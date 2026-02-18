let
  common = import ../common.nix;
in {
  project.name = "scrobble";

  services.maloja = {
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
      healthcheck = {
        test = ["CMD-SHELL" "curl --fail localhost:42010/ || exit 1"];
        interval = "30s";
        timeout = "15s";
        retries = 3;
        start_period = "1m";
      };
    };
    out.service = common.outDefaults;
  };

  services.multi-scrobbler = {
    service = {
      image = "foxxmd/multi-scrobbler";
      restart = "unless-stopped";
      ports = [
        "9078:9078"
      ];
      volumes = [
        "/docker-nfs/scrobble/multi-scrobbler:/config"
      ];
      environment = {
        PUID = common.puid;
        PGID = common.pgid;
        TZ = common.tz;
        # set if using a source/client with redirect URI that you have not explicitly set and MS is NOT running on the same machine that you will view the dashboard from
        # EX: You will view MS dashboard at 'http://192.168.0.101:9078' -> set BASE_URL=http://192.168.0.101:9078
        #- BASE_URL=http://MyHostIP:9078
      };
      healthcheck = {
        test = ["CMD-SHELL" "curl --fail localhost:9078/api/health || exit 1"];
        interval = "30s";
        timeout = "15s";
        retries = 3;
        start_period = "1m";
      };
      depends_on = {
        maloja.condition = "service_healthy";
      };
    };
    out.service = common.outDefaults;
  };
}
