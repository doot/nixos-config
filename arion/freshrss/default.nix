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
        PUID = common.puid;
        PGID = "1029"; # Differs from common.pgid ("100"); intentional for freshrss
        TZ = common.tz;
      };
    };
    out.service =
      common.outDefaults
      // {
        cpu_shares = 512;
        mem_limit = "1g";
        memswap_limit = "1g";
        healthcheck = common.mkHealthcheck 80;
      };
  };
}
