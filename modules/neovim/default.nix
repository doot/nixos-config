# Module to load everything required to use Neovim with LazyVim without managing anything
# in nix. This isn't pretty, but it might be the best option for now since some systems do
# not have nix available and I don't want to manage two configs.
{
  pkgs,
  config,
  lib,
  inputs,
  ...
}: let
  cfg = config.roles.neovim;
  nightly = inputs.neovim-nightly-overlay.packages.${pkgs.stdenv.hostPlatform.system}.default;
  parserTools = lib.makeBinPath [pkgs.stdenv.cc pkgs.unstable-small.tree-sitter];
  editor = pkgs.symlinkJoin {
    pname = "neovim-with-parser-tools";
    inherit (nightly) version meta;
    passthru = {inherit (nightly) lua;};
    paths = [nightly];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram "$out/bin/nvim" --suffix PATH : ${parserTools}
    '';
  };
in {
  options.roles.neovim = {
    enable =
      lib.mkEnableOption "additional LazyVim tools and providers"
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
  config = {
    environment.systemPackages =
      if cfg.enable
      then
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
        ++ lib.optional cfg.imageSupport pkgs.unstable.ueberzugpp
      else [editor];

    programs.neovim = {
      inherit (cfg) enable;
      withPython3 = cfg.enable;
      withNodeJs = cfg.enable;
      package = editor;
    };
  };
}
