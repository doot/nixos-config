{
  lib,
  stdenvNoCC,
  python3,
}:
stdenvNoCC.mkDerivation {
  pname = "jellyfin-people-images";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [python3];
  dontBuild = true;
  doCheck = true;
  doInstallCheck = true;

  checkPhase = ''
    runHook preCheck
    python3 -B -m unittest discover -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 refresh_people_images.py "$out/bin/jellyfin-people-images"
    patchShebangs "$out/bin"
    runHook postInstall
  '';

  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/jellyfin-people-images" --help
    runHook postInstallCheck
  '';

  meta = {
    description = "Audit Jellyfin person portraits and refresh broken images";
    license = lib.licenses.mit;
    mainProgram = "jellyfin-people-images";
    platforms = lib.platforms.unix;
  };
}
