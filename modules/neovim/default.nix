# Module to load everything required to use Neovim with LazyVim without managing anything
# in nix. This isn't pretty, but it might be the best option for now since some systems do
# not have nix available and I don't want to manage two configs.
{
  pkgs,
  config,
  lib,
  ...
}: let
  cfg = config.roles.neovim;
in {
  options.roles.neovim = {
    enable =
      lib.mkEnableOption "the Neovim role's additional LazyVim tools and providers (nightly Neovim remains installed when disabled)"
      // {
        default = true;
      };

    imageSupport = lib.mkOption {
      type = lib.types.bool;
      default = config.services.xserver.enable || config.programs.hyprland.enable;
      description = ''
        Terminal image previews in neovim, via ueberzugpp. Only useful under a
        graphical session, and pulls in the X11/Wayland stack, so headless hosts
        leave it off.
      '';
    };
  };
  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages =
        [
          pkgs.unstable-small.lazygit
          pkgs.unstable-small.unzip
          pkgs.unstable.nodejs_26
          pkgs.unstable-small.tree-sitter
          pkgs.unstable-small.stylua
          pkgs.unstable-small.luarocks
          pkgs.unstable-small.gh
          pkgs.unstable-small.nil
        ]
        ++ lib.optional cfg.imageSupport pkgs.unstable.ueberzugpp;
    };
    programs = {
      neovim = {
        enable = true;
        withPython3 = true;
        withNodeJs = true;
      };
      # nix-ld = {
      #   # Allows LazyVim to work with neovim as-is (not a good way to do this, but works for now)
      #   enable = true;
      #   libraries = with pkgs; [
      #     stdenv.cc.cc
      #   ];
      # };
    };
  };
}
