{
  config,
  lib,
  ...
}: let
  common = import ../common.nix;
  network = import ../../common/network.nix;
  cfg = config.jellyglance;
  vhost = "jellyglance.${network.hosts.nix-media-docker.fqdn}";
in {
  options.jellyglance = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 3013;
      description = "Host loopback port for JellyGlance";
    };
    dataDir = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/docker-local/jellyglance";
      description = "Host directory for JellyGlance state";
    };
  };

  config = {
    project.name = "jellyglance";
    services = {
      jellyglance = {
        service = {
          image = "ghcr.io/jellyglance/server:latest";
          restart = "unless-stopped";
          user = "${common.puid}:${common.pgid}";
          capabilities.ALL = false;
          env_file = ["/run/secrets/rendered/jellyglance.env"];
          ports = ["127.0.0.1:${toString cfg.port}:3000"];
          volumes = [
            "${cfg.dataDir}/config:/app/config"
            "${cfg.dataDir}/backups:/app/backups"
            # Import staging and frontend setup also write inside the application tree.
            "${cfg.dataDir}/backups:/app/apps/api/backup-data"
            "${cfg.dataDir}/config/client-env.js:/app/apps/web/dist/env.js"
          ];
          environment = {
            TZ = common.tz;
            HOME = "/tmp";
            POSTGRES_USER = "jellyglance";
            POSTGRES_DB = "jellyglance";
            POSTGRES_IP = "postgres";
            POSTGRES_PORT = "5432";
            CONFIG_DIR = "/app/config";
            BACKUP_DIR = "/app/backups";
            JS_PUBLIC_URL = "https://${vhost}";
          };
          depends_on.postgres.condition = "service_healthy";
        };
        out.service = common.outDefaults // {security_opt = ["no-new-privileges:true"];};
      };
      postgres = {
        service = {
          image = "postgres:18-alpine";
          restart = "unless-stopped";
          user = "${common.puid}:${common.pgid}";
          capabilities.ALL = false;
          env_file = ["/run/secrets/rendered/jellyglance-postgres.env"];
          environment = {
            POSTGRES_USER = "jellyglance";
            POSTGRES_DB = "jellyglance";
            POSTGRES_INITDB_ARGS = "--auth-host=scram-sha-256";
          };
          # PostgreSQL 18 stores its versioned data below this parent.
          volumes = ["${cfg.dataDir}/postgres:/var/lib/postgresql"];
          healthcheck = {
            test = ["CMD" "pg_isready" "-U" "jellyglance" "-d" "jellyglance"];
            interval = "10s";
            timeout = "5s";
            retries = 5;
            start_period = "60s";
          };
        };
        out.service =
          common.outDefaults
          // {
            shm_size = "1g";
            stop_grace_period = "60s";
            security_opt = ["no-new-privileges:true"];
          };
      };
    };
  };
}
