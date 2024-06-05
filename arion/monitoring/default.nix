{
  project.name = "monitoring";

  services.cadvisor = {
    service.image = "gcr.io/cadvisor/cadvisor";
    service.privileged = true;
    service.restart = "unless-stopped";
    service.volumes = [
      "/:/rootfs:ro"
      "/var/run:/var/run:rw"
      "/sys:/sys:ro"
      "/var/lib/docker/:/var/lib/docker:ro"
      "/dev/disk/:/dev/disk:ro"
    ];
    service.ports = [
      "8080:8080"
    ];
    out.service.pull_policy = "always";
    out.service.cpu_shares = 256;
    out.service.mem_limit = "1g";
    out.service.memswap_limit = "1g";
  };

  services.nut-exporter = {
    service.image = "hon95/prometheus-nut-exporter:latest";
    service.restart = "unless-stopped";
    service.environment = {
      TZ = "America/Los_Angeles";
      HTTP_PATH = "/metrics";
      # Defaults
      # RUST_LOG = "info";
      # HTTP_PORT = 9995;
      # HTTP_PATH = "/nut";
      # LOG_REQUESTS_CONSOLE = false;
      # PRINT_METRICS_AND_EXIT = false;
    };
    service.ports = [
      "9995:9995"
    ];
    out.service.pull_policy = "always";
    out.service.cpu_shares = 256;
    out.service.mem_limit = "1g";
    out.service.memswap_limit = "1g";
  };
}
