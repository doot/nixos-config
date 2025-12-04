# This just exists so that the arion cli can be used directly from this directory, even though these modules are loaded by nixos.
# ex: arion -f pihole/default.nix exec pihole bash
import <nixpkgs> {stdenv.hostPlatform.system = "x86_64-linux";}
