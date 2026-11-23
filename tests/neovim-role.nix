{host}: let
  inherit (host) pkgs;
  inherit (pkgs) lib;
  configure = neovim: (host.extendModules {modules = [{roles.neovim = neovim;}];}).config;
  disabled = configure {enable = lib.mkForce false;};
  images = configure {
    extraTools = lib.mkForce false;
    imageSupport = true;
  };
  inherit (disabled.environment.sessionVariables) EDITOR VISUAL;
in
  assert lib.assertMsg (EDITOR == "vim" && VISUAL == "vim" && builtins.elem pkgs.unstable.vim disabled.environment.systemPackages)
  "Disabling the Neovim role must leave EDITOR and VISUAL pointing to the installed Vim";
  assert lib.assertMsg (builtins.elem pkgs.unstable.ueberzugpp images.environment.systemPackages)
  "Explicit image previews must provide ueberzugpp without the additional tools";
    pkgs.runCommand "neovim-role-test" {} ''
      ${pkgs.unstable.vim}/bin/${EDITOR} --version > "$out"
    ''
