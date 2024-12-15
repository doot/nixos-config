{pkgs, ...}: {
  # https://devenv.sh/basics/
  # See full reference at https://devenv.sh/reference/options/

  # https://devenv.sh/packages/
  packages = [pkgs.git];

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    nix flake check --override-input priv ./priv
  '';

  languages.nix = {
    enable = true;
  };

  devcontainer.enable = true;

  pre-commit.hooks = {
    commitizen.enable = true;

    deadnix.enable = true;

    actionlint.enable = true;

    shellcheck.enable = true;

    alejandra.enable = true;

    # TODO enable after reworking configs
    # statix.enable = true;
  };
}
