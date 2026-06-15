# Centralized host identity (shortname / fqdn / ip), shared across NixOS modules and Arion services.
# Plain attrset (not a NixOS module) so it can be imported anywhere. No service ports here —
# each service defines its own port and is referenced from its own config option.
let
  domain = "jhauschildt.com";
in rec {
  inherit domain;

  hosts = {
    nix-media-docker = {
      shortname = "nmd";
      ip = "192.168.1.88";
      fqdn = "nmd.${domain}";
    };
    nix-shitfucker = {
      shortname = "nsf";
      ip = "192.168.1.110";
      fqdn = "nsf.${domain}";
    };
    synology = {
      shortname = "sh2"; # formerly referred to as "shitholder"
      ip = "192.168.1.60";
      fqdn = "sh2.${domain}";
    };
    proxmox = {
      shortname = "pve";
      fqdn = "pve.${domain}";
    };
    gateway = {
      ip = "192.168.1.1";
    };
  };

  # Compat alias so existing `network.ips.*` references stay untouched.
  ips = {
    gateway = hosts.gateway.ip;
    nix-media-docker = hosts.nix-media-docker.ip;
    nix-shitfucker = hosts.nix-shitfucker.ip;
    shitholder = hosts.synology.ip;
  };
}
