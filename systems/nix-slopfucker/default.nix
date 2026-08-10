{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./hermes.nix
  ];

  system.stateVersion = "26.05";
  boot.kernelPackages = pkgs.linuxPackages_latest;

  environment.systemPackages = with pkgs; [
    inputs.neovim-nightly-overlay.packages.${pkgs.stdenv.hostPlatform.system}.default
    github-cli
  ];

  services = {
    qemuGuest.enable = true;
  };

  # Isolation: do not join the mesh VPN that bridges this host into the rest of the network.
  # The threat model is capability containment — hermes-agent is treated as hostile code, so
  # we minimise what the VM can reach, not what can reach it.
  services.netbird.enable = lib.mkForce false;
}
