# Shared borgbackup job to the NAS. Bakes the boilerplate (RSH, prune policy,
# compression, remote-path) so each host only declares its own paths + repo.
#
# NOTE: borg does not support multiple machines writing to the same repository,
# so every host MUST use a distinct `repo`.
{
  config,
  lib,
  ...
}: let
  cfg = config.roles.borg;
in {
  options.roles.borg = {
    enable = lib.mkEnableOption "borgbackup job to the NAS";

    jobName = lib.mkOption {
      type = lib.types.str;
      description = "Job name; also used as the archive base name.";
    };

    repo = lib.mkOption {
      type = lib.types.str;
      description = "Borg repository URL. Must be unique per host (borg does not share a repo across machines).";
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Paths to back up.";
    };

    preHook = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Shell run before the backup, e.g. to dump databases into a staging dir that is also listed in `paths`.";
    };

    readWritePaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      description = ''
        Directories the backup service is allowed to write to. The nixpkgs
        borgbackup module runs the job under `ProtectSystem = "strict"`, so the
        whole filesystem is read-only except borg's own cache/config. Any path a
        `preHook` writes to (e.g. a DB-dump staging dir) MUST be listed here or
        the preHook fails with "Read-only file system".
      '';
      example = ["/var/backup/mysqldump"];
    };

    failOnWarnings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Fail the job on a borg warning (exit 1). Keep true so a warning is a
        real signal; set false only for a job that backs up files written live
        (e.g. an sqlite DB), where "file changed while we backed it up" is
        expected and would otherwise mark every run failed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.borgbackup.jobs.${cfg.jobName} = {
      inherit (cfg) paths repo preHook readWritePaths failOnWarnings;
      archiveBaseName = cfg.jobName;
      # TODO(secrets): switch to repokey encryption with a passphrase sourced from the
      # secrets store once that task lands. Unencrypted matches the current posture.
      encryption.mode = "none";
      environment.BORG_RSH = "ssh -o 'StrictHostKeyChecking=no' -o 'BatchMode=yes' -i /root/.ssh/id_ed25519";
      extraArgs = ["--remote-path=/usr/local/bin/borg"];
      extraCreateArgs = [
        "--stats"
        "--show-rc"
        "--exclude-caches"
      ];
      prune.keep = {
        daily = 7;
        weekly = 2;
        monthly = 4;
      };
      extraPruneArgs = [
        "--show-rc"
        "--stats"
        "--save-space"
      ];
      compression = "auto,zstd";
      startAt = "daily";
      persistentTimer = true;
    };
  };
}
