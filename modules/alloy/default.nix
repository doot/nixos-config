{
  pkgs,
  hostname,
  config,
  lib,
  ...
}: let
  cfg = config.roles.alloy;
in {
  options.roles.alloy = {
    enable =
      lib.mkEnableOption "alloy role"
      // {
        default = true;
      };
    withSyslogListener = lib.mkEnableOption "Whether to enable the alloy syslog listener (opens port) ";
    alloyPort = lib.mkOption {
      type = lib.types.port;
      default = 3030;
      description = "Port for the Alloy HTTP server.";
    };
    syslogPort = lib.mkOption {
      type = lib.types.port;
      default = 1514;
      description = "Port for the syslog listener.";
    };
    lokiHost = lib.mkOption {
      type = lib.types.str;
      default = "nmd.jhauschildt.com";
      description = "Hostname of the Loki instance.";
    };
    lokiPort = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      description = "Port of the Loki instance.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.alloy = {
      enable = true;
      package = pkgs.unstable.grafana-alloy;
      extraFlags = [
        "--server.http.listen-addr=0.0.0.0:${toString cfg.alloyPort}"
        "--disable-reporting"
      ];
    };

    networking.firewall.allowedTCPPorts =
      [
        cfg.alloyPort # Alloy web ui
      ]
      ++ lib.optionals cfg.withSyslogListener [
        cfg.syslogPort # syslog listen port
      ];

    environment.etc."alloy/config.alloy".text = ''
      local.file_match "local_files" {
        path_targets = [{"__path__" = "/var/log/*.log"}]
        sync_period = "5s"
      }
      loki.source.file "log_scrape" {
        targets    = local.file_match.local_files.targets
        forward_to = [loki.process.filter_logs.receiver]
        tail_from_end = true
      }
      loki.process "filter_logs" {
        stage.drop { source = ""
          expression  = ".*Connection closed by authenticating user root"
          drop_counter_reason = "noisy"
        }
        forward_to = [loki.write.grafana_loki.receiver]
      }
      loki.write "grafana_loki" {
        endpoint {
          url = "http://${cfg.lokiHost}:${toString cfg.lokiPort}/loki/api/v1/push"
        }
      }

      // journald
      discovery.relabel "journal" {
        targets = []

        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "unit"
        }
      }

      loki.source.journal "journal" {
        max_age       = "12h0m0s"
        relabel_rules = discovery.relabel.journal.rules
        forward_to    = [loki.write.grafana_loki.receiver]
        labels        = {
          host = "${hostname}",
          job  = "systemd-journal",
        }
      }

      ${lib.optionalString cfg.withSyslogListener ''
        // rsyslog
        loki.relabel "syslog" {
          forward_to = []
          rule {
            source_labels = ["__syslog_message_hostname"]
            target_label  = "host"
          }
        }

        loki.source.syslog "syslog" {
          listener {
            address = "${cfg.lokiHost}:${toString cfg.syslogPort}"
            label_structured_data = true
            labels = {
              job  = "syslog",
            }
          }

          forward_to = [loki.write.grafana_loki.receiver]
          relabel_rules = loki.relabel.syslog.rules
        }
      ''}
    '';
  };
}
