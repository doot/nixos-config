{
  config,
  lib,
  ...
}: let
  common = import ../common.nix;
  network = import ../../common/network.nix;
  cfg = config.tracearr;
  vhost = "tracearr.${network.hosts.nix-media-docker.fqdn}";
in {
  options.tracearr = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 3011;
      description = "Host loopback port for Tracearr";
    };
    dataDir = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/docker-local/tracearr";
      description = "Host directory for Tracearr state";
    };
  };

  config = {
    project.name = "tracearr";
    services = {
      tracearr = {
        service = {
          image = "ghcr.io/connorgallopo/tracearr:latest";
          restart = "unless-stopped";
          capabilities.ALL = false;
          env_file = ["/run/secrets/rendered/tracearr.env"];
          ports = ["127.0.0.1:${toString cfg.port}:3000"];
          volumes = ["${cfg.dataDir}/data:/data"];
          environment = {
            TZ = common.tz;
            NODE_ENV = "production";
            HOST = "0.0.0.0";
            REDIS_URL = "redis://redis:6379";
            TRUST_PROXY = "true";
            CORS_ORIGIN = "https://${vhost}";
          };
          depends_on = {
            timescale.condition = "service_healthy";
            redis.condition = "service_healthy";
          };
        };
        out.service = common.outDefaults // {security_opt = ["no-new-privileges:true"];};
      };
      timescale = {
        service = {
          image = "timescale/timescaledb-ha:pg18.4-ts2.29.1";
          restart = "unless-stopped";
          env_file = ["/run/secrets/rendered/tracearr-postgres.env"];
          environment = {
            POSTGRES_USER = "tracearr";
            POSTGRES_DB = "tracearr";
            POSTGRES_INITDB_ARGS = "--auth-host=scram-sha-256";
          };
          volumes = ["${cfg.dataDir}/postgres:/home/postgres/pgdata/data"];
          command = [
            "postgres"
            "-c"
            "timescaledb.license=timescale"
            "-c"
            "timescaledb.max_tuples_decompressed_per_dml_transaction=100000"
            "-c"
            "max_locks_per_transaction=4096"
            "-c"
            "timescaledb.telemetry_level=off"
            "-c"
            "max_connections=150"
          ];
          healthcheck = {
            test = ["CMD" "pg_isready" "-U" "tracearr" "-d" "tracearr"];
            interval = "10s";
            timeout = "5s";
            retries = 5;
            start_period = "60s";
          };
        };
        out.service =
          common.outDefaults
          // {
            mem_limit = "4g";
            memswap_limit = "4g";
            shm_size = "512m";
            ulimits.nofile = {
              soft = 65536;
              hard = 65536;
            };
            stop_grace_period = "60s";
            security_opt = ["no-new-privileges:true"];
          };
      };
      redis = {
        service = {
          image = "redis:8-alpine";
          restart = "unless-stopped";
          command = ["redis-server" "--appendonly" "yes"];
          volumes = ["${cfg.dataDir}/redis:/data"];
          healthcheck = {
            test = ["CMD" "redis-cli" "ping"];
            interval = "10s";
            timeout = "5s";
            retries = 5;
          };
        };
        out.service = common.outDefaults // {security_opt = ["no-new-privileges:true"];};
      };
    };
  };
}
