{
  pkgs,
  hostname,
  config,
  lib,
  ...
}: let
  cfg = config.roles.alloy;
  alloy_port = 3030;
  syslog_port = 1514;
  loki_host = "nmd.jhauschildt.com";
in {
  options.roles.alloy = {
    enable =
      lib.mkEnableOption "alloy role"
      // {
        default = true;
      };
    withSyslogListener = lib.mkEnableOption "Whether to enable the alloy syslog listener (opens port) ";
    # TODO move ports to options here, with defaults...
  };
  config = lib.mkIf cfg.enable {
    services.alloy = {
      enable = true;
      package = pkgs.unstable.grafana-alloy;
      extraFlags = [
        "--server.http.listen-addr=0.0.0.0:${toString alloy_port}"
        "--disable-reporting"
      ];
    };

    networking.firewall.allowedTCPPorts =
      [
        alloy_port # Alloy web ui
      ]
      ++ lib.optionals cfg.withSyslogListener [
        syslog_port # syslog listen port
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
          url = "http://${loki_host}:3100/loki/api/v1/push"
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
            address = "${loki_host}:${toString syslog_port}"
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
