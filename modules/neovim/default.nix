{
  pkgs,
  config,
  lib,
  ...
}: let
  cfg = config.roles.neovim;
  inherit (pkgs.unstable.vimPlugins.nvim-treesitter) parsers queries;
  # LazyVim owns the Lua plugin; Nix supplies only its parsers and matching queries.
  grammarSite = pkgs.unstable.buildEnv {
    name = "neovim-treesitter-grammars";
    paths = lib.attrValues parsers ++ lib.attrValues queries;
    pathsToLink = ["/parser" "/queries"];
  };
in {
  options.roles.neovim = {
    enable = lib.mkEnableOption "Neovim with prebuilt Tree-sitter grammars";

    extraTools = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install additional LazyVim tools and enable the Node.js and Python providers.";
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
      variables.NVIM_TREESITTER_GRAMMARS = toString grammarSite;
      systemPackages =
        if cfg.extraTools
        then
          [
            pkgs.unstable-small.lazygit
            pkgs.unstable-small.unzip
            pkgs.unstable.nodejs_26
            pkgs.unstable-small.stylua
            pkgs.unstable-small.luarocks
            pkgs.unstable-small.gh
            pkgs.unstable-small.nil
          ]
          ++ lib.optional cfg.imageSupport pkgs.unstable.ueberzugpp
        else [config.programs.neovim.package];
    };
    programs = {
      neovim = lib.mkIf cfg.extraTools {
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
