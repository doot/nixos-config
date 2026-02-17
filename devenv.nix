{pkgs, ...}: {
  enterTest = ''
    echo "Running tests"
    nix flake check --override-input priv ./priv
  '';

  languages = {
    nix = {
      enable = true;
      lsp.enable = true;
    };
    shell = {
      enable = true;
      lsp.enable = true;
    };
  };

  packages = [pkgs.github-cli];

  git-hooks.hooks = {
    commitizen.enable = true;

    deadnix.enable = true;

    actionlint.enable = true;

    shellcheck.enable = true;

    alejandra.enable = true;

    # TODO enable after reworking configs
    # statix.enable = true;

    check-yaml.enable = true;
  };
}
