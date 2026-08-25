_: {
  # Base config is derived from the base profile of github:doot/devenv-base.
  # See: devenv.yaml and https://github.com/doot/devenv-base.

  enterTest = ''
    echo "Running tests"
    nix flake check --override-input priv ./priv
  '';
}
