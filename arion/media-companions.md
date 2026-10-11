# Jellyfin companion trials

| App | Hostname | Loopback port | Persistent storage |
| --- | --- | --- | --- |
| Tracearr | `tracearr.nmd.jhauschildt.com` | 3011 | Docker volumes `tracearr_{postgres,redis,backups,images}` |
| Jellydash | `jellydash.nmd.jhauschildt.com` | 3012 | `/docker-local/jellydash` |
| JellyGlance | `jellyglance.nmd.jhauschildt.com` | 3013 | Docker volumes `jellyglance_{postgres,config,backups}` |

nginx allows only `common/network.nix`'s `localClientCidrs`: LAN and loopback,
not arbitrary VPN/mesh clients. Application logins remain enabled. Claim/setup
must still be completed promptly: other LAN clients can reach first-run setup.
The application ports are loopback-only; databases and Redis have no host ports.

Tracearr and JellyGlance use named volumes so Docker preserves the images'
initial ownership without hardcoding container UIDs. They survive recreation;
never use `docker compose down --volumes` on these projects. Jellydash's entrypoint
owns its subdirectories. No media, Tautulli database or Docker socket is mounted.

## Deploy

1. Merge the paired public/private changes and populate the private secrets
   **before rebuilding**. The private overlay uses the public proxy options;
   the applications need its rendered environment files. Do not deploy either
   half alone. See the private `modules/media-companion-secrets.md`.
2. Rebuild `nix-media-docker` with the real private overlay. Check
   `systemctl status tracearr jellydash jellyglance nginx` and each project's
   container health/logs. A healthy HTTP endpoint does not prove recording works.
3. Open the HTTPS hostnames from the LAN. Claim Tracearr with its sops claim code,
   use Jellydash's seeded `admin` account, and create JellyGlance's first admin.
   Add Plex/Jellyfin servers and tokens through the appropriate app UI; use URLs
   reachable from containers, not `localhost`. Jellydash's URL is preconfigured.
4. Confirm one real new playback per server, including stop time and user.
   If Jellyfin returns 503, inspect its remote-access rejection logs before
   weakening access rules. Container clients may need a deliberately assigned
   network allowed by Jellyfin; do not trust all Docker networks as proxies.

Images follow `latest` and the shared pull policy; this is not reproducible image
selection. It picks up updates on later pulls, not on a timer. Database major
versions stay fixed and require explicit migration to change.

## Compare history, not dashboard totals

- **Tracearr:** ongoing Plex + Jellyfin recording, Tautulli API import. Import
  only accepts plays before the Plex server was added to Tracearr, skips some
  unmatched/invalid records, and can report completion with failed pages. Sync
  users first, inspect all import counters/messages and reconcile old samples.
  Mark retired servers historical; deleting a server deletes its history.
- **Jellydash:** Jellyfin recording and Playback Reporting event imports
  (plugin API, TSV or SQLite). No Plex/Tautulli recorder/importer.
- **JellyGlance:** Jellyfin/Emby recording and Tautulli SQLite-backup upload.
  Import drops music and some invalid/duplicate records; large imports can fail
  partially. Import Playback Reporting before Tautulli: plugin sync only fetches
  outside the existing history range. Its separate Jellyfin watched-state import
  cannot reconstruct rewatches.

Keep Tautulli, Streamystats and Playback Reporting collecting throughout the
trial. Preserve original Tautulli database snapshots independently. Check old
users, deleted titles, music, rewatches, timestamps and skipped records—not just
the headline play count. No import runs automatically from this configuration.

## Security and backup checks

JellyGlance's first-run restore route is blocked because it writes uploads before
checking setup state. Verify GET and POST return 403 for lowercase, mixed-case
and trailing-slash variants. Use authenticated restore after setup. An additional CSP
blocks external scripts, including its bundled third-party analytics. Verify the
browser console/network tab and exercise login/import/live updates after deploy.
Do not distribute accounts assuming per-user live-session privacy.

The nginx entrypoints replace forwarding headers; direct container access is not
a trusted proxy route. Jellydash keeps proxy trust/HTTPS redirects disabled rather
than guessing a Docker gateway CIDR; nginx terminates TLS and its forwarded scheme
sets secure cookies. A bridge change must not be fixed by trusting every proxy.

Persistent storage is **not a backup**. These new databases are not added to Borg's
live-file copy list: copying an active PostgreSQL directory is not a valid backup.
Enable and export Tracearr's logical backups, take full PostgreSQL dumps for
JellyGlance and consistent SQLite backups for Jellydash, then store them off-host.
Preserve the sops keys with backups and test a disposable restore before retiring
any source history. Rolling back the deployment means removing these three project
and proxy registrations; keep all state and source collectors intact.

Sources: [Tracearr deployment](https://github.com/connorgallopo/Tracearr/blob/fa9d4f170909ba1d614c4fb621ce0b324fd5078c/docker/examples/docker-compose.pg18.yml),
[Tracearr importer](https://github.com/connorgallopo/Tracearr/blob/fa9d4f170909ba1d614c4fb621ce0b324fd5078c/apps/server/src/services/tautulli.ts),
[Jellydash SQLite](https://github.com/themartz90/jellydash/blob/cb9bbe42f6b5a435df13c0bb80fecdfc6bd37105/docker-compose.sqlite.yml),
[JellyGlance importer](https://github.com/JellyGlance/Server/blob/baf6949406149b3eb1c96f3f185cd261117876aa/apps/api/routes/tautulli.js).
