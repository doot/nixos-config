{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.services.hermes-agent;
  common = import "${inputs.hermes-agent}/nix/moduleCommon.nix" {inherit lib;};
  envNames = lib.imap0 (i: _: "environment-${toString i}") cfg.environmentFiles;
  hasCredentials = cfg.environmentFiles != [] || cfg.authFile != null;
in {
  assertions = [
    {
      assertion = !cfg.container.enable && cfg.backend.mode == "none" && cfg.user != "root";
      message = "Hermes state initialization requires an unprivileged native gateway.";
    }
  ];

  # Run the shell installer after privilege drop: its paths are agent-writable.
  system.activationScripts.hermes-agent-setup.text = lib.mkForce "";
  systemd.services.hermes-agent = {
    serviceConfig.LoadCredential =
      lib.zipListsWith (name: path: "${name}:${path}") envNames cfg.environmentFiles
      ++ lib.optional (cfg.authFile != null) "auth:${cfg.authFile}";
    preStart = lib.mkBefore ''
      (
        ${lib.optionalString hasCredentials ''cd "$CREDENTIALS_DIRECTORY" || exit 1''}
        ${common.mkStateScript {
        inherit pkgs;
        cfg =
          cfg
          // {
            environmentFiles = envNames;
            authFile =
              if cfg.authFile == null
              then null
              else "auth";
          };
        hermesHome = "${cfg.stateDir}/.hermes";
        inherit (cfg) workingDirectory;
        stateDirs = common.stateSubdirs;
        modes = {
          config =
            if cfg.addToSystemPackages
            then "0660"
            else "0640";
          env = "0640";
          managed = "0644";
          auth = "0600";
          document = "0640";
        };
      }}
        rm -f ${lib.escapeShellArg "${cfg.stateDir}/.hermes/.container-mode"}
      )
    '';
  };
}
