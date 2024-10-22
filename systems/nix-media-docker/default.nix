{
  config,
  lib,
  pkgs,
  modulesPath,
  inputs,
  fqdn,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ./hardware-configuration.nix # Include the results of the hardware scan.
    "${inputs.nixpkgs-unstable}/nixos/modules/services/monitoring/alloy.nix"
  ];

  # TODO: remove alloy from disabled modules and unstable override of the alloy service after next nixOS version is released. Currently the service is only available in unstable.
  disabledModules = [
    "services/monitoring/alloy.nix"
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
  networking.nameservers = ["192.168.1.1"]; # override due to disabled stub listener
  services.resolved.extraConfig = ''
    DNSStubListener=no
  '';

  networking.firewall.allowedTCPPorts = [
    32400 # Plex
    8181 # Tautulli
    9323 # docker prometheus metrics
    42010 # maloja
    9078 # multi-scrobbler
    3493 # nut-exporter
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

  programs.git.config = {
    # Prevent errors due to ownership of this special override repo
    safe.directory = [
      "/home/doot/nixos-config-priv/.git"
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
}
