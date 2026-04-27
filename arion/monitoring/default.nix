let
  common = import ../common.nix;
in {
  project.name = "monitoring";

  services = {
    cadvisor = {
      service = {
        image = "gcr.io/cadvisor/cadvisor:v0.52.0"; # TODO: latest tag is over a year old, switch back once it's ben updated
        privileged = true;
        restart = "unless-stopped";
        command = [
          "-housekeeping_interval=30s"
          "-store_container_labels=false"
        ];
        volumes = [
          "/:/rootfs:ro"
          "/var/run:/var/run:rw"
          "/sys:/sys:ro"
          "/var/lib/docker/:/var/lib/docker:ro"
          "/dev/disk/:/dev/disk:ro"
        ];
        ports = [
          "8080:8080"
        ];
      };
      out.service =
        common.outDefaults
        // {
          mem_limit = "1g";
          memswap_limit = "1g";
        };
    };
    nut-exporter = {
      service = {
        image = "hon95/prometheus-nut-exporter:latest";
        restart = "unless-stopped";
        environment = {
          TZ = common.tz;
          HTTP_PATH = "/metrics";
          # Defaults
          # RUST_LOG = "info";
          # HTTP_PORT = 9995;
          # HTTP_PATH = "/nut";
          # LOG_REQUESTS_CONSOLE = false;
          # PRINT_METRICS_AND_EXIT = false;
        };
        ports = [
          "9995:9995"
        ];
      };
      out.service =
        common.outDefaults
        // {
          mem_limit = "1g";
          memswap_limit = "1g";
        };
    };

    # TODO: This is temporary until nix packaging is fixed upstream. The package is currently broken.
    gitea-mirror = {
      service = {
        image = "ghcr.io/raylabshq/gitea-mirror:latest";
        restart = "unless-stopped";
        ports = [
          "4321:4321"
        ];
        user = "1029";
        volumes = [
          "/docker-local/gitea-mirror/:/app/data"
        ];
        environment = {
          # === ABSOLUTELY REQUIRED ===
          # This MUST be set and CANNOT be changed via UI
          # BETTER_AUTH_SECRET = common.betterAuthSecret; # Min 32 chars, required for sessions
          BETTER_AUTH_URL = "https://gitea-mirror.nmd.jhauschildt.com}";
          BETTER_AUTH_TRUSTED_ORIGINS = "https://gitea-mirror.nmd.jhauschildt.com}";

          # === CORE SETTINGS ===
          # These are technically required but have working defaults
          NODE_ENV = "production";
          DATABASE_URL = "file:data/gitea-mirror.db";
          HOST = "0.0.0.0";
          PORT = "4321";
          BASE_URL = "/";
          PUBLIC_BETTER_AUTH_URL = "https://gitea-mirror.nmd.jhauschildt.com}";
          # Optional concurrency controls (defaults match in-app defaults)
          # If you want perfect ordering of issues and PRs, set these at 1
          # MIRROR_ISSUE_CONCURRENCY=${MIRROR_ISSUE_CONCURRENCY:-3}
          # MIRROR_PULL_REQUEST_CONCURRENCY=${MIRROR_PULL_REQUEST_CONCURRENCY:-5}
        };
        env_file = [
          "/home/doot/secret_test/monitoring/env"
        ];
      };
    };
  };
}
