{
  lib,
  pkgs,
  modulesPath,
  fqdn,
  config,
  outputs,
  ...
}: {
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

  boot.isContainer = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Disable stub and override default nameservers, pihole use port 53 instead
  networking.nameservers = ["192.168.1.88" "192.168.1.60"]; # override due to disabled stub listener
  services.resolved.extraConfig = ''
    DNSStubListener=no
  '';

  networking.firewall.allowedTCPPorts = [
    32400 # Plex
  ];

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
      projects = {
        pihole = {
          serviceName = "pihole"; # systemd service name
          settings = {
            # enableDefaultNetwork = false;
            imports = [../../arion/pihole];
          };
        };
        freshrss = {
          serviceName = "freshrss"; # systemd service name
          settings = {
            imports = [../../arion/freshrss];
          };
        };
        librenms = {
          serviceName = "librenms"; # systemd service name
          settings = {
            imports = [../../arion/librenms];
          };
        };
        plex = {
          serviceName = "plex"; # systemd service name
          settings = {
            imports = [../../arion/plex];
          };
        };
        monitoring = {
          serviceName = "monitoring"; # systemd service name
          settings = {
            imports = [../../arion/monitoring];
          };
        };
        scrobble = {
          serviceName = "scrobble"; # systemd service name
          settings = {
            imports = [../../arion/scrobble];
          };
        };
        maybe = {
          serviceName = "maybe"; # systemd service name
          settings = {
            imports = [../../arion/maybe];
          };
        };
        # wireguard = {
        #   serviceName = "wireguard"; # systemd service name
        #   settings = {
        #     imports = [../../arion/wireguard];
        #   };
        # };
      };
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
    };
  };

  services = {
    audiobookshelf = {
      enable = true;
    };
  };

  programs.git.config = {
    # Prevent errors due to ownership of this special override repo
    safe.directory = [
      "/home/doot/nixos-config-priv/.git"
      "/home/doot/nixos-config-priv"
    ];
  };

  # Certs
  security.acme = {
    # TODO extract this into common config
    acceptTerms = true;
    defaults.email = "jeremy@jhauschildt.com";
    defaults.dnsResolver = "8.8.8.8"; # Needed due to using a wildcard and hijacking locally
    certs.${fqdn} = {
      domain = "*.${fqdn}";
      dnsProvider = "digitalocean";
      dnsPropagationCheck = true;
      environmentFile = "/home/doot/secret_test/acme/env";
    };
  };

  users.users.nginx.extraGroups = ["acme"];

  # TODO: this works, but ultimately we want this to be part of a module instead
  # services.nginx =
  # let
  #   newNginxVHost = args:
  #   {
  #     virtualHosts."${args.name}.${args.fqdn}" = {
  #       useACMEHost = args.fqdn;
  #       forceSSL = true;
  #       locations."/" = {
  #         proxyPass = "http://127.0.0.1:${toString args.port}";
  #         proxyWebsockets = true;
  #       };
  #     };
  #   };
  # in newNginxVHost { name = "maybe"; fqdn = fqdn; port = 3060; };

  # Add certain arion/docker services to nginx proxy
  services.nginx = {
    enable = true;
    statusPage = true;
    virtualHosts = builtins.listToAttrs (
      # This is a mess, but it iterates over a list of attribute sets, whose attributes are arguments, and creates a virtualHosts attribute set with those arguments for each one
      # for example { name = "pihole"; port = 2000;} turns into:
      #   {
      #     "pihole.nmd.jhauschildt.com" = {
      #       useACMEHost = "nmd.jhauschildt.com";
      #       forceSSL = true;
      #       locations."/" = {
      #         proxyPass = "http://127.0.0.1:2000";
      #         proxyWebsockets = true;
      #       };
      #     };
      #   }
      # TODO: This should be a temporary solution until I can create a module that does this in a cleaner way.
      #       Ideally the module would let me set the bare minumum attributes anywhere in the config, then extrapolate using these defaults
      builtins.map (
        arg: {
          name = "${arg.name}.${fqdn}";
          value = {
            default = arg.default or false;
            useACMEHost = fqdn;
            forceSSL = true;
            locations."/" = {
              proxyPass = "${arg.proxyPassHost or "http://127.0.0.1"}:${toString arg.port}";
              proxyWebsockets = true;
              extraConfig = arg.extraConfig or '''';
            };
          };
        }
      )
      [
        {
          name = "maybe";
          port = 3060;
        }
        {
          name = "pihole";
          port = 2000;
          extraConfig = ''rewrite ^/$ /admin permanent;'';
        }
        {
          name = "pihole2";
          proxyPassHost = "http://192.168.1.60";
          port = 2000;
        }
        {
          name = "freshrss";
          port = 8666;
        }
        {
          name = "librenms";
          port = 7000;
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
        }
        {
          name = "tautulli";
          port = 8181;
        }
        {
          name = "audiobook";
          port = config.services.audiobookshelf.port;
        }
        {
          name = "immich";
          # TODO: this can't be a good way to do this, try to find a cleaner way
          proxyPassHost = "http://${outputs.nixosConfigurations.nix-shitfucker._module.specialArgs.fqdn}";
          # proxyPassHost = "http://nsf.jhauschildt.com";
          port = config.services.immich.port;
          extraConfig = ''
            client_max_body_size 50000M;
            proxy_read_timeout   600s;
            proxy_send_timeout   600s;
            send_timeout         600s;
          '';
        }
      ]
    );
  };

  # Host specific settings for certain roles
  roles.alloy.withSyslogListener = true;
}
