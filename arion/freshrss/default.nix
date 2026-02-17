let
  common = import ../common.nix;
in {
  project.name = "freshrss";
  services.freshrss = {
    service = {
      image = "lscr.io/linuxserver/freshrss:latest";
      restart = "unless-stopped";
      volumes = [
        "/docker-local/freshrss/data:/config"
      ];
      ports = [
        "8666:80"
      ];
      environment = {
        PUID = 1029;
        PGID = 1029;
        TZ = common.tz;
      };
    };
    out.service =
      common.outDefaults
      // {
        cpu_shares = 512;
        mem_limit = "1g";
        memswap_limit = "1g";
        healthcheck = {
          test = ["CMD-SHELL" "curl --fail localhost:80/ || exit 1"];
          interval = "30s";
          timeout = "15s";
          retries = 3;
          start_period = "1m";
        };
      };
  };
}
