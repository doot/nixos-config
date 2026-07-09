{
  lib,
  pkgs,
  modulesPath,
  config,
  outputs,
  fqdn,
  ...
}: let
  network = import ../../common/network.nix;
in {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ./hardware-configuration.nix # Include the results of the hardware scan.
  ];

  environment.systemPackages = with pkgs; [
    arion
    distrobox
    docker-compose
    python3
  ];

  system = {
    stateVersion = "23.11";

    autoUpgrade = {
      flags = [
        "--override-input"
        "priv"
        "/home/doot/nixos-config-priv"
      ];

      # This system is in lxc container, so it will never have kernel upgrades. All upgrades fail when this is enabled due to trying to read boot symlinks that don't exist.
      allowReboot = lib.mkForce false;
    };
  };

  boot = {
    isContainer = true;
  };

  # Disable stub and override default nameservers, pihole use port 53 instead
  networking = {
    nameservers = [network.ips.nix-media-docker network.ips.shitholder]; # override due to disabled stub listener
    firewall.allowedTCPPorts = [
      32400 # Plex
    ];
  };
  services.resolved.settings.Resolve.DNSStubListener = "no";

  virtualisation = {
    docker = {
      enable = true;
      enableOnBoot = true;
      autoPrune = {
        enable = true;
        dates = "daily";
        flags = ["--all"];
      };
      # rootless = {
      #   enable = true;
      #   # setSocketVariable = true;
      # };
      daemon = {
        settings = {
          metrics-addr = "0.0.0.0:9323";
          ipv6 = true;
          fixed-cidr-v6 = "fd18:9732:5931:1::/64";
        };
      };
    };

    arion = {
      backend = "docker";
      projects =
        lib.genAttrs
        ["pihole" "freshrss" "librenms" "plex" "monitoring" "scrobble"]
        (name: {
          serviceName = name; # systemd service name
          settings.imports = [../../arion/${name}];
        });
    };
  };

  # Supress systemd units that don't work because of LXC
  systemd = {
    suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
    ];

    # Start tty0 on serial console (needed for proxmox console)
    services = {
      "getty@tty1" = {
        enable = lib.mkForce true;
        wantedBy = ["getty.target"]; # to start at boot
        serviceConfig.Restart = "always"; # restart when session is closed
      };

      # Prevent netbird from starting a resolver on port 53, because that fucks shit up, especially on this host that runs a dns server
      netbird.serviceConfig.Environment = [
        "NB_DNS_RESOLVER_ADDRESS=127.0.0.1:4053"
      ];

      # Ensure that mediaDir is not mounted read-only. Systemd unit sets DynamicUser=yes, which implicitly sets ProtectSystem=strict, which mounts everything
      # read-only
      pinchflat.serviceConfig.ReadWritePaths = config.services.pinchflat.mediaDir;

      # TODO: This appears to be required for karakeep-browser to work at the moment. Move this into a module and into a VM rather than container
      karakeep-browser.serviceConfig.PrivateDevices = lib.mkForce "no";
    };
  };

  programs.git.config = {
    # Prevent errors due to ownership of this special override repo
    safe.directory = [
      "/home/doot/nixos-config-priv/.git"
      "/home/doot/nixos-config-priv"
    ];
  };

  # TODO: This appears to be required for karakeep-browser to work at the moment. Move this into a module and into a VM rather than container
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services = {
    ntfy-sh = {
      enable = true;
      # Secret env file providing NTFY_AUTH_USERS + NTFY_AUTH_TOKENS. Generate
      # with `ntfy user hash` (bcrypt) and `ntfy token generate`:
      #   NTFY_AUTH_USERS='hermes...user'
      #   NTFY_AUTH_TOKENS='herme...gent comms'
      environmentFile = "/home/doot/secret_test/ntfy/env";
      settings = {
        base-url = "https://ntfy.${fqdn}";
        listen-http = ":2586";
        behind-proxy = true;
        cache-duration = "720h";
        message-size-limit = "32K";
        # Private instance: deny by default, grant per topic. Users and tokens
        # come from environmentFile above.
        auth-default-access = "deny-all";
        auth-access = [
          # Agent comms channel: agent (token) + phone (password), read-write.
          "hermes:hermes-agent:rw"
          "doot:hermes-agent:rw"
          # Anonymous read-write for the changelog flow: every host's notifier
          # publishes here and the atom reader on this host polls it. Without
          # this explicit grant the server-global deny-all would break it.
          "everyone:nixos-changelog:rw"
        ];
      };
    };

    audiobookshelf = {
      enable = true;
    };

    karakeep = {
      package = pkgs.unstable.karakeep;
      enable = true;
      browser.enable = true;
      meilisearch.enable = true;
      extraEnvironment = {
        PORT = "3004";
        NODE_OPTIONS = "--max-old-space-size=8192";
        DISABLE_SIGNUPS = "true";
        DB_WAL_MODE = "true";
        SEARCH_NUM_WORKERS = "2";
        SEARCH_JOB_TIMEOUT_SEC = "60";
        WEBHOOK_NUM_WORKERS = "2";
        ASSET_PREPROCESSING_NUM_WORKERS = "3";
        # Crawler Configs
        CRAWLER_NUM_WORKERS = "3";
        CRAWLER_JOB_TIMEOUT_SEC = "300";
        CRAWLER_NAVIGATE_TIMEOUT_SEC = "60";
        CRAWLER_STORE_PDF = "true";
      };
    };

    meilisearch.package = pkgs.meilisearch;

    readeck = {
      package = pkgs.unstable.readeck;
      enable = false; # TODO: Temporarily disable as I am not actively using it
      # READECK_SECRET_KEY must be set:
      environmentFile = "/home/doot/secret_test/readeck/env";
      settings = {
        server = {
          port = 8002;
        };
      };
    };

    pinchflat = {
      enable = true;
      mediaDir = "/media-nfs/pinchflat/";
      secretsFile = "/home/doot/secret_test/pinchflat/env";
      package = pkgs.unstable.pinchflat;
    };

    actual = {
      enable = true;
      settings.port = 9345;
      package = pkgs.unstable.actual-server;
    };
  };

  # Host specific settings for certain roles
  roles = {
    alloy.withSyslogListener = true;

    # Extra offsite backup for a small subset of data
    borg = {
      enable = true;
      jobName = "borg-nmd";
      repo = "ssh://proxmox-borg@192.168.1.60:2222/volume1/proxmox-nfs/borg-nmd";
      paths = [
        "/var/lib/karakeep"
        "/var/lib/grafana/data"
        "/var/lib/actual"
        "/var/lib/nixos"
        "/etc/group"
        "/etc/machine-id"
        "/etc/passwd"
        "/docker-local/freshrss"
        "/home/doot/secret_test"
        "/home/doot/nixos-config-priv"
        "/root/media-nfs.files.txt"
      ];
      # Back up the directory structure of /media-nfs to a file (the media itself is not backed up here)
      preHook = ''
        echo "Backing up directory structure of /media-nfs..."
        find /media-nfs/ 2>/dev/null > /root/media-nfs.files.txt || true
        echo "Done listing files to /root/media-nfs.files.txt."
      '';
    };

    navidrome.enable = true;

    nixos-changelog.atomFeed.enable = true;

    nginx-proxy = {
      enable = true;
      acme = {
        enable = true;
        email = "jeremy@jhauschildt.com";
        dnsProvider = "digitalocean";
        dnsResolver = "8.8.8.8";
        environmentFile = "/home/doot/secret_test/acme/env";
      };
      proxies = [
        {
          name = "pihole";
          port = 2000;
          extraConfig = ''rewrite ^/$ /admin permanent;'';
        }
        {
          name = "pihole2";
          proxyPassHost = "http://${network.ips.shitholder}";
          port = 2000;
          extraConfig = ''rewrite ^/$ /admin permanent;'';
        }
        {
          name = "freshrss";
          port = 8666;
        }
        {
          name = "librenms";
          port = 7000;
          extraConfig = ''
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        }
        {
          name = "maloja";
          port = 42010;
        }
        {
          name = "ms";
          port = 9078;
        }
        {
          name = "cadvisor";
          port = 8080;
        }
        {
          name = "plex";
          port = 32400;
          extraConfig = ''rewrite ^/$ /web permanent;'';
        }
        {
          name = "tautulli";
          port = 8181;
        }
        {
          name = "audiobook";
          inherit (config.services.audiobookshelf) port;
        }
        {
          name = "immich";
          proxyPassHost = "http://${network.hosts.nix-shitfucker.fqdn}";
          inherit (config.services.immich) port;
          extraConfig = ''
            client_max_body_size 50000M;
            proxy_read_timeout   600s;
            proxy_send_timeout   600s;
            send_timeout         600s;
          '';
        }
        {
          name = "readeck";
          inherit (config.services.readeck.settings.server) port;
        }
        {
          name = "karakeep";
          port = config.services.karakeep.extraEnvironment.PORT;
        }
        {
          name = "pinchflat";
          inherit (config.services.pinchflat) port;
        }
        {
          name = "git";
          proxyPassHost = "http://${network.hosts.nix-shitfucker.fqdn}";
          port = outputs.nixosConfigurations.nix-shitfucker.config.services.forgejo.settings.server.HTTP_PORT;
          extraConfig = ''
            client_max_body_size 512M;
          '';
        }
        {
          name = "navidrome";
          port = config.services.navidrome.settings.Port;
        }
        {
          name = "actual";
          inherit (config.services.actual.settings) port;
        }
        {
          name = "ntfy";
          port = 2586;
          # ntfy's subscribe stream is a long-lived chunked response; default
          # proxy_buffering withholds it from HTTP/1.1 clients (the agent), and a
          # long read timeout stops nginx cutting the idle-but-alive stream.
          extraConfig = ''
            proxy_buffering off;
            proxy_read_timeout 3600s;
          '';
        }
        # {
        #   name = "gitea-mirror";
        #   proxyPassHost = "http://${outputs.nixosConfigurations.nix-shitfucker._module.specialArgs.fqdn}";
        #   port = outputs.nixosConfigurations.nix-shitfucker.config.services.gitea-mirror.port;
        # }
        {
          name = "gitea-mirror";
          port = 4321;
        }
        {
          name = "nc";
          proxyPassHost = "http://${network.hosts.nix-shitfucker.fqdn}";
          port = 80; # TODO: Put into variable to share with nextcloud setup in nsf, move to another port
        }
        {
          name = "wealthfolio";
          port = 8088; # TODO: Put into variable
        }
      ];
    };
  };
}
