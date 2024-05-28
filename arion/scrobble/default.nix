{
  project.name = "scrobble";
  services.maloja = {
    service.image = "krateng/maloja:latest";
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
}
