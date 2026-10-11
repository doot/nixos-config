{
  config,
  lib,
  ...
}: let
  common = import ../common.nix;
  network = import ../../common/network.nix;
  cfg = config.jellydash;
  vhost = "jellydash.${network.hosts.nix-media-docker.fqdn}";
  jellyfinHost = "jf.${network.hosts.nix-media-docker.fqdn}";
in {
  options.jellydash = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 3012;
      description = "Host loopback port for Jellydash";
    };
    dataDir = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/docker-local/jellydash";
      description = "Host directory for Jellydash state";
    };
  };

  config = {
    project.name = "jellydash";
    services.jellydash = {
      service = {
        image = "ghcr.io/themartz90/jellydash:latest";
        restart = "unless-stopped";
        env_file = ["/run/secrets/rendered/jellydash.env"];
        ports = ["127.0.0.1:${toString cfg.port}:80"];
        volumes = [
          "${cfg.dataDir}/data:/var/www/html/var/data"
          "${cfg.dataDir}/cache:/var/www/html/cache"
          "${cfg.dataDir}/runtime-cache:/var/www/html/var/cache"
          "${cfg.dataDir}/logs:/var/www/html/var/log"
          "${cfg.dataDir}/sessions:/var/www/html/var/sessions"
          "${cfg.dataDir}/uploads:/var/www/html/public/uploads"
        ];
        environment = {
          APP_ENV = "production";
          APP_DEBUG = "false";
          APP_TIMEZONE = common.tz;
          APP_URL = "https://${vhost}";
          DB_DRIVER = "sqlite3";
          DB_NAME = "/var/www/html/var/data/jellydash.sqlite";
          JELLYFIN_URL = "https://${jellyfinHost}";
          JELLYFIN_VERIFY_SSL = "true";
          AUTH_ENABLED = "true";
          AUTH_ADMIN_USER = "admin";
          POLLER_ENABLED = "true";
        };
      };
      out.service = common.outDefaults // {security_opt = ["no-new-privileges:true"];};
    };
  };
}
