# Hermes records session transcripts but never records which sessions had a
# terminal attached, so a host reboot loses the working set while keeping every
# transcript. This plugin writes that missing fact to $HERMES_HOME/live/<pid>.json.
#
# Packaged rather than dropped in ~/.hermes/plugins so the agent cannot edit its
# own hooks: the store path is read-only and the module symlinks it in.
{
  lib,
  stdenvNoCC,
  python3,
}:
stdenvNoCC.mkDerivation {
  pname = "hermes-plugin-session-leases";
  version = "0.1.0";

  src = ./.;

  # `name` disambiguates the extraPlugins symlink (nix-managed-<name>).
  passthru.pluginName = "session-leases";

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm444 plugin.yaml $out/plugin.yaml
    install -Dm444 __init__.py $out/__init__.py

    # The restore CLI is a sibling artifact, not part of the plugin contract:
    # it runs on the machine holding the wezterm mux client, not in the agent.
    install -Dm555 hermes-restore $out/bin/hermes-restore
    patchShebangs $out/bin/hermes-restore

    runHook postInstall
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${lib.getExe python3} -c 'import ast, pathlib; ast.parse(pathlib.Path("__init__.py").read_text())'
    ${lib.getExe python3} -c 'import ast, pathlib; ast.parse(pathlib.Path("hermes-restore").read_text())'
    runHook postCheck
  '';

  meta = {
    description = "Records which Hermes sessions have a live TUI attached, so a rebooted host can restore its working set";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "hermes-restore";
  };
}
