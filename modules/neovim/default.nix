# Module to load everything required to use Neovim with LazyVim without managing anything
# in nix. This isn't pretty, but it might be the best option for now since some systems do
# not have nix available and I don't want to manage two configs. LazyVim/mason will
# automatically download/compile plugins and language servers to the home directory.
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
      lib.mkEnableOption "neovim role"
      // {
        default = true;
      };
  };
  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages = with pkgs; [
        lazygit
        unzip
        stylua
        ueberzugpp
        nodejs_24
        tree-sitter
        luarocks
        sqlfluff
        gcc
        gh
        rustc
        cargo
      ];
    };
    programs = {
      neovim = {
        enable = true;
        withPython3 = true;
        withNodeJs = true;
        # TODO: switch back to unstable once breakage is fixed with stable or next version is released
        # package = pkgs.unstable.neovim-unwrapped;
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
