{
  config,
  lib,
  ...
}: let
  common = import ../common.nix;
  cfg = config.streamystats;
in {
  options.streamystats = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 3010;
      description = "Host loopback port for Streamystats";
    };
    dataDir = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/docker-local/streamystats";
      description = "Host directory for Streamystats PostgreSQL data";
    };
  };

  config = {
    project.name = "streamystats";
    services.streamystats = {
      service = {
        image = "ghcr.io/fredrikburmester/streamystats-aio:latest";
        restart = "unless-stopped";
        env_file = ["/run/secrets/rendered/streamystats.env"];
        volumes = ["${cfg.dataDir}:/var/lib/postgresql/data"];
        ports = ["127.0.0.1:${toString cfg.port}:3000"];
        environment = {
          TZ = common.tz;
          POSTGRES_HOST_AUTH_METHOD = "scram-sha-256";
          POSTGRES_INITDB_ARGS = "--auth-host=scram-sha-256";
        };
      };
      out.service =
        common.outDefaults
        // {
          # PostgreSQL needs time to shut down before Docker sends SIGKILL.
          stop_grace_period = "60s";
          security_opt = ["no-new-privileges:true"];
          logging = {
            driver = "json-file";
            options = {
              max-size = "10m";
              max-file = "3";
            };
          };
        };
    };
  };
}
