# Baseline vi/vim shell settings for every host, independent of dotfiles. These
# settings restate some preferences defined in ~/.dotfiles and is done
# deliberately to solve for the cases where dotfiles have not been set up.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.roles.shellDefaults;

  nixpkgsInputrc = "${pkgs.path}/nixos/modules/programs/bash/inputrc";
in {
  options.roles.shellDefaults = {
    enable =
      lib.mkEnableOption "vi-mode shell and editor defaults"
      // {
        default = true;
      };

    editor = lib.mkOption {
      type = lib.types.str;
      default = "nvim";
      description = ''
        Command used for EDITOR/VISUAL. Must be present in
        {option}`environment.systemPackages` on the host that sets it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.sessionVariables = {
      EDITOR = cfg.editor;
      VISUAL = cfg.editor;
    };

    # Enable vi mode for readline. The $include keeps the stock nixpkgs
    # bindings, which fix Home/End/Delete across terminals.
    environment.etc.inputrc.text = ''
      $include ${nixpkgsInputrc}

      set editing-mode vi
      set keymap vi
      set show-mode-in-prompt on
      set vi-ins-mode-string "\1\e[1;0m\2[+] \1\e[0m\2"
      set vi-cmd-mode-string "\1\e[1;0m\2[:] \1\e[0m\2"
    '';

    # Enable vi mode in the bash prompt.
    programs.bash.interactiveShellInit = ''
      set -o vi
    '';
  };
}
