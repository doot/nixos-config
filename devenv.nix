{pkgs, ...}: {
  # https://devenv.sh/basics/
  # See full reference at https://devenv.sh/reference/options/

  env.GREET = "devenv";

  # https://devenv.sh/packages/
  packages = [pkgs.git];

  # https://devenv.sh/scripts/
  scripts.hello.exec = "echo hello from $GREET";

  enterShell = ''
    hello
    git --version
  '';

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
  '';

  languages.nix = {
    enable = true;
  };

  pre-commit.hooks = {
    commitizen.enable = true;

    deadnix.enable = true;

    actionlint.enable = true;

    shellcheck.enable = true;

    alejandra.enable = true;
    # nixfmt = {
    #   enable = true;
    #   package = pkgs.nixfmt-rfc-style;
    # };

    # TODO enable after reworking configs
    # statix.enable = true;
  };
}
