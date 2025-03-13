{
  project.name = "pihole";

  services = {
    pihole = {
      service = {
        image = "pihole/pihole:latest";
        restart = "unless-stopped";
        volumes = [
          "/docker-local/pihole_md/etc-pihole:/etc/pihole"
          "/docker-local/pihole_md/etc-dnsmasq.d/:/etc/dnsmasq.d"
        ];
        ports = [
          "53:53/tcp"
          "53:53/udp"
          "2000:80/tcp"
        ];
        environment = {
          TZ = "America/Los_Angeles";
          FTLCONF_dns_listeningMode = "all";
          # FTLCONF_dns_upstreams = "9.9.9.9;149.112.112.112;2620:fe::fe;2620:fe::9";
          FTLCONF_dns_upstreams = "192.168.1.1";
          FTLCONF_dns_dnssec = "false"; # Temporarily disabled as it causes some issues with plex and other services
        };
        capabilities.NET_ADMIN = true;
        capabilities.SYS_NICE = true;
        networks = ["piholenet"];
      };
      out.service.pull_policy = "always";
      out.service.shm_size = "250mb";
    };

    orbital-sync = {
      service = {
        image = "ghcr.io/mattwebbio/orbital-sync:master";
        # TODO: switch this back to stable after v6 changes are released
        restart = "unless-stopped";
        environment = {
          PRIMARY_HOST_BASE_URL = "https://pihole.nmd.jhauschildt.com";
          SECONDARY_HOST_1_BASE_URL = "https://pihole2.nmd.jhauschildt.com";
          INTERVAL_MINUTES = "30";
        };
        env_file = [
          # Sets PRIMARY_HOST_PASSWORD and SECONDARY_HOST_1_PASSWORD
          "/home/doot/secret_test/orbital-sync/env"
        ];
        depends_on = {
          pihole.condition = "service_healthy";
        };
      };
      out.service.pull_policy = "always";
    };
  };
  networks = {
    piholenet = {
      enable_ipv6 = true;
      ipam = {
        config = [
          {
            subnet = "fd18:9732:5931:3::/64";
          }
        ];
      };
    };
  };
}
