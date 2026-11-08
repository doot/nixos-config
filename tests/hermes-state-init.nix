{inputs}: let
  inherit (inputs.nixpkgs-unstable) lib;
  pkgs = inputs.nixpkgs-unstable.legacyPackages.x86_64-linux;
  config = inputs.self.nixosConfigurations.nix-slopfucker.config.containers.hermes.config;
  cfg = config.services.hermes-agent;
  gateway = config.systemd.services.hermes-agent;
  stateRules = lib.filter (rule: lib.hasInfix " ${cfg.stateDir}" rule) config.systemd.tmpfiles.rules;
  envCredentials = lib.imap0 (i: path: "environment-${toString i}:${path}") cfg.environmentFiles;
in
  assert lib.assertMsg (config.system.activationScripts.hermes-agent-setup.text == "")
  "Hermes activation must not write through agent-controlled state as root";
  assert lib.assertMsg (gateway.serviceConfig.User == cfg.user && cfg.user != "root" && lib.hasInfix "config.yaml" gateway.preStart)
  "Hermes state setup must run as the service user";
  assert lib.assertMsg (!(gateway.serviceConfig.PermissionsStartOnly or false) && gateway.serviceConfig.CapabilityBoundingSet == "")
  "Hermes preStart must not retain root privileges";
  assert lib.assertMsg (gateway.serviceConfig.LoadCredential == envCredentials && lib.hasInfix ''cd "$CREDENTIALS_DIRECTORY"'' gateway.preStart)
  "Hermes setup must receive environment inputs through systemd credentials";
  assert lib.assertMsg (lib.all (path: !(lib.hasInfix path gateway.preStart)) cfg.environmentFiles)
  "Hermes setup must not try to read the original root-only environment files";
  assert lib.assertMsg (stateRules != [] && lib.all (rule: lib.hasPrefix "d " rule || lib.hasPrefix "L+ " rule) stateRules)
  "Review new privileged tmpfiles operations beneath Hermes state";
    pkgs.runCommand "hermes-state-init-test" {
      nativeBuildInputs = [pkgs.coreutils pkgs.systemd];
      passthru.evaluation = {
        inherit stateRules;
        inherit (gateway) preStart;
        inherit (gateway.serviceConfig) User LoadCredential;
      };
    } ''
      # These same-UID fixtures test path handling, not a root security boundary.
      umask 0007
      mkdir -p root/state root/target
      cd root || exit
      # Nix's user namespace makes / an unsafe owner transition for tmpfiles.
      printf 'd /state/created 0700 - - - -\n' > positive.conf
      systemd-tmpfiles --root="$PWD" --create - < positive.conf
      test "$(stat -c %a state/created)" = 700
      mode=$(stat -c %a target)
      test "$mode" != 700
      ln -s "$PWD/target" state/logs

      mkdir -p state/logs/legacy-created
      test -d target/legacy-created

      printf 'd /state/logs 0700 - - - -\n' > dirs.conf
      systemd-tmpfiles --root="$PWD" --create - < dirs.conf
      test -L state/logs
      test "$(stat -c %a target)" = "$mode"

      printf 'unchanged\n' > target/canary
      ln -s "$PWD/target/canary" state/SOUL.md
      printf 'declarative\n' > soul
      printf 'L+ /state/SOUL.md - - - - ../soul\n' > links.conf
      systemd-tmpfiles --root="$PWD" --create - < links.conf
      test "$(readlink state/SOUL.md)" = ../soul
      test "$(cat state/SOUL.md)" = declarative
      test "$(cat target/canary)" = unchanged

      printf 'PASS: activation/UID/credential assertions; tmpfiles d and L+ fixtures\n'
      touch "$out"
      chmod 0644 "$out"
    ''
