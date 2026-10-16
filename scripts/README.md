# Maintenance tools

One uv-managed Python 3.14+ package, `homelab-tools`, contains the maintenance
commands. It uses uv's build backend and has no runtime dependencies beyond
Python's standard library.

## Jellyfin person portraits

`jellyfin-people-images` audits every person portrait and optionally queues
refreshes for missing or unreadable images. It does not access the database,
delete media credits, or run on a schedule.

On `nix-media-docker`:

```sh
jellyfin-people-images --report people-before.jsonl
jellyfin-people-images --repair --report people-repair.jsonl
```

The installed command defaults to the URL derived from the Jellyfin proxy and
host network configuration. `--url` overrides `JELLYFIN_URL`, which overrides
that default. Supply a server API key at the private prompt or through
`JELLYFIN_API_KEY`; a restricted user session may omit people. HTTPS is required
except for loopback HTTP. Redirects are refused rather than forwarding the key.

Keep Jellyfin running, library scans idle, and metadata storage mounted.
The command validates the complete person list before submitting refreshes.

- Default: read-only audit. `--repair` queues refreshes only for failed portraits.
- Refreshes use full metadata/image refresh with `replaceAllMetadata=false` and
  `replaceAllImages=true`. Generated biographies or provider IDs may be filled
  in, and images on affected people may be replaced.
- `--workers` controls concurrent image probes (default 4); `--interval` controls
  seconds between refresh requests (default 0.5).
- Authentication, rate-limit, proxy, and connection errors stop the run.
  Refresh writes are not retried; already queued work may still finish.
- Reports contain person names and IDs. They are private JSONL files (mode 0600
  on Unix), created exclusively without overwriting existing files.

**Queued does not mean repaired.** After Jellyfin finishes, run another audit:

```sh
jellyfin-people-images --report people-after.jsonl
```

Exit codes: 0 completed (possibly queued), 1 failure, 2 broken portraits or invalid
arguments, 130 interrupted. Interrupted runs leave partial reports.

The probe checks HTTP status, content type, and JPEG/PNG/GIF/WebP signatures,
not complete decoding or visual correctness. HTTP 404/500 and invalid image
responses are repair candidates; widespread 500 errors may instead require
fixing storage or permissions. Some providers have no portrait to download.

## Development

From the repository root:

```sh
devenv shell
jellyfin-people-images --help
mypy --config-file scripts/pyproject.toml
ruff check scripts/src scripts/tests
devenv tasks run tools:test
devenv build outputs.homelab-tools-tests
```

The shared `devenv-base` Python profile provides Python, uv, editable sync, and
lint hooks. Mypy checks source and tests in strict mode. Public APIs use PEP 257
docstrings with reST `:param:`, `:returns:`, `:raises:`, and `:ivar:` fields;
type information stays in annotations. Outside devenv, provide the server URL
explicitly:

```sh
uv run --project scripts jellyfin-people-images --url https://jellyfin.example.com
uv run --project scripts python -B -m unittest discover -s scripts/tests -v
```

Tests use offline fixtures, never a live Jellyfin server. The Nix check exercises
the installed package, command entry points, and URL overrides.

Add modules under `src/homelab_tools`, entry points under `[project.scripts]`,
and tests under `tests`. Generate `uv.lock` with `uv lock --project scripts`.
