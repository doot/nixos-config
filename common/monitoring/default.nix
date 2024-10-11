{
  config,
  pkgs,
  lib,
  ...
}: let
  loki_port = 3100;
in {
  # This is necessary since the NixOS Prometheus services does not have an easy way to set the data directory
  fileSystems."/var/lib/prometheus2/data" = {
    depends = [
      "/docker-nfs/monitoring/prometheus_data"
      "/var/lib/prometheus2/data"
    ];
    device = "/docker-nfs/monitoring/prometheus_data";
    fsType = "none";
    options = ["bind"];
  };

  # # This isn't necessary at all, but I'm fucking lazy
  # fileSystems."/var/lib/grafana/data" = {
  #   depends = [
  #     "/docker-nfs/monitoring/graphana"
  #     "/var/lib/grafana/data"
  #   ];
  #   device = "/docker-nfs/monitoring/graphana";
  #   fsType = "none";
  #   options = [ "bind" ];
  # };

  # Override the user of the Grafana systemd unit to docker-media, as this the way the mounted NFS directory is set up.
  # systemd.services.grafana.serviceConfig.User = lib.mkForce "docker-media"; # this doesn't actually work well...
  systemd.services.prometheus.serviceConfig.User = lib.mkForce "docker-media";

  services = {
    grafana = {
      package = pkgs.unstable.grafana;
      enable = true;
      # TODO Temorarily disable declarative plugins to try out a few plugins which are not available in nixpkgs
      # declarativePlugins = with pkgs.grafanaPlugins; [
      #   grafana-piechart-panel
      #   grafana-clock-panel
      #   grafana-worldmap-panel
      #   # natel-discrete-panel
      # ];
      settings = {
        # TODO for now database exists in default of /var/lib/grafana/data/grafana.db and is not backed up, except for snapshots. Get a proper set up working. Fucking permissions.
        # database.path = "/docker-nfs/monitoring/grafana/grafana.db";
        server = {
          # Listening Address
          http_addr = "127.0.0.1";
          # and Port
          http_port = 3000;
          # Grafana needs to know on which domain and URL it's running
          domain = "nmd.jhauschildt.com";
          root_url = "https://nmd.jhauschildt.com/grafana/";
          serve_from_sub_path = true;
        };
      };
      # provision.datasources.settings.deleteDatasources = [{name="Prometheus2"; orgId = 1;}];
      provision.datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://localhost:${toString config.services.prometheus.port}";
        }
        {
          name = "Loki";
          type = "loki";
          access = "proxy";
          url = "http://localhost:${toString loki_port}";
        }
      ];
    };

    prometheus = {
      enable = true;
      port = 9001;
      retentionTime = "1y";

      exporters.pve = {
        enable = true;
        port = 9221;
        configFile = "/docker-nfs/monitoring/pve-exporter/pve.yml";
      };

      exporters.unpoller = {
        enable = true;
        controllers = [
          {
            user = "unifipoller";
            pass = "/etc/nixos/shared_secret_test/unpoller/pass";
            url = "https://192.168.1.1:443";
            verify_ssl = false;
          }
        ];
      };

      scrapeConfigs = [
        {
          # This is enabled by default in common/default.nix for all NixOS hosts
          job_name = "nix-media-docker";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.exporters.node.port}"];
            }
          ];
        }
        {
          job_name = "nix-shitfucker";
          static_configs = [
            {
              targets = ["192.168.1.110:${toString config.services.prometheus.exporters.node.port}"];
            }
          ];
        }
        {
          job_name = "cadvisor-nmd";
          scrape_interval = "30s";
          static_configs = [
            {
              targets = ["127.0.0.1:8080"];
            }
          ];
        }
        {
          job_name = "docker-nmd";
          static_configs = [
            {
              targets = ["127.0.0.1:9323"];
            }
          ];
        }
        {
          job_name = "unifipoller";
          static_configs = [
            {
              targets = ["localhost:${toString config.services.prometheus.exporters.unpoller.port}"];
            }
          ];
        }
        {
          job_name = "pve";
          static_configs = [
            {
              targets = ["192.168.1.80"];
            }
          ];
          metrics_path = "/pve";
          params.module = ["default"];
          relabel_configs = [
            {
              source_labels = ["__address__"];
              target_label = "__param_target";
            }
            {
              source_labels = ["__param_target"];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "192.168.1.88:${toString config.services.prometheus.exporters.pve.port}"; # PVE exporter.
            }
          ];
        }
        {
          job_name = "nut-exporter";
          honor_timestamps = true;
          scrape_interval = "30s";
          scrape_timeout = "10s";
          metrics_path = "/metrics";
          scheme = "http";
          # follow_redirects = true;
          # enable_http2 = true;
          static_configs = [
            {
              # NUT server address
              targets = ["192.168.1.60:3493"];
            }
          ];
          relabel_configs = [
            {
              source_labels = ["__address__"];
              target_label = "__param_target";
            }
            {
              source_labels = ["__param_target"];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "192.168.1.88:9995";
            }
          ];
        }
      ];
    };

    loki = {
      enable = true;
      configuration = {
        auth_enabled = false;
        analytics.reporting_enabled = false;
        server = {http_listen_port = loki_port;};
        common = {
          ring = {
            instance_addr = "0.0.0.0";
            kvstore = {store = "inmemory";};
          };
          replication_factor = 1;
          path_prefix = "/tmp/loki";
        };
        schema_config = {
          configs = [
            {
              from = "2020-05-15";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
        };
        storage_config = {
          filesystem = {
            directory = "/var/lib/loki/chunks";
          };
        };
        limits_config = {volume_enabled = true;};
      };
      extraFlags = [
        "--pattern-ingester.enabled=true"
        "--server.http-listen-port=${toString loki_port}"
      ];
    };

    nginx = {
      enable = true;
      virtualHosts.${config.services.grafana.settings.server.domain} = {
        locations."/grafana" = {
          proxyPass = "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    # config.services.grafana.settings.server.http_port # Grafana web ui: 3000 TODO remove, nginx is over port 80 for now...
    80 # nginx proxy
    config.services.prometheus.port # Prometheus web ui
    loki_port # loki push
  ];
}
