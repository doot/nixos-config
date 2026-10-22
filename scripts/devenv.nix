{
  config,
  pkgs,
  lib,
  ...
}: let
  network = import ../common/network.nix;
  jellyfinProxy = import ../systems/nix-media-docker/jellyfin-proxy.nix;
  jellyfinUrl = "https://${jellyfinProxy.name}.${network.hosts.nix-media-docker.fqdn}";
  tools = config.languages.python.import ./. {};
in {
  env.JELLYFIN_URL = lib.mkDefault jellyfinUrl;

  outputs = {
    homelab-tools = tools;
    jellyfin-people-images =
      pkgs.runCommand "jellyfin-people-images" {
        nativeBuildInputs = [pkgs.makeWrapper];
        meta.mainProgram = "jellyfin-people-images";
      } ''
        makeWrapper ${tools}/bin/jellyfin-people-images "$out/bin/jellyfin-people-images" \
          --set-default JELLYFIN_URL ${lib.escapeShellArg jellyfinUrl}
      '';
    homelab-tools-tests = pkgs.callPackage ./checks.nix {
      inherit tools jellyfinUrl;
      jellyfin = config.outputs.jellyfin-people-images;
    };
  };
}
