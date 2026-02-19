let
  common = import ../common.nix;
in {
  project.name = "plex";
  services.plex = {
    service = {
      image = "lscr.io/linuxserver/plex:latest";
      restart = "unless-stopped";
      network_mode = "host";
      ports = [
        "8181:8181"
      ];
      environment = {
        TZ = common.tz;
        PUID = common.puid;
        PGID = common.pgid;
        VERSION = "latest";
      };
      volumes = [
        "/plex/config:/config"
        "/plex/transcode:/transcode"
        "/media-nfs:/data"
        "/pictures-nfs:/pictures"
      ];
      devices = [
        "/dev/dri:/dev/dri"
      ];
      healthcheck = {
        test = ["CMD-SHELL" "curl --connect-timeout 15 --max-time 100 --silent --show-error --fail http://localhost:32400/identity > /dev/null || exit 1"];
        interval = "5s";
        timeout = "2s";
        retries = 20;
        start_period = "1m";
      };
    };
    out.service =
      common.outDefaults
      // {
        shm_size = "12gb"; # Necessary because shm_size does not appear to be implemented in Arion
        cpu_shares = 2048;
        mem_limit = "15g";
      };
  };

  services.tautulli = {
    service = {
      image = "linuxserver/tautulli";
      restart = "unless-stopped";
      network_mode = "service:plex";
      environment = {
        TZ = common.tz;
        PUID = common.puid;
        PGID = common.pgid;
      };
      volumes = [
        "/docker-nfs/plexpy:/config"
        "/plex/config/Library/Application Support/Plex Media Server/Logs:/logs:ro"
        "/etc/localtime:/etc/localtime:ro"
      ];
      depends_on = {
        plex.condition = "service_healthy";
      };
      healthcheck = common.mkHealthcheck 8181;
    };
    out.service = common.outDefaults;
  };
}
