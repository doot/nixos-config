# Baseline vi/vim shell ergonomics for every host, independent of dotfiles.
#
# The dotfiles repo lands asynchronously (clone-dotfiles.service in common/) and
# not at all on hosts that never run it — e.g. the hermes container, which has no
# ~/.inputrc and no user dotfile deployment. Without this module such a host
# silently inherits the nixpkgs defaults: EDITOR=nano (programs/environment.nix)
# and emacs-mode readline. These options restate the dotfiles' shell-level
# preferences declaratively so a fresh host is already correct at first boot.
#
# Scope is deliberately narrow: readline mode + default editor. Editor
# *configuration* (LazyVim et al) stays in dotfiles; duplicating it here would
# create a second source of truth.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.roles.shellDefaults;

  # The stock file the bash module would otherwise install verbatim. Referenced
  # by store path so the $include below resolves without a second /etc entry.
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
        {option}`environment.systemPackages` on the host that sets it — hosts
        carrying only plain vim (the hermes container) override this to "vim"
        rather than exporting a name that resolves to nothing.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # sessionVariables lands in /etc/set-environment, which is sourced by both
    # login and non-login shells, so this reaches systemd-spawned agents too --
    # not just interactive terminals. It beats the nixpkgs `lib.mkDefault "nano"`
    # on plain priority without needing mkForce.
    environment.sessionVariables = {
      EDITOR = cfg.editor;
      VISUAL = cfg.editor;
    };

    # readline covers every libreadline consumer at once (bash, python REPL,
    # psql, gdb...), which `set -o vi` alone does not. nixpkgs sets
    # environment.etc.inputrc at mkOptionDefault priority specifically so it can
    # be overridden by .text like this.
    #
    # $include pulls in the stock CentOS-derived file rather than discarding it:
    # its bindings fix Home/End/Delete/Ctrl-arrow across linux console, xterm,
    # rxvt and freebsd console. Those live in an `$if mode=emacs` block, so they
    # are inert here -- but keeping the include means flipping `editing-mode`
    # back to emacs on a host still yields working keys. The vi settings follow
    # the include so they win on conflict.
    environment.etc.inputrc.text = ''
      $include ${nixpkgsInputrc}

      set editing-mode vi
      set keymap vi

      # Distinguishes insert from command mode, which is otherwise invisible in
      # a bare terminal. The \1..\2 wrappers mark the escape sequences as
      # zero-width so readline's column arithmetic stays correct and long lines
      # do not wrap onto themselves.
      set show-mode-in-prompt on
      set vi-ins-mode-string "\1\e[1;0m\2[+] \1\e[0m\2"
      set vi-cmd-mode-string "\1\e[1;0m\2[:] \1\e[0m\2"
    '';

    # readline's editing-mode governs bash only once bash is in vi mode itself;
    # `set -o vi` is the shell-option half of the same preference and also fixes
    # bash builtins that consult SHELLOPTS.
    programs.bash.interactiveShellInit = ''
      set -o vi
    '';
  };
}
