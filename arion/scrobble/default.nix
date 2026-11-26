let
  common = import ../common.nix;
in {
  project.name = "scrobble";

  services = {
    maloja = {
      service = {
        # build.context = "https://github.com/krateng/maloja.git";
        # build.dockerfile = "./Containerfile";
        image = "krateng/maloja:latest"; # Image outdated
        restart = "unless-stopped";
        ports = [
          "42010:42010"
        ];
        volumes = [
          "/docker-nfs/scrobble/maloja/config:/config/config"
          "/docker-nfs/scrobble/maloja/data:/config/state"
          "/docker-nfs/scrobble/maloja/logs:/config/logs"
          "/docker-nfs/scrobble/maloja/cache:/config/cache"
        ];
        environment = {
          PUID = common.puid;
          PGID = common.pgid;
          TZ = common.tz;
        };
        healthcheck = common.mkHealthcheck 42010;
      };
      out.service = common.outDefaults;
    };

    multi-scrobbler = {
      service = {
        image = "foxxmd/multi-scrobbler";
        restart = "unless-stopped";
        ports = [
          "9078:9078"
        ];
        volumes = [
          "/docker-nfs/scrobble/multi-scrobbler:/config"
        ];
        user = "${common.puid}:${common.pgid}";
        capabilities.ALL = false;
        security_opt = ["no-new-privileges:true"];
        environment = {
          BASE_URL = "https://ms.nmd.jhauschildt.com";
          TZ = common.tz;
          CACHE_VALKEY = "redis://valkey:6379";
          RANDOM = "RANDOM";
        };
        healthcheck = {
          test = [
            "CMD"
            "/nodejs/bin/node"
            "--input-type=module"
            "-e"
            "process.exit((await fetch('http://127.0.0.1:9078/api/health', {redirect: 'manual'})).ok ? 0 : 1)"
          ];
          interval = "30s";
          timeout = "15s";
          retries = 3;
          start_period = "1m";
        };
        depends_on = {
          maloja.condition = "service_healthy";
          valkey.condition = "service_healthy";
        };
      };
      out.service = common.outDefaults;
    };

    valkey = {
      service = {
        image = "valkey/valkey:latest";
        restart = "unless-stopped";
        volumes = [
          "valkeydata:/data"
        ];
        healthcheck = {
          test = ["CMD" "valkey-cli" "-p" "6379" "ping"];
          interval = "60s";
          timeout = "15s";
          retries = 3;
          start_period = "30s";
        };
      };
      out.service = common.outDefaults;
    };
  };

  docker-compose.volumes = {
    valkeydata = {
      driver = "local";
    };
  };
}
