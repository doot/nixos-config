{
  config,
  lib,
  pkgs,
  inputs,
  terminalIdentityEnv ? ["TERM"],
  ...
}: let
  cfg = config.services.hermes-agent;
  common = import "${inputs.hermes-agent}/nix/moduleCommon.nix" {inherit lib;};
  uid = config.users.users.${cfg.user}.uid;
  runtimeDir = "/run/user/${toString uid}";
  userManager = "user@${toString uid}";
  writePaths = [cfg.stateDir cfg.workingDirectory runtimeDir];
  writeAccess = lib.concatStringsSep "," [
    "write-file"
    "remove-dir"
    "remove-file"
    "make-dir"
    "make-reg"
    "make-sock"
    "make-fifo"
    "make-sym"
    "refer"
    "truncate"
  ];
  landlockArgs = paths:
    ["--no-new-privs" "--landlock-access=fs:${writeAccess},make-char,make-block,ioctl-dev"]
    ++ map (path: "--landlock-rule=path-beneath:${writeAccess}:${path}") paths
    ++ map (path: "--landlock-rule=path-beneath:write-file:${path}") [
      "/dev/null"
      "/dev/zero"
      "/dev/full"
    ]
    ++ map (path: "--landlock-rule=path-beneath:write-file,ioctl-dev:${path}") [
      "/dev/tty"
      "/dev/pts"
    ];
  launcher = {
    manager ? false,
    paths ? writePaths ++ ["/tmp" "/var/tmp"],
  }:
    pkgs.writeShellScript "hermes-confine" ''
      set -eu
      ${lib.optionalString manager ''
        # Refuse ProtectControlGroups=private's unsupported-kernel downgrade.
        read -r cgroup < /proc/self/cgroup
        test "$cgroup" = '0::/init.scope'
        test -w /sys/fs/cgroup/cgroup.subtree_control
      ''}
      exec ${lib.getExe' pkgs.util-linux "setpriv"} ${lib.escapeShellArgs (landlockArgs (
        paths ++ lib.optional manager "/sys/fs/cgroup"
      ))} -- "$@"
    '';
  workerLauncher = launcher {};
  managerLauncher = launcher {manager = true;};
  cliLauncher = launcher {paths = [runtimeDir];};
  policy = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    ProtectSystem = "strict";
    ProtectHome = lib.mkForce "read-only";
    ReadWritePaths = writePaths;
    # Scopes share the manager's temporary namespace across gateway restarts.
    PrivateTmp = lib.mkForce "disconnected";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectClock = true;
    ProtectProc = "invisible";
    RestrictNamespaces = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = ["~@mount @debug process_vm_readv process_vm_writev"];
    SystemCallErrorNumber = "EPERM";
  };
  cli = pkgs.writeShellScriptBin "hermes" ''
    set -euo pipefail
    export HERMES_HOME=${lib.escapeShellArg "${cfg.stateDir}/.hermes"}
    export XDG_RUNTIME_DIR=${lib.escapeShellArg runtimeDir}
    mode=--pipe
    if [[ -t 0 && -t 1 ]]; then mode=--pty; fi
    setenv=(--setenv=HERMES_HOME)
    for var in ${lib.escapeShellArgs terminalIdentityEnv}; do
      if [[ -n "''${!var-}" ]]; then setenv+=("--setenv=$var=''${!var}"); fi
    done
    exec ${cliLauncher} ${lib.getExe' pkgs.systemd "systemd-run"} \
      --user "$mode" --wait --collect --quiet \
      --working-directory=${lib.escapeShellArg cfg.workingDirectory} \
      "''${setenv[@]}" -- ${common.effectivePackage cfg}/bin/hermes "$@"
  '';
in {
  assertions = [
    {
      assertion = uid != null;
      message = "Hermes worker confinement requires an explicitly assigned UID.";
    }
    {
      assertion = !cfg.container.enable && cfg.backend.mode == "none";
      message = "Hermes worker confinement covers the native gateway and CLI only.";
    }
  ];

  users.users.${cfg.user}.linger = true;
  services.hermes-agent.addToSystemPackages = lib.mkForce false;
  environment = {
    systemPackages = [cli];
    variables.HERMES_HOME = "${cfg.stateDir}/.hermes";
  };

  systemd.user.services.hermes-gateway = {
    description = "Hermes Agent Gateway";
    unitConfig.ConditionUser = cfg.user;
    environment =
      common.processEnvironment {hermesHome = "${cfg.stateDir}/.hermes";}
      // {
        HOME = cfg.stateDir;
        XDG_RUNTIME_DIR = runtimeDir;
      };
    path = common.processPath {inherit pkgs cfg;};
    # M must fork G so it can inspect G's children when attaching worker scopes.
    serviceConfig = {
      Type = "exec";
      ExecStart = lib.escapeShellArgs ([workerLauncher] ++ common.gatewayArgv cfg);
      Restart = "no";
      UMask = "0007";
      WorkingDirectory = cfg.workingDirectory;
    };
  };

  systemd.services = {
    hermes-agent = {
      environment.XDG_RUNTIME_DIR = runtimeDir;
      requires = ["${userManager}.service"];
      after = ["${userManager}.service"];
      serviceConfig =
        policy
        // {
          Type = "exec";
          ProtectControlGroups = true;
          ExecStart = lib.mkForce (lib.escapeShellArgs [
            cliLauncher
            (lib.getExe' pkgs.systemd "systemctl")
            "--user"
            "--wait"
            "start"
            "hermes-gateway.service"
          ]);
          # ExecStopPost also runs after controller death or a failed start.
          ExecStopPost = lib.escapeShellArgs [
            cliLauncher
            (lib.getExe' pkgs.systemd "systemctl")
            "--user"
            "stop"
            "hermes-gateway.service"
          ];
        };
    };
    ${userManager} = {
      overrideStrategy = "asDropin";
      # PID 1 applies this policy before user services or generators can run.
      serviceConfig =
        policy
        // {
          ProtectControlGroups = "private";
          ExecStart = ["" "${managerLauncher} ${config.systemd.package}/lib/systemd/systemd --user"];
        };
    };
  };
}
