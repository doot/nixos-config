{
  config,
  lib,
  pkgs,
  modulesPath,
  self,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ./hardware-configuration.nix # Include the results of the hardware scan.
  ];
  networking.hostName = "nix-media-docker";

  environment.systemPackages = with pkgs; [
    arion
    distrobox
    docker-compose
    python3
  ];

  system.stateVersion = "23.11";

  boot.isContainer = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Disable stub and override default nameservers, pihole use port 53 instead
  networking.nameservers = ["192.168.1.1"]; # override due to disabled stub listener
  services.resolved.extraConfig = ''
    DNSStubListener=no
  '';

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
    };

    arion = {
      backend = "docker";
      projects.pihole = {
        serviceName = "pihole"; # systemd service name
        settings = {
          # enableDefaultNetwork = false;
          imports = [../../arion/pihole/arion-compose.nix];
        };
      };
    };
  };

  # Supress systemd units that don't work because of LXC
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  # Start tty0 on serial console (needed for proxmox console)
  systemd.services."getty@tty1" = {
    enable = lib.mkForce true;
    wantedBy = ["getty.target"]; # to start at boot
    serviceConfig.Restart = "always"; # restart when session is closed
  };

  # Prevent netbird from starting a resolver on port 53, because that fucks shit up, especially on this host that runs a dns server
  systemd.services.netbird.serviceConfig.Environment = [
    "NB_DNS_RESOLVER_ADDRESS=127.0.0.1:4053"
  ];
}
