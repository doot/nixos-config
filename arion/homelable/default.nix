let
  common = import ../common.nix;
  network = import ../../common/network.nix;

  # SECRET_KEY, AUTH_USERNAME and AUTH_PASSWORD_HASH, rendered by sops-nix from
  # nixos-config-priv. Regenerate with:
  #   SECRET_KEY:         python3 -c "import secrets; print(secrets.token_hex(32))"
  #   AUTH_PASSWORD_HASH: docker compose exec backend python -c \
  #                         'import bcrypt; print(bcrypt.hashpw(b"pw", bcrypt.gensalt()).decode())'
  envFile = "/run/secrets/homelable-env";

  frontendPort = 3010;
  vhost = "homelable.${network.hosts.nix-media-docker.fqdn}";
in {
  project.name = "homelable";

  services = {
    backend = {
      service = {
        container_name = "homelable-backend";
        image = "ghcr.io/pouzor/homelable-backend:latest";
        restart = "unless-stopped";
        # nmap needs raw sockets to fingerprint hosts.
        capabilities.NET_RAW = true;
        volumes = [
          "/docker-local/homelable/data:/app/data"
        ];
        env_file = [envFile];
        environment = {
          TZ = common.tz;
          SQLITE_PATH = "/app/data/homelab.db";
          CORS_ORIGINS = ''["https://${vhost}"]'';
          SCANNER_RANGES = ''["192.168.1.0/24"]'';
        };
      };
      out.service = common.outDefaults // {cpu_shares = 512;};
    };

    # Serves the SPA and proxies /api to the backend over the project network.
    frontend = {
      service = {
        container_name = "homelable-frontend";
        image = "ghcr.io/pouzor/homelable-frontend:latest";
        restart = "unless-stopped";
        ports = [
          "${toString frontendPort}:80"
        ];
        depends_on = ["backend"];
        environment = {
          TZ = common.tz;
        };
      };
      out.service = common.outDefaults // {cpu_shares = 512;};
    };
  };
}
