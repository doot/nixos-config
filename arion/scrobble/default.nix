{
  project.name = "scrobble";
  services.maloja = {
    service.build.context = "https://github.com/krateng/maloja.git";
    service.build.dockerfile = "./Containerfile";
    # service.image = "krateng/maloja:latest"; # Image outdated
    service.restart = "unless-stopped";
    service.ports = [
      "42010:42010"
    ];
    service.volumes = [
      "/docker-nfs/scrobble/maloja/config:/config/config"
      "/docker-nfs/scrobble/maloja/data:/config/state"
      "/docker-nfs/scrobble/maloja/logs:/config/logs"
      "/docker-nfs/scrobble/maloja/cache:/config/cache"
    ];
    service.environment = {
      PUID = 1029;
      PGID = 100;
      TZ = "America/Los_Angeles";
    };
    service.healthcheck = {
      test = ["CMD-SHELL" "curl localhost:42010/"];
      interval = "30s";
      timeout = "15s";
      retries = 3;
    };
    out.service.pull_policy = "always";
    out.service.cpu_shares = 256;
    out.service.mem_limit = "2g";
    out.service.memswap_limit = "2g";
  };
  services.multi-scrobbler = {
    service.image = "foxxmd/multi-scrobbler";
    service.restart = "unless-stopped";
    service.ports = [
      "9078:9078"
    ];
    service.volumes = [
      "/docker-nfs/scrobble/multi-scrobbler:/config"
    ];
    service.environment = {
      PUID = 1029;
      PGID = 100;
      TZ = "America/Los_Angeles";
      # set if using a source/client with redirect URI that you have not explicitly set and MS is NOT running on the same machine that you will view the dashboard from
      # EX: You will view MS dashboard at 'http://192.168.0.101:9078' -> set BASE_URL=http://192.168.0.101:9078
      #- BASE_URL=http://MyHostIP:9078
    };
    service.healthcheck = {
      test = ["CMD-SHELL" "curl localhost:9078/"];
      interval = "30s";
      timeout = "15s";
      retries = 3;
    };
    out.service.pull_policy = "always";
    out.service.cpu_shares = 256;
    out.service.mem_limit = "2g";
    out.service.memswap_limit = "2g";
    service.depends_on = {
      maloja.condition = "service_healthy";
    };
  };
}
