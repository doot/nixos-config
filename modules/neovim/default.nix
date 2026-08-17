# Module to load everything required to use Neovim with LazyVim without managing anything
# in nix. This isn't pretty, but it might be the best option for now since some systems do
# not have nix available and I don't want to manage two configs. LazyVim/mason will
# automatically download/compile plugins and language servers to the home directory.
{
  pkgs,
  config,
  lib,
  inputs,
  ...
}: let
  cfg = config.roles.neovim;
in {
  options.roles.neovim = {
    enable =
      lib.mkEnableOption "neovim role"
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
      systemPackages = with pkgs;
        [
          lazygit
          unzip
          stylua
          unstable.nodejs_26
          tree-sitter
          luarocks
          sqlfluff
          gcc
          gh
          rustc
          cargo
          nil
          rust-analyzer
        ]
        ++ lib.optional cfg.imageSupport ueberzugpp;
    };
    programs = {
      neovim = {
        enable = true;
        withPython3 = true;
        withNodeJs = true;
        package = inputs.neovim-nightly-overlay.packages.${pkgs.stdenv.hostPlatform.system}.default;
      };
      nix-ld = {
        # Allows LazyVim to work with neovim as-is (not a good way to do this, but works for now)
        enable = true;
        libraries = with pkgs; [
          stdenv.cc.cc
        ];
      };
    };
  };
}
