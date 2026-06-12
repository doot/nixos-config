{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./hermes.nix
    # Locked-down Hermes container (gated off by default — see
    # README-hermes-container.md for the test-first rollout). Importing it only
    # registers the `slop.hermesContainer.enable` option; it builds nothing
    # until enabled, so the Proxmox image build is unaffected.
    ./hermes-container.nix
  ];

  system.stateVersion = "26.05";
  boot.kernelPackages = pkgs.linuxPackages_latest;

  environment.systemPackages = with pkgs; [neovim];

  services = {
    qemuGuest.enable = true;
  };

  # Isolation: do not join the mesh VPN that bridges this host into the rest of the network.
  # The threat model is capability containment — hermes-agent is treated as hostile code, so
  # we minimise what the VM can reach, not what can reach it.
  services.netbird.enable = lib.mkForce false;
}
