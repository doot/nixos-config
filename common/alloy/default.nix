{
  pkgs,
  hostname,
  ...
}: let
  alloy_port = 3030;
  syslog_port = 1514;
  loki_host = "nmd.jhauschildt.com";
in {
  services.alloy = {
    enable = true;
    package = pkgs.unstable.grafana-alloy;
    extraFlags = [
      "--server.http.listen-addr=0.0.0.0:${toString alloy_port}"
    ];
  };

  networking.firewall.allowedTCPPorts = [
    alloy_port # Alloy web ui
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
      stage.drop {
        source = ""
        expression  = ".*Connection closed by authenticating user root"
        drop_counter_reason = "noisy"
      }
      forward_to = [loki.write.grafana_loki.receiver]
    }
    loki.write "grafana_loki" {
      endpoint {
        url = "http://${loki_host}:3100/loki/api/v1/push"

        // basic_auth {
        //  username = "admin"
        //  password = "admin"
        // }
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

    // rsyslog
    // TODO: this should not go in common config, needs to only apply to nmd config since it is a listener
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
  '';
}
