{
  config,
  lib,
  ...
}: let
  common = import ../common.nix;
  cfg = config.watchstate;
in {
  options.watchstate = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 8087;
      description = "Host loopback port for WatchState";
    };
    dataDir = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/docker-local/watchstate";
      description = "Host directory for WatchState data";
    };
  };

  config = {
    project.name = "watchstate";
    services.watchstate = {
      service = {
        image = "ghcr.io/arabcoders/watchstate:latest";
        restart = "unless-stopped";
        user = "${common.puid}:${common.pgid}";
        capabilities.ALL = false;
        volumes = [
          "${cfg.dataDir}:/config"
        ];
        ports = [
          "127.0.0.1:${toString cfg.port}:8080"
        ];
        environment = {
          TZ = common.tz;
          UMASK = "0077";
          WS_SECURE_API_ENDPOINTS = "true";
          WS_TRUST_PROXY = "true";
          WS_TRUST_HEADER = "X-WatchState-Client-IP";
          WS_TRUST_LOCAL = "false";
        };
      };
      out.service =
        common.outDefaults
        // {
          security_opt = ["no-new-privileges:true"];
        };
    };
  };
}
