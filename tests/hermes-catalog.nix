{inputs}: let
  inherit (inputs.nixpkgs-unstable) lib;
  pkgs = inputs.nixpkgs-unstable.legacyPackages.x86_64-linux;
  cfg = inputs.self.nixosConfigurations.nix-slopfucker.config.containers.hermes.config.services.hermes-agent;
  common = import "${inputs.hermes-agent}/nix/moduleCommon.nix" {inherit lib;};
  package = common.effectivePackage cfg;
  grafana = cfg.settings.mcp_servers.grafana;
  # Force derivation evaluation without building the agent's runtime closure.
  evaluation = pkgs.writeText "hermes-catalog-evaluation.json" (
    builtins.unsafeDiscardStringContext (builtins.toJSON {
      package = package.drvPath;
      plugins = map (plugin: plugin.drvPath) cfg.extraPlugins;
      mcpCommands = lib.mapAttrs (_: server: server.command) cfg.settings.mcp_servers;
    })
  );
in
  assert lib.assertMsg (lib.all (arg: builtins.elem arg grafana.args) ["--disable-write" "--usage-stats=disabled"])
  "Grafana MCP must disable writes and usage reporting";
  assert lib.assertMsg (!grafana.sampling.enabled)
  "Grafana MCP must not request model sampling";
  assert lib.assertMsg (grafana.env.GRAFANA_SERVICE_ACCOUNT_TOKEN == "\${GRAFANA_TOKEN}")
  "Grafana credentials must be resolved at runtime";
  assert lib.assertMsg (cfg.settings.mcp_servers.nixos.command != null)
  "The existing NixOS MCP must remain configured";
  assert lib.assertMsg (builtins.elem "security-guidance" cfg.settings.plugins.enabled)
  "Security Guidance must be enabled for its block policy";
  assert lib.assertMsg (!(builtins.elem "disk-cleanup" cfg.settings.plugins.enabled))
  "Automatic cleanup must remain opt-in";
    pkgs.runCommand "hermes-catalog-test" {
      nativeBuildInputs = [pkgs.python3];
      PYTHONPATH = inputs.hermes-agent;
      inherit (cfg.environment) SECURITY_GUIDANCE_BLOCK SECURITY_GUIDANCE_DISABLE;
    } ''
      python ${./test_hermes_security_guidance.py} ${package.bundledPlugins}/security-guidance
      cp ${evaluation} "$out"
    ''
