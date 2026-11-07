{inputs}: let
  pkgs = import inputs.nixpkgs-unstable {system = "x86_64-linux";};
  inherit (pkgs) lib;
  module = import ../systems/nix-slopfucker/hermes.nix {
    inherit lib pkgs;
    inputs = {};
    config.containers.hermes.config.services.hermes-agent.settings.webapp.port = 9120;
  };
  fixtureArgs = {
    inherit lib;
    vethHost = "hf-agent";
    hostAddress = "198.18.0.1";
    allowedInternalHosts = ["10.23.0.88"];
    allowedInternalServices = [
      {
        host = "10.23.0.110";
        ports = [22];
      }
    ];
    lanDenyCidrs = ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "169.254.0.0/16" "100.64.0.0/10"];
  };
  render = import ../systems/nix-slopfucker/hermes-firewall.nix;
  evaluate = modules:
    (import (inputs.nixpkgs-unstable + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules =
        [
          {
            system.stateVersion = "26.05";
            boot.isContainer = true;
          }
        ]
        ++ modules;
    }).config;
  base = {
    networking = {
      enableIPv6 = true;
      firewall = {
        allowedTCPPorts = [22 2022 3030 8765 9002 9558];
        allowedUDPPorts = [161];
        logRefusedConnections = false;
      };
    };
  };
  fixture = args:
    evaluate [
      base
      {
        inherit (module) networking;
        system.preSwitchChecks = module.system.preSwitchChecks or {};
        systemd.services.nftables = module.systemd.services.nftables;
      }
      {
        networking = {
          nftables.tables.hermes-confinement.content = lib.mkForce (render args).content;
          firewall.interfaces = lib.mkForce {hf-agent = module.networking.firewall.interfaces.ve-hermes;};
          nat = {
            externalInterface = lib.mkForce "hf-uplink";
            internalInterfaces = lib.mkForce ["hf-agent"];
          };
        };
      }
    ];
  cfg = fixture fixtureArgs;
  changed = fixture (fixtureArgs // {allowedInternalHosts = ["10.23.0.89"];});
  # The deployed iptables NAT stop script must not remove native tables.
  legacy = evaluate [
    base
    {
      networking = {
        nftables.enable = false;
        firewall.interfaces.hf-agent = {
          allowedTCPPorts = [53];
          allowedUDPPorts = [53];
        };
        nat = {
          enable = true;
          externalInterface = "hf-uplink";
          internalInterfaces = ["hf-agent"];
        };
      };
    }
  ];
  policy = {
    nativeOwnership = module.networking.nftables.enable;
    migrationCheck = cfg.system.preSwitchChecks.hermes-firewall-backend or "";
    inherit (cfg.networking.firewall) backend filterForward;
    inherit (cfg.networking.nftables) flushRuleset tables;
    inherit (cfg.systemd.services.nftables) before requiredBy;
    inherit (cfg.systemd.services.nftables.serviceConfig) ExecStart ExecReload ExecStop ExecStartPost;
    unit = cfg.systemd.units."nftables.service".text;
    fixture = builtins.elemAt cfg.systemd.services.nftables.serviceConfig.ExecStart 1;
    changedFixture = builtins.elemAt changed.systemd.services.nftables.serviceConfig.ExecStart 1;
    legacyStart = lib.removePrefix "@" (builtins.head (lib.splitString " " legacy.systemd.services.firewall.serviceConfig.ExecStart));
    legacyStop = lib.removePrefix "@" (builtins.head (lib.splitString " " legacy.systemd.services.firewall.serviceConfig.ExecStop));
    legacyPath = lib.makeBinPath legacy.systemd.services.firewall.path;
    productionTable = module.networking.nftables.tables.hermes-confinement;
  };
in {
  inherit policy;
  policyFile = pkgs.writeText "hermes-firewall-policy.json" (builtins.toJSON policy);
  # Packet tests run separately: Nix builders need not permit network namespaces.
  check =
    pkgs.runCommand "hermes-firewall-regression" {
      nativeBuildInputs = [pkgs.python3 pkgs.bash];
    } ''
      set -o pipefail
      python ${./test_hermes_firewall.py} ${pkgs.writeText "hermes-firewall-policy.json" (builtins.toJSON policy)} LifecycleRegression -v 2>&1 | tee "$out"
    '';
}
