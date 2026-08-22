# Media Stack — Artemis-Cluster

Verified against the live tree 2026-08-21. App lists rot — run `ls kubernetes/apps/media/` for
the current set rather than trusting this section.

## Architecture

Live apps in `kubernetes/apps/media/` (21 as of 2026-08-21):

### Acquisition

| App            | Image                                              | Role                                                                          |
| -------------- | -------------------------------------------------- | ----------------------------------------------------------------------------- |
| `sonarr`       | `ghcr.io/home-operations/sonarr`                   | TV (single instance)                                                          |
| `radarr`       | `ghcr.io/home-operations/radarr`                   | Movies                                                                        |
| `prowlarr`     | `ghcr.io/home-operations/prowlarr`                 | Central indexer manager → syncs to all arr apps + autobrr                     |
| `sabnzbd`      | `ghcr.io/home-operations/sabnzbd`                  | Usenet downloads                                                              |
| `qbittorrent`  | `ghcr.io/home-operations/qbittorrent-libtorrentv1` | Torrents — **single container, no VPN sidecar**                               |
| `qui`          | `ghcr.io/autobrr/qui`                              | qBittorrent web UI + cross-seed automation — **upstream autobrr, not a fork** |
| `autobrr`      | `ghcr.io/autobrr/autobrr`                          | IRC announcers for private trackers (`id.dcunha.io` OIDC)                     |
| `bazarr`       | `ghcr.io/home-operations/bazarr`                   | Subtitles (behind the `tinyauth` component)                                   |
| `recyclarr`    | `ghcr.io/recyclarr/recyclarr`                      | Quality profile sync (CronJob — no Service, no route)                         |
| `flaresolverr` | `ghcr.io/flaresolverr/flaresolverr`                | Cloudflare challenge solver for indexers, `:8191`                             |
| `trawl`        | `ghcr.io/germondai/trawl`                          | Camoufox/Firefox-based challenge solver, `:8191` — Dragonfly index 5 cache    |

### Playback and requests

| App            | Image                                              | Role                                                            |
| -------------- | -------------------------------------------------- | --------------------------------------------------------------- |
| `jellyfin`     | `ghcr.io/jellyfin/jellyfin`                        | Media server — `jellyfin.dcunha.io` + `jellyfin.frostlink.dev`  |
| `seerr`        | `ghcr.io/seerr-team/seerr`                         | Requests — `seerr.dcunha.io` **and** `requests.dcunha.io`       |
| `autopulse`    | `ghcr.io/dan-online/autopulse`                     | Library-refresh trigger into Jellyfin, `:2875` API / `:2885` UI |
| `streamystats` | `ghcr.io/fredrikburmester/streamystats-job-server` | Jellyfin watch statistics — shared Postgres via pgbouncer       |

### Books, comics, documents

| App         | Image                                 | Role                                                                                                                              |
| ----------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `bookboss`  | `ghcr.io/szinn/bookboss`              | Ebook library at `books.dcunha.io` — shared Postgres, OIDC                                                                        |
| `shelfmark` | `ghcr.io/calibrain/shelfmark`         | Book search/ingest at `booksearch.dcunha.io`, `:8084` — OIDC, talks to Prowlarr on `:80`                                          |
| `kaizoku`   | `docker.io/maxpiva/rensaio`           | Manga downloader, `:9833` — PUID 99 / PGID 100 (not the usual 1000)                                                               |
| `komf`      | `sndxr/komf`                          | Metadata for Komga — Komga itself lives in `default`, not `media`                                                                 |
| `paperless` | `ghcr.io/paperless-ngx/paperless-ngx` | Document management — shared Postgres + Dragonfly index 1, plus `paperless-tika` and `paperless-gotenberg` sidecar kustomizations |

### Chat

| App         | Image                         | Role                            |
| ----------- | ----------------------------- | ------------------------------- |
| `thelounge` | `ghcr.io/thelounge/thelounge` | Self-hosted IRC client, `:9000` |

## Scale-to-zero — read this before diagnosing "X is down"

Ten of the media apps carry `components/zeroscaler`, an HPA with `minReplicas: 0` that idles the
Deployment out and scales it back up when the blackbox probe succeeds:

```text
bazarr  bookboss  jellyfin  kaizoku  qbittorrent  qui  radarr  sabnzbd  shelfmark  sonarr
```

Consequences that catch people out:

- **Zero replicas is the healthy steady state.** "No pods for sonarr" is not an outage.
- **`kubectl rollout restart` is a no-op on a scaled-to-zero Deployment.** To force a restart,
  wake the app first (hit its hostname), then restart — or just delete the running pod.
- The whole scheme hangs off one blackbox-exporter. If _every_ zeroscaler app looks down at once,
  suspect the exporter, not the apps.

## Critical Rules

- **Never enable "Remove Completed"** in Sonarr/Radarr download client settings — cross-seed
  depends on files staying
- **Prowlarr is the indexer source of truth** — never add indexer API keys directly to
  Sonarr/Radarr/Bazarr
- **cross-seed is built into qui** — do not deploy it as a standalone app
- **SABnzbd incomplete dir on Ceph** — NFS chokes on RAR unpacking IOPS; incomplete must be
  block storage

## Internal Cluster DNS (pod-to-pod)

Always use cluster-local DNS, never external. **The arr apps and qBittorrent listen on `:80`,
not their upstream default ports** — the app-template `service.app.ports.http.port` anchor is
`80` for all of them. Wiring one app to another using the upstream default gets connection
refused.

```text
http://sonarr.media.svc.cluster.local:80
http://radarr.media.svc.cluster.local:80
http://prowlarr.media.svc.cluster.local:80
http://qbittorrent.media.svc.cluster.local:80
http://bazarr.media.svc.cluster.local:80
http://qui.media.svc.cluster.local:80
http://seerr.media.svc.cluster.local:80
http://autobrr.media.svc.cluster.local:80
http://sabnzbd.media.svc.cluster.local:8080
http://flaresolverr.media.svc.cluster.local:8191
http://trawl.media.svc.cluster.local:8191
```

| App           | Correct port | Wrong (upstream default, and what old docs said) |
| ------------- | ------------ | ------------------------------------------------ |
| `sonarr`      | `80`         | `8989`                                           |
| `radarr`      | `80`         | `7878`                                           |
| `prowlarr`    | `80`         | `9696`                                           |
| `qbittorrent` | `80`         | `8080`                                           |
| `sabnzbd`     | `8080`       | — `8080` is correct here                         |

Confirm before wiring: `grep -m1 -oE "&port [0-9]+" kubernetes/apps/media/<app>/app/helmrelease.yaml`

## SABnzbd Server Priority

| Priority | Server          | Host                        |
| -------- | --------------- | --------------------------- |
| P0       | Frugal US       | news.frugalusenet.com       |
| P1       | Frugal EU       | eunews.frugalusenet.com     |
| P2       | ~~NewsDemon~~   | EXPIRED 2026-04-21 — remove |
| P3       | Frugal Bonus    | bonus.frugalusenet.com      |
| P4       | NGD 1TB block   | us.newsgroupdirect.com      |
| P5       | Blocknews 300GB | us.blocknews.net            |

## qBittorrent

**There is no Gluetun sidecar and no VPN.** The HelmRelease has a single `app` container; a
`grep -c gluetun` over the whole app directory returns 0. Torrent traffic egresses directly
through a second `LoadBalancer` Service (`service.bittorrent`) pinned to `10.10.99.95` via
`io.cilium/lb-ipam-ips`, with `externalTrafficPolicy: Local`. If a doc claims a shared network
namespace with a VPN container, it is describing a configuration that no longer exists.

- Torrenting port: `31288` (`QBT_TORRENTING_PORT`, exposed on the `bittorrent` LB Service, UPnP
  disabled)
- DHT/PeX/Local Peer Discovery: disabled (private trackers only)
- Seeding rule via qui Automation: ratio ≥ 1.1 AND seeding time ≥ 259,200s (3 days) → Pause
- Global share limits in qBittorrent: disabled (qui handles it)
- Carries `components/zeroscaler` — it idles out when nothing is downloading

## Jellyfin

- Attached to **three** hostnames: `jellyfin.dcunha.io` on internal + external gateways, and
  `jellyfin.frostlink.dev` on `edge-gateway` (towonel). See `.agents/references/networking.md`.
- Carries `components/zeroscaler` — so `kubectl rollout restart deployment jellyfin -n media` is
  a **no-op while it is scaled to zero**. Wake it with a request first, or delete the running
  pod. For read-only inspection prefer the `-ops` MCP k8s tools over `kubectl`
  (`cluster-conventions.md` § Cluster Inspection).
- Trickplay: enabled. If it stops, restart the pod once it is awake.
- Streamyfin plugin installed (push notifications, casting, TV login)
- AnilistSync plugin for per-user AniList scrobbling

## seerr (formerly Jellyseerr)

The app was renamed. The directory is `kubernetes/apps/media/seerr/`, the image is
`ghcr.io/seerr-team/seerr`, and there is **no `jellyseerr` directory**. Anything still saying
"Jellyseerr" is stale — the `litellm-media` MCP tools also surface as `seerr-*`.

- Served on both `seerr.dcunha.io` and `requests.dcunha.io`, internal + external gateways
- Tag Requests enabled (tags pass to Sonarr/Radarr → visible in Jellyfin metadata)
- Webhook to Streamyfin for push notifications:

    ```json
    { "title": "{{subject}}", "body": "{{message}}", "username": "{{requestedBy_username}}" }
    ```

## Data layer

Media apps that need a real database use the shared services in `database`, not their own —
see `.agents/references/postgres-dragonfly.md`.

| App            | Postgres                      | Dragonfly index |
| -------------- | ----------------------------- | --------------- |
| `paperless`    | shared, via `pooler-rw`       | 1               |
| `streamystats` | shared, via pgbouncer sidecar | —               |
| `bookboss`     | shared, via `pooler-rw`       | —               |
| `trawl`        | —                             | 5               |

## TrueNAS NFS

- Server: `10.10.99.100` | Path: `/mnt/atlas/media`
- Mounted at `/media` in pods
- `force user = apps` / `force group = apps` (UID 1000) — all writes land as UID 1000
- `kaizoku` is the exception: it runs PUID 99 / PGID 100
