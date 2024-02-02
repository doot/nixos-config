{
  project.name = "plex";
  services.plex = {
    out.service.shm_size = "10gb"; # Necessary because shm_size does not appear to be implemented in Arion
    service.image = "plexinc/pms-docker:beta";
    service.restart = "unless-stopped";
    service.network_mode = "host";
    service.ports = [
      "8181:8181"
    ];
    service.environment = {
      TZ = "America/Los_Angeles";
      PLEX_UID = "1029";
      PLEX_GID = "100";
    };
    service.volumes = [
      "/plex/config:/config"
      "/plex/transcode:/transcode"
      "/media-nfs:/data"
      "/pictures-nfs:/pictures"
    ];
    service.devices = [
      "/dev/dri:/dev/dri"
    ];
  };

  services.tautulli = {
    service.image = "linuxserver/tautulli";
    service.restart = "unless-stopped";
    service.network_mode = "service:plex";
    service.environment = {
      TZ = "America/Los_Angeles";
      PUID = "1029";
      PGID = "100";
    };
    service.volumes = [
      "/docker-nfs/plexpy:/config"
      "/plex/config/Library/Application Support/Plex Media Server/Logs:/logs:ro"
      "/etc/localtime:/etc/localtime:ro"
    ];
    out.service.cpu_shares = 256;
    out.service.mem_limit = "1g";
    out.service.memswap_limit = "2g";
    service.depends_on = {
      plex.condition = "service_healthy";
    };
    service.healthcheck = {
      test = ["CMD-SHELL" "curl localhost:8181/"];
      interval = "30s";
      timeout = "15s";
      retries = 3;
    };
  };
}
