{
  config,
  pkgs,
  lib,
  fqdn,
  domain,
  ...
}: let
  loki_port = 3100;
  nsf_fqdn = "nsf.${domain}";
  sh_fqdn = "sh2.${domain}";
  pve_fqdn = "pve.${domain}";
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

  systemd = {
    services = {
      # Override the user of the Grafana systemd unit to docker-media, as this the way the mounted NFS directory is set up.
      # systemd.services.grafana.serviceConfig.User = lib.mkForce "docker-media"; # this doesn't actually work well...
      prometheus.serviceConfig.User = lib.mkForce "docker-media";

      # Explicitly add an EnvironmentFile to the pihole-exporter systemd unit as the module does not provide a way to do this natively
      prometheus-pihole-exporter.serviceConfig.EnvironmentFile = lib.mkForce "/home/doot/secret_test/pihole-exporter/primary.env";
    };
  };

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
        analytics.reporting_enabled = false;
        server = {
          # Listening Address
          http_addr = "127.0.0.1";
          # and Port
          http_port = 3000;
          # Grafana needs to know on which domain and URL it's running
          domain = "grafana.${fqdn}";
          root_url = "https://grafana.${fqdn}/";
          serve_from_sub_path = true;
        };
        feature_toggles = {
          # Toggles for enabling experimental GitSync
          provisioning = true;
          kubernetesClientDashboardsFolders = true;
          kubernetesDashboards = true;
          grafanaAPIServerEnsureKubectlAccess = true;

          # Toggles experimental dynamic dashboards
          dashboardNewLayouts = true;
        };
      };
      # provision.datasources.settings.deleteDatasources = [{name="Prometheus2"; orgId = 1;}];
      provision.datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          access = "proxy";
          url = "https://prom.${fqdn}";
        }
        {
          name = "Loki";
          type = "loki";
          access = "proxy";
          url = "http://127.0.0.1:${toString loki_port}";
        }
      ];
    };

    prometheus = {
      enable = true;
      port = 9001;
      retentionTime = "1y";

      package = pkgs.unstable.prometheus;

      exporters.pve = {
        enable = true;
        port = 9221;
        configFile = "/docker-nfs/monitoring/pve-exporter/pve.yml";
      };

      exporters.unpoller = {
        enable = true;
        loki = {
          # url = "http://127.0.0.1:${toString loki_port}/loki/api/v1/push";
          url = "http://127.0.0.1:${toString loki_port}";
        };
        controllers = [
          {
            user = "unifipoller";
            pass = "/etc/nixos/shared_secret_test/unpoller/pass";
            url = "https://192.168.1.1:443";
            verify_ssl = false;
            save_dpi = true; # May be resource intensive, disable if it causes problems
            # enable loki and then try out the following:
            save_events = true;
            save_anomalies = true;
          }
        ];
      };

      exporters.nginx = {
        enable = true;
      };

      exporters.pihole = {
        # TODO: re-enable once fix to command line args is released and in nixpkgs
        enable = false;
        protocol = "https";
        piholePort = 443;
        piholeHostname = "pihole.nmd.jhauschildt.com";
        # TODO: password is provided via overriden systemd EnvironmentFile (secret_test/pihole-exporter/primary.env) above until module has a better option
      };

      scrapeConfigs = [
        {
          # The node exporter is enabled by default in common/default.nix for all NixOS hosts
          job_name = "node";
          static_configs = [
            {
              targets = [
                "${fqdn}:${toString config.services.prometheus.exporters.node.port}"
                "${nsf_fqdn}:${toString config.services.prometheus.exporters.node.port}"
                # "192.168.1.80:9100"
                "${pve_fqdn}:9100"
              ];
            }
          ];
        }
        {
          # The systemd exporter is enabled by default in common/default.nix for all NixOS hosts
          job_name = "systemd";
          static_configs = [
            {
              targets = [
                "${fqdn}:${toString config.services.prometheus.exporters.systemd.port}"
                "${nsf_fqdn}:${toString config.services.prometheus.exporters.systemd.port}"
              ];
            }
          ];
        }
        {
          job_name = "cadvisor";
          scrape_interval = "30s";
          static_configs = [
            {
              targets = ["${fqdn}:8080"];
            }
          ];
        }
        {
          job_name = "docker";
          static_configs = [
            {
              targets = ["${fqdn}:${toString (lib.tail (lib.splitString ":" config.virtualisation.docker.daemon.settings.metrics-addr))}"];
            }
          ];
        }
        {
          job_name = "unifipoller";
          static_configs = [
            {
              targets = ["${fqdn}:${toString config.services.prometheus.exporters.unpoller.port}"];
            }
          ];
        }
        {
          job_name = "pve";
          static_configs = [
            {
              targets = [pve_fqdn];
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
              replacement = "${fqdn}:${toString config.services.prometheus.exporters.pve.port}"; # PVE exporter.
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
              targets = ["${sh_fqdn}:3493"];
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
              replacement = "${fqdn}:9995";
            }
          ];
        }
        {
          job_name = "nginx";
          static_configs = [
            {
              targets = [
                "${fqdn}:${toString config.services.prometheus.exporters.nginx.port}"
              ];
            }
          ];
        }
        # TODO: re-enable once fix to command line args is released and in nixpkgs (see pihole exporter above)
        # {
        #   job_name = "pihole";
        #   static_configs = [
        #     {
        #       targets = [
        #         "${fqdn}:${toString config.services.prometheus.exporters.pihole.port}"
        #       ];
        #     }
        #   ];
        # }
      ];
    };

    loki = {
      enable = true;
      package = pkgs.unstable.grafana-loki;
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
        "--log.level=warn"
      ];
    };

    nginx = {
      enable = true;
      virtualHosts."grafana.${fqdn}" = {
        default = true;
        useACMEHost = fqdn;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
          proxyWebsockets = true;
        };
      };
      virtualHosts."prom.${fqdn}" = {
        useACMEHost = fqdn;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.prometheus.port}";
          proxyWebsockets = true;
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    # TODO Extract this to common nginx config
    80 # nginx proxy
    443 # nginx proxy
    loki_port # loki push
  ];
}
