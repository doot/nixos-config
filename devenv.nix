_: {
  imports = [./scripts/devenv.nix];

  languages.python = {
    directory = "./scripts";
    venv.enable = true;
    uv = {
      enable = true;
      sync = {
        enable = true;
        arguments = ["--locked"];
      };
    };
  };

  tasks."tools:test" = {
    after = ["devenv:python:uv"];
    before = ["devenv:enterTest"];
    exec = "python -B -m unittest discover -s scripts/tests -v";
  };
  # Base config is derived from the base profile of github:doot/devenv-base.
  # See: devenv.yaml and https://github.com/doot/devenv-base.

  enterTest = ''
    echo "Running tests"
    nix flake check --override-input priv ./priv
  '';
}
