{
  config,
  lib,
  ...
}: let
  cfg = config.roles.labChecks;

  flags = config.system.autoUpgrade.flags;
  # `--override-input priv <url>` is three separate list elements; pair each
  # flag with its successor to find the adjacent `--override-input priv`.
  privOverridden =
    lib.elem true
    (lib.zipListsWith (a: b: a == "--override-input" && b == "priv")
      flags (lib.drop 1 flags));
in {
  options.roles.labChecks = {
    enable =
      lib.mkEnableOption "eval-time invariant checks for this fleet"
      // {default = true;};

    failOnWarnings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Fail evaluation when any module emits a warning. Off by default so a
        fresh nixpkgs deprecation cannot block a deploy; CI turns it on to
        surface deprecations the release they appear rather than the release
        the option is removed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Every host imports a priv bundle, which resolves to the public no-op
        # stub unless the input is overridden at deploy time.
        assertion = config.system.autoUpgrade.enable -> privOverridden;
        message = ''
          system.autoUpgrade.flags lacks `--override-input priv <url>`, so
          scheduled upgrades evaluate the public stub and /run/secrets stays empty.
        '';
      }
      {
        assertion = cfg.failOnWarnings -> config.warnings == [];
        message = "roles.labChecks.failOnWarnings is set and this configuration emits warnings:\n${lib.concatStringsSep "\n" config.warnings}";
      }
    ];
  };
}
