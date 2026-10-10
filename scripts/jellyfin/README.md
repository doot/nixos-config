# Jellyfin person portraits

Checks every person through Jellyfin's API and optionally queues refreshes for
missing or unreadable portraits. Requires Python 3.10+ with no extra packages.
No database access, library deletion, or scheduled job.

## Run

From the repository root, choose a server explicitly:

```sh
export JELLYFIN_URL='https://jellyfin.example.com'
nix run .#jellyfin-people-images -- --report people-before.jsonl
nix run .#jellyfin-people-images -- --repair --report people-repair.jsonl
```

Without Nix:

```sh
python3 scripts/jellyfin/refresh_people_images.py --repair --report people-repair.jsonl
```

Use a **server API key**, not a restricted user session. The script prompts for
it without echoing; `JELLYFIN_API_KEY` is also supported. `--url` overrides
`JELLYFIN_URL`. HTTPS is required except for loopback HTTP on the server itself.
Redirects are refused rather than forwarding the key.

Keep Jellyfin running, library scans idle, and metadata storage mounted. The
script enumerates and validates all pages before submitting any refreshes.
It checks the portrait endpoint rather than trusting a registered image path.

- Default: read-only audit. `--repair` queues work only for failed portraits.
- Refreshes use full metadata/image refresh, `replaceAllMetadata=false`, and
  `replaceAllImages=true`. Generated biographies or provider IDs may be filled
  in; images on affected people may be replaced. Media credits are not deleted.
- `--workers` controls concurrent image probes (default 4).
  `--interval` controls seconds between refresh requests (default 0.5).
- Authentication, rate-limit, proxy, or connection errors stop the run. Refresh
  writes are not automatically retried. Already queued work can still finish.
- Reports are private JSONL files (mode 0600 on Unix), created exclusively.
  Existing reports are never overwritten. They contain person names and IDs;
  keep them out of commits, especially if you choose a custom filename.

A 204 response means **queued**, not repaired. Let Jellyfin finish its queue,
then run another read-only pass with a new report:

```sh
nix run .#jellyfin-people-images -- --report people-after.jsonl
```

Reports include `id`, `name`, `http_status`, `healthy`, and `queued` per person;
refresh attempts also include `refresh_http_status`. Interrupted runs leave
partial reports. Exit codes: 0 completed (possibly queued), 1 failure,
2 audit found broken portraits or invalid arguments, 130 interrupted.

## Limits

The probe checks HTTP status, content type, and JPEG/PNG/GIF/WebP signatures—not
complete image decoding or visual correctness. HTTP 404/500 and invalid image
responses are repair candidates; a widespread server-side 500 may require fixing
storage or permissions instead. Some providers have no portrait to download.
This is a maintenance pass, not a guarantee that every person has a photo.

## Tests

```sh
python3 -B -m unittest discover -s scripts/jellyfin -v
nix build .#jellyfin-people-images
```

The package runs the tests and checks the installed command's `--help`.
It is also a flake check, so the existing `nix flake check` and `devenv test`
commands include it. Tests use fixtures, never a real Jellyfin server.
