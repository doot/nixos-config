let
  common = import ../common.nix;
  settings = import ./settings.nix;
in {
  project.name = "watchstate";
  services.watchstate = {
    service = {
      image = "ghcr.io/arabcoders/watchstate:v1.10.5@sha256:810cc6dafda19b9a6abab3527ead1cd044962d157acf230491d169c5e2493bbb";
      restart = "unless-stopped";
      user = "${common.puid}:${common.pgid}";
      capabilities.ALL = false;
      volumes = [
        "${settings.dataDir}:/config"
      ];
      ports = [
        "127.0.0.1:${toString settings.port}:8080"
      ];
      environment = {
        TZ = common.tz;
        UMASK = "0077";
        WS_SECURE_API_ENDPOINTS = "true";
        WS_TRUST_PROXY = "true";
        WS_TRUST_HEADER = "X-WatchState-Client-IP";
        WS_TRUST_LOCAL = "false";
      };
    };
    out.service =
      common.outDefaults
      // {
        security_opt = ["no-new-privileges:true"];
      };
  };
}
