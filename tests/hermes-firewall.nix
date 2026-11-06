{inputs}: let
  pkgs = import inputs.nixpkgs-unstable {system = "x86_64-linux";};
  inherit (pkgs) lib;
  module = import ../systems/nix-slopfucker/hermes.nix {
    inherit lib pkgs;
    inputs = {};
    config = {
      containers.hermes.config.services.hermes-agent.settings.webapp.port = 9120;
      networking.enableIPv6 = true;
    };
  };
  unwrap = value: value.content or value;
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
    enableIPv6 = true;
  };
  render = import ../systems/nix-slopfucker/hermes-firewall.nix;
  policy = {
    start = unwrap module.networking.firewall.extraCommands;
    stop = unwrap module.networking.firewall.extraStopCommands;
    preStart = module.systemd.services.firewall.preStart;
    inherit (module.systemd.services.firewall) before requiredBy;
    fixture = render fixtureArgs;
    changedFixture = render (fixtureArgs // {allowedInternalHosts = ["10.23.0.89"];});
    ipv4OnlyFixture = render (fixtureArgs // {enableIPv6 = false;});
  };
in {
  inherit policy;
  # Packet tests run separately: Nix builders need not permit network namespaces.
  check =
    pkgs.runCommand "hermes-firewall-regression" {
      nativeBuildInputs = [pkgs.python3 pkgs.bash];
    } ''
      set -o pipefail
      python ${./test_hermes_firewall.py} ${pkgs.writeText "hermes-firewall-policy.json" (builtins.toJSON policy)} LifecycleRegression -v 2>&1 | tee "$out"
    '';
}
