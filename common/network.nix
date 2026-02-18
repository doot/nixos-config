# Centralized network constants shared across NixOS modules and Arion services.
# This file is a plain attrset (not a NixOS module) so it can be imported anywhere.
{
  ips = {
    gateway = "192.168.1.1";
    nix-media-docker = "192.168.1.88";
    shitholder = "192.168.1.60";
    nix-shitfucker = "192.168.1.110";
  };
}
