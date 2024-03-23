{
  project.name = "pihole";
  services.pihole = {
    service.image = "pihole/pihole:latest";
    service.restart = "unless-stopped";
    service.volumes = [
      "/docker-local/pihole_md/etc-pihole:/etc/pihole"
      "/docker-local/pihole_md/etc-dnsmasq.d/:/etc/dnsmasq.d"
    ];
    service.ports = [
      "53:53/tcp"
      "53:53/udp"
      "2000:80/tcp"
    ];
    service.environment = {
      TZ = "America/Los_Angeles";
      DNSMASQ_LISTENING = "all";
      # PIHOLE_DNS_: "1.1.1.1;1.0.0.1;2606:4700:4700::1111;2606:4700:4700::1001"
      PIHOLE_DNS_ = "9.9.9.9;149.112.112.112;2620:fe::fe;2620:fe::9";
      FTLCONF_LOCAL_IPV4 = "192.168.1.86";
      FTLCONF_LOCAL_IPV6 = "fe80::b898:73ff:fe75:1ba9";
      DNSSEC = "false";  # Temporarily disabled as it causes some issues with plex and other services
      # WEBPASSWORD: "set a secure password here or it will be random"
    };
    service.capabilities.NET_ADMIN = true;
    out.service.pull_policy = "always";
  };

  services.orbital-sync = {
    service.image = "mattwebbio/orbital-sync";
    service.restart = "unless-stopped";
    service.environment = {
      PRIMARY_HOST_BASE_URL = "http://pihole:80"; # TODO: replace with final host ip
      PRIMARY_HOST_PASSWORD = "-o_WqUaV";
      SECONDARY_HOST_1_BASE_URL = "http://192.168.1.60:2000";
      SECONDARY_HOST_1_PASSWORD = "dEvyeHGU";
      INTERVAL_MINUTES = "30";
    };
    service.depends_on = ["pihole"];
    out.service.pull_policy = "always";
  };
}
