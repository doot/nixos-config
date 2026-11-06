{inputs}: let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  network = import ../common/network.nix;
  fqdn = network.hosts.nix-media-docker.fqdn;
  cfg =
    (lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit fqdn;
        outputs.nixosConfigurations.nix-slopfucker.config.containers.hermes = {
          localAddress = "10.100.0.2";
          config.services.hermes-agent.settings.webapp = {
            port = 9120;
            public_url = "https://hermes.${fqdn}";
          };
        };
      };
      modules = [
        ../modules/nginx-proxy
        ../systems/nix-media-docker/hermes.nix
        {
          roles.nginx-proxy.enable = true;
          environment.etc."ssh/ssh_known_hosts".text = "";
          security.acme = {
            acceptTerms = true;
            defaults.email = "test@example.invalid";
            certs.${fqdn}.domain = "*.${fqdn}";
          };
          system.stateVersion = "26.05";
        }
      ];
    }).config;
in
  pkgs.runCommand "hermes-webapp-tests" {
    nativeBuildInputs = [pkgs.python3 pkgs.nginx pkgs.openssl pkgs.apacheHttpd];
    TEST_CONFIG = builtins.toJSON {
      command = cfg.systemd.services.nginx.serviceConfig.ExecStart;
      authFile = cfg.services.nginx.virtualHosts."hermes.${fqdn}".basicAuthFile;
      upstream = cfg.services.nginx.virtualHosts."hermes.${fqdn}".locations."/".proxyPass;
      nginxGroups = cfg.users.users.nginx.extraGroups;
      tunnel = cfg.systemd.services.hermes-webapp-tunnel.serviceConfig;
    };
  } ''
    python ${./hermes-webapp.py}
    touch "$out"
  ''
