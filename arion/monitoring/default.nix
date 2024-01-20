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
  };
}
