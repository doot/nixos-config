{
  config,
  lib,
  pkgs,
  fqdn,
  hostname,
  domain,
  ...
}: let
  cfg = config.roles.nixos-changelog;

  notifyScript = pkgs.writeShellScript "nixos-changelog-notify" ''
    profiles=$(ls -Hdv /nix/var/nix/profiles/system-*-link 2>/dev/null | tail -2)
    if [ "$(echo "$profiles" | wc -l)" -lt 2 ]; then
      echo "Not enough system profiles to diff, skipping"
      exit 0
    fi

    old=$(echo "$profiles" | head -1)
    new=$(echo "$profiles" | tail -1)

    diff=$(${lib.getExe pkgs.nvd} --color=never diff "$old" "$new" 2>&1)

    if ! printf '%s' "$diff" | ${pkgs.gnugrep}/bin/grep -qE "^(Version changes:|Added packages:|Removed packages:)"; then
      echo "No package changes, skipping notification"
      exit 0
    fi

    printf '%s' "$diff" | ${pkgs.curl}/bin/curl \
      --silent \
      -H "Title: NixOS update: ${hostname}" \
      -H "Tags: package,nixos" \
      --data-binary @- \
      "${cfg.ntfyUrl}/${cfg.ntfyTopic}" \
      || echo "Warning: failed to post to ntfy"
  '';

  atomScript = pkgs.writeText "generate-atom.py" ''
    import json, os, sys, urllib.request
    from datetime import datetime, timezone

    NTFY_URL = "${cfg.ntfyUrl}"
    TOPIC = "${cfg.ntfyTopic}"
    FEED_DIR = "${cfg.atomFeed.feedDir}"
    FEED_FILE = FEED_DIR + "/feed.atom"
    FQDN = "${fqdn}"


    def fetch_messages():
        url = f"{NTFY_URL}/{TOPIC}/json?poll=1&since=43200m"
        try:
            with urllib.request.urlopen(url, timeout=10) as resp:
                messages = []
                for line in resp.read().decode("utf-8").strip().split("\n"):
                    if line.strip():
                        try:
                            msg = json.loads(line)
                            if msg.get("event") == "message":
                                messages.append(msg)
                        except json.JSONDecodeError:
                            pass
                return messages
        except Exception as e:
            print(f"Error fetching messages: {e}", file=sys.stderr)
            return []


    def xml_escape(text):
        return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


    def colorize_line(line):
        if line.startswith("[U") or line.startswith("[A"):
            color = "#22c55e"
        elif line.startswith("[R"):
            color = "#ef4444"
        elif line.startswith("[D"):
            color = "#eab308"
        elif line.startswith("[C"):
            color = "#06b6d4"
        elif line.startswith("&lt;&lt;&lt;") or line.startswith("&gt;&gt;&gt;") or line.startswith("Closure size:"):
            color = "#9ca3af"
        elif line.startswith("Version changes:") or line.startswith("Added packages:") or line.startswith("Removed packages:"):
            return f'&lt;span style="font-weight:bold"&gt;{line}&lt;/span&gt;'
        else:
            return line
        return f'&lt;span style="color:{color}"&gt;{line}&lt;/span&gt;'


    def to_rfc3339(ts):
        return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


    def render_content(message):
        escaped = xml_escape(message)
        body = "\n".join(colorize_line(line) for line in escaped.split("\n"))
        return f"&lt;pre style=\"font-family:monospace;font-size:13px\"&gt;{body}&lt;/pre&gt;"


    messages = sorted(fetch_messages(), key=lambda m: m.get("time", 0), reverse=True)
    updated = to_rfc3339(messages[0]["time"]) if messages else to_rfc3339(0)

    entries = "\n".join(
        f"""  <entry>
        <id>{xml_escape(m.get("id", ""))}</id>
        <title>{xml_escape(m.get("title", "NixOS update"))}</title>
        <updated>{to_rfc3339(m.get("time", 0))}</updated>
        <content type="html">{render_content(m.get("message", ""))}</content>
      </entry>"""
        for m in messages
    )

    atom = f"""<?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <id>nixos-changelog-{FQDN}</id>
      <title>NixOS Changelog</title>
      <updated>{updated}</updated>
      <link rel="self" href="https://changelog.{FQDN}/feed.atom"/>
    {entries}
    </feed>"""

    tmp = FEED_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(atom)
    os.rename(tmp, FEED_FILE)
    print(f"Written {len(messages)} entries to {FEED_FILE}")
  '';
in {
  options.roles.nixos-changelog = {
    enable =
      lib.mkEnableOption "NixOS upgrade changelog notifications via ntfy"
      // {
        default = true;
      };
    ntfyUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ntfy.nmd.${domain}";
      description = "URL of the ntfy server";
    };
    ntfyTopic = lib.mkOption {
      type = lib.types.str;
      default = "nixos-changelog";
      description = "ntfy topic for changelog notifications";
    };
    atomFeed = {
      enable = lib.mkEnableOption "Atom feed generation from ntfy messages (enable on one host only)";
      feedDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/nixos-changelog";
        description = "Directory to write the Atom feed file";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      systemd.services.nixos-changelog-notify = {
        description = "Post NixOS upgrade changelog to ntfy";
        after = ["nixos-upgrade.service"];
        wantedBy = ["nixos-upgrade.service"];
        path = [pkgs.nix];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = notifyScript;
          RemainAfterExit = false;
        };
      };
    }

    (lib.mkIf cfg.atomFeed.enable {
      systemd = {
        tmpfiles.rules = [
          "d ${cfg.atomFeed.feedDir} 0755 root root -"
        ];

        services.nixos-changelog-atom = {
          description = "Generate Atom feed from ntfy changelog messages";
          after = ["network-online.target"];
          wants = ["network-online.target"];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.python3}/bin/python3 ${atomScript}";
          };
        };

        timers.nixos-changelog-atom = {
          description = "Atom feed generation timer";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = "15min";
          };
        };
      };

      services.nginx.virtualHosts."changelog.${fqdn}" = {
        useACMEHost = fqdn;
        forceSSL = true;
        locations."/" = {
          root = cfg.atomFeed.feedDir;
          extraConfig = ''
            add_header Content-Type "application/atom+xml; charset=utf-8";
            try_files /feed.atom =404;
          '';
        };
      };
    })
  ]);
}
