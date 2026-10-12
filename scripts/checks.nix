{
  lib,
  runCommand,
  tools,
  jellyfin,
  jellyfinUrl,
}:
runCommand "homelab-tools-tests" {} ''
  export HOME="$TMPDIR" COLUMNS=120
  unset JELLYFIN_URL JELLYFIN_API_KEY PYTHONPATH
  ${tools}/bin/python -B -m unittest discover -s ${./tests} -v

  ${tools}/bin/jellyfin-people-images --help > generic-help
  grep -F 'default: None' generic-help

  ${jellyfin}/bin/jellyfin-people-images --help > configured-help
  grep -F ${lib.escapeShellArg jellyfinUrl} configured-help

  JELLYFIN_URL=https://override.example.invalid \
    ${jellyfin}/bin/jellyfin-people-images --help > override-help
  grep -F 'https://override.example.invalid' override-help

  # An invalid explicit URL must win over both defaults and fail before connecting.
  set +e
  JELLYFIN_URL=https://override.example.invalid JELLYFIN_API_KEY=fixture \
    ${jellyfin}/bin/jellyfin-people-images --url http://invalid.example \
    > invalid-url 2>&1
  status=$?
  set -e
  test "$status" -eq 1
  grep -F 'Use HTTPS, or loopback HTTP' invalid-url
  for report in people-images-*.jsonl; do test ! -e "$report"; done
  touch "$out"
''
