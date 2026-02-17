let
  common = import ../common.nix;
in {
  project.name = "monitoring";

  services = {
    cadvisor = {
      service = {
        image = "gcr.io/cadvisor/cadvisor:v0.52.0"; # TODO: latest tag is over a year old, switch back once it's ben updated
        privileged = true;
        restart = "unless-stopped";
        command = [
          "-housekeeping_interval=30s"
          "-store_container_labels=false"
        ];
        volumes = [
          "/:/rootfs:ro"
          "/var/run:/var/run:rw"
          "/sys:/sys:ro"
          "/var/lib/docker/:/var/lib/docker:ro"
          "/dev/disk/:/dev/disk:ro"
        ];
        ports = [
          "8080:8080"
        ];
      };
      out.service =
        common.outDefaults
        // {
          mem_limit = "1g";
          memswap_limit = "1g";
        };
    };
    nut-exporter = {
      service = {
        image = "hon95/prometheus-nut-exporter:latest";
        restart = "unless-stopped";
        environment = {
          TZ = common.tz;
          HTTP_PATH = "/metrics";
          # Defaults
          # RUST_LOG = "info";
          # HTTP_PORT = 9995;
          # HTTP_PATH = "/nut";
          # LOG_REQUESTS_CONSOLE = false;
          # PRINT_METRICS_AND_EXIT = false;
        };
        ports = [
          "9995:9995"
        ];
      };
      out.service =
        common.outDefaults
        // {
          mem_limit = "1g";
          memswap_limit = "1g";
        };
    };
  };
}
