# Initialize agent-writable state without root. Upstream activation performs
# privileged installs/chown/chmod beneath paths the agent can replace with symlinks.
#
# Disable that activation and reuse its installer before each gateway start, under
# the service user. LoadCredential supplies root-only env/auth inputs; the installer
# writes config, .env, auth, documents and plugins. Upstream tmpfiles handles initial
# directory ownership. This is a native systemd gateway inside a NixOS container;
# upstream OCI and separate backend lifecycles are not supported here.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.services.hermes-agent;
  common = import "${inputs.hermes-agent}/nix/moduleCommon.nix" {inherit lib;};
  envCredentialNames = lib.imap0 (i: _: "environment-${toString i}") cfg.environmentFiles;
  hasCredentials = cfg.environmentFiles != [] || cfg.authFile != null;
  stateSetup = common.mkStateScript {
    inherit pkgs;
    cfg =
      cfg
      // {
        environmentFiles = envCredentialNames;
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
  };
in {
  assertions = [
    {
      assertion = !cfg.container.enable && cfg.backend.mode == "none" && cfg.user != "root";
      message = "Hermes state initialization requires an unprivileged native gateway.";
    }
  ];

  system.activationScripts.hermes-agent-setup.text = lib.mkForce "";
  systemd.services.hermes-agent = {
    serviceConfig.LoadCredential =
      lib.zipListsWith (name: path: "${name}:${path}") envCredentialNames cfg.environmentFiles
      ++ lib.optional (cfg.authFile != null) "auth:${cfg.authFile}";
    # The installer quotes file paths; use relative credential names in a subshell.
    preStart = lib.mkBefore ''
      (
        ${lib.optionalString hasCredentials ''cd "$CREDENTIALS_DIRECTORY" || exit 1''}
        ${stateSetup}
        rm -f ${lib.escapeShellArg "${cfg.stateDir}/.hermes/.container-mode"}
      )
    '';
  };
}
