# Module enable Forgejo
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.roles.navidrome;
in {
  options.roles.navidrome = {
    enable =
      lib.mkEnableOption "navidrome role"
      // {
        default = false;
      };
  };
  config = lib.mkIf cfg.enable {
    services = {
      navidrome = {
        enable = true;
        package = pkgs.unstable.navidrome;
        settings = {
          MusicFolder = "/media-nfs/Music_lidarr";
        };
      };
    };

    systemd = {
      services = {
        # Navidrome scanning fails with permission denied error to /dev/null for some reason
        navidrome.serviceConfig.PrivateDevices = lib.mkForce "no";
      };
    };
  };
}
