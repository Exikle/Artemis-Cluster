# Media Stack — Artemis-Cluster

Verified against the live cluster 2026-08-21 — images, service ports, HTTPRoutes and zeroscaler
membership all re-checked against running objects, not just the tree. App lists rot — run
`ls kubernetes/apps/media/` for the current set rather than trusting this section.

## Architecture

Live apps in `kubernetes/apps/media/` (21 as of 2026-08-21):

### Acquisition

| App           | Image                                              | Role                                                                                                               |
| ------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `sonarr`      | `ghcr.io/home-operations/sonarr`                   | TV (single instance)                                                                                               |
| `radarr`      | `ghcr.io/home-operations/radarr`                   | Movies                                                                                                             |
| `prowlarr`    | `ghcr.io/home-operations/prowlarr`                 | Central indexer manager → syncs to Sonarr and Radarr (autobrr uses IRC announces, not Prowlarr)                    |
| `sabnzbd`     | `ghcr.io/home-operations/sabnzbd`                  | Usenet downloads                                                                                                   |
| `qbittorrent` | `ghcr.io/home-operations/qbittorrent-libtorrentv1` | Torrents — **single container, no VPN sidecar**                                                                    |
| `qui`         | `ghcr.io/autobrr/qui`                              | qBittorrent web UI + cross-seed automation — **upstream autobrr, not a fork**                                      |
| `autobrr`     | `ghcr.io/autobrr/autobrr`                          | IRC announcers for private trackers (`id.dcunha.io` OIDC)                                                          |
| `bazarr`      | `ghcr.io/home-operations/bazarr`                   | Subtitles (behind the `envoy-oidc` component; own auth off, see `identity-stack.md`)                               |
| `recyclarr`   | `ghcr.io/recyclarr/recyclarr`                      | Quality profile sync (CronJob — no Service, no route)                                                              |
| `trawl`       | `ghcr.io/germondai/trawl`                          | Camoufox/Firefox-based challenge solver — replaced `flaresolverr`, same `:8191`, `:8191` — Dragonfly index 5 cache |

**immich lives in `media` too** — moved from `default`, three Kustomizations
(`immich-app`, `immich-microservices`, `immich-machine-learning`; there is no `database/`
component since it was consolidated onto the shared CNPG cluster on 2026-09-01). It is a photo
library rather than part of the Arr chain, which is why it does not appear in the tables above.

### Playback and requests

| App            | Image                                                       | Role                                                                                                                                                                                                                                                           |
| -------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `jellyfin`     | `ghcr.io/jellyfin/jellyfin`                                 | Media server — `jellyfin.dcunha.io` + `jellyfin.frostlink.dev`                                                                                                                                                                                                 |
| `seerr`        | `ghcr.io/seerr-team/seerr`                                  | Requests — `seerr.dcunha.io` **and** `requests.dcunha.io`                                                                                                                                                                                                      |
| `autopulse`    | `ghcr.io/dan-online/autopulse`                              | Library-refresh trigger into Jellyfin, `:2875` API / `:2885` UI                                                                                                                                                                                                |
| `streamystats` | `ghcr.io/fredrikburmester/streamystats-{job-server,nextjs}` | Jellyfin watch statistics — two Deployments (`streamystats-nextjs-app`, `streamystats-job-server`) behind Services `streamystats-app` `:3000` / `streamystats-job-server` `:3005`, each with a `ghcr.io/cloudnative-pg/pgbouncer` sidecar onto shared Postgres |

### Books, comics, documents

| App         | Image                                 | Role                                                                                                                              |
| ----------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `bookboss`  | `ghcr.io/szinn/bookboss`              | Ebook library at `books.dcunha.io` — shared Postgres, OIDC                                                                        |
| `shelfmark` | `ghcr.io/calibrain/shelfmark`         | Book search/ingest at `booksearch.dcunha.io`, `:8084` — OIDC, talks to Prowlarr on `:80`                                          |
| `rensaio`   | `docker.io/maxpiva/rensaio`           | Manga downloader, `:9833` — PUID 99 / PGID 100 (not the usual 1000); library at `downloads/kaizoku`                               |
| `komf`      | `sndxr/komf`                          | Metadata for Komga — Komga itself lives in `default`, not `media`                                                                 |
| `paperless` | `ghcr.io/paperless-ngx/paperless-ngx` | Document management — shared Postgres + Dragonfly index 1, plus `paperless-tika` and `paperless-gotenberg` sidecar kustomizations |

### Chat

| App         | Image                         | Role                            |
| ----------- | ----------------------------- | ------------------------------- |
| `thelounge` | `ghcr.io/thelounge/thelounge` | Self-hosted IRC client, `:9000` |

## Scale-to-zero — read this before diagnosing "X is down"

Several media apps carry `components/zeroscaler`, an HPA with `minReplicas: 0` that scales the
Deployment down and back up on an external `probe_success` metric. Who carries it changes — the
list is not written here:

```bash
grep -rln 'components/zeroscaler' kubernetes/apps/   # the tree
kubectl get hpa -A                                   # what is actually live
```

Consequences that catch people out:

- **A zeroscaled app can legitimately be at zero replicas.** "No pods for sonarr" is not
  automatically an outage — check the HPA before escalating.
  **But do not assume zero is the normal state either:** as measured on 2026-09-01, every
  zeroscaled app was sitting at 1 replica, and the 14-day average replica count was ≈1.0 for all
  of them. In practice these apps are not idling down. Read the live HPA rather than assuming
  either direction.
- **`kubectl rollout restart` is a no-op on a scaled-to-zero Deployment.** To force a restart,
  wake the app first (hit its hostname), then restart — or just delete the running pod.
- **It is not confined to `media`.** `default/komga` carries it too, so a cluster-wide zeroscaler
  failure takes Komga with it. The grep above covers every namespace for that reason.
- The whole scheme hangs off one blackbox-exporter and one metric series. If _every_ zeroscaler
  app looks down at once, suspect the metric path, not the apps — see the chain below.
- **The reason they never idle: every HPA reads the same metric, and it is a NAS probe.** All of
  them select `probe_success{job="blackbox-tcp"}` with no per-app discriminator, and `Probe/tcp`
  in `observability` has exactly one static target —
  `truenas.external-endpoints.svc.cluster.local:2049`. Nothing overrides `ZEROSCALER_JOB_NAME` or
  `ZEROSCALER_METRIC_NAME` anywhere in the tree. So the component is a TrueNAS-availability gate,
  not an idle-scaler: apps stay at 1 while the NAS answers, and a single NFS probe blip scales all
  of them to zero together. Decision on whether to drop, fix or rename it is parked in
  [#1901](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/1901).

### The wake-up path is a chain, and blackbox-exporter is only its first link

The HPA scales on an **External** metric, which means it goes through the custom-metrics API:

```text
blackbox-exporter → vmagent → victoria-metrics-server → prometheus-adapter → HPA → Deployment
       probe_success{job="blackbox-tcp"} == 1  →  scale 0 → 1
```

`observability/prometheus-adapter` is the sole provider of the
`v1beta1.external.metrics.k8s.io` APIService. If it is unhealthy, every zeroscaler HPA reads
`<unknown>/1` and every one of those apps stays at zero — with the probes green and the exporter
fine. Nothing alerts on it. The blast radius is every app the grep above returns, cluster-wide.

Diagnose "everything in media is down" in this order:

```bash
kubectl get apiservice v1beta1.external.metrics.k8s.io    # AVAILABLE must be True
kubectl get hpa -n media                                  # TARGETS <unknown>/1 == adapter fault
kubectl get pods -n observability -l app.kubernetes.io/name=blackbox-exporter
```

## Critical Rules

- **Never enable "Remove Completed"** in Sonarr/Radarr download client settings — cross-seed
  depends on files staying
- **Prowlarr is the indexer source of truth** — never add indexer API keys directly to
  Sonarr/Radarr/Bazarr
- **cross-seed is built into qui** — do not deploy it as a standalone app
- **K-drama / C-drama routing lives in seerr, not git.** seerr only knows "normal" and "anime", so
  two Override Rules on the Sonarr service send TMDB original language `ko` → K-Drama profile +
  `/media/kdrama` and `zh|cn` → C-Drama profile + `/media/cdrama`. seerr skips rules for anime TV,
  which keeps its anime route. List them with `GET /api/v1/overrideRule`
- **Quality profiles are owned by recyclarr** (`recyclarr/app/resources/recyclarr.yml`) and are
  referenced by TRaSH `trash_id`, not by name — a name reference silently stops matching when the
  guide renames a profile (`SQP-1 (2160p)` became `[SQP] SQP-1 (2160p)` and left its scores at 0)
- **SABnzbd incomplete dir is on the NFS media share** (`/media/downloads/usenet/incomplete`), the same
  filesystem as `complete`, so finishing a job is a rename rather than a cross-filesystem copy. Moving it to
  block storage would need a new volume and would turn every unpack into a copy — do not move it with jobs queued

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
http://trawl.media.svc.cluster.local:8191
http://immich.media.svc.cluster.local:2283
http://immich-ml.media.svc.cluster.local:3003
```

| App           | Correct port | Wrong (upstream default, and what old docs said) |
| ------------- | ------------ | ------------------------------------------------ |
| `sonarr`      | `80`         | `8989`                                           |
| `radarr`      | `80`         | `7878`                                           |
| `prowlarr`    | `80`         | `9696`                                           |
| `qbittorrent` | `80`         | `8080`                                           |
| `bazarr`      | `80`         | `6767`                                           |
| `autobrr`     | `80`         | `7474`                                           |
| `qui`         | `80`         | `7476`                                           |
| `seerr`       | `80`         | `5055`                                           |
| `sabnzbd`     | `8080`       | — `8080` is correct here                         |

**`:80` is not universal in this namespace.** Only the apps above were normalised. Everything
else keeps its upstream port, so assuming `:80` fails just as often as assuming `8989`:

| App                       | Port(s)                  |
| ------------------------- | ------------------------ |
| `jellyfin`                | `8096`                   |
| `paperless`               | `8000`                   |
| `paperless-tika`          | `9998`                   |
| `paperless-gotenberg`     | `3000`                   |
| `bookboss`                | `8080` http, `8081` grpc |
| `shelfmark`               | `8084`                   |
| `komf`                    | `8085`                   |
| `rensaio`                 | `9833`                   |
| `thelounge`               | `9000`                   |
| `autopulse`               | `2875` api, `2885` ui    |
| `streamystats-app`        | `3000`                   |
| `streamystats-job-server` | `3005`                   |
| `flaresolverr` / `trawl`  | `8191`                   |

Confirm before wiring — the Service is authoritative, the anchor only tells you what was intended:

```bash
kubectl get svc -n media <app> -o jsonpath='{.spec.ports}'
```

`autobrr` and `qui` additionally expose a metrics port (`9094` and `8080`) and are the only two
media apps with a `VMServiceScrape`. Nothing else in `media` is scraped.

## SABnzbd Server Priority

The live `sabnzbd.ini` on the PVC is authoritative — this table records the intent behind the
ordering, not a snapshot to trust blindly.

| Priority | Server                 | Host                     |
| -------- | ---------------------- | ------------------------ |
| P0       | Frugal US              | news.frugalusenet.com    |
| P0       | Frugal EU              | eunews.frugalusenet.com  |
| P1       | NewsGroup Direct - 1TB | news.newsgroupdirect.com |
| P2       | Frugal Bonus           | bonus.frugalusenet.com   |
| P3       | Blocknews - 300GB      | usnews.blocknews.net     |

The two Frugal unlimited servers deliberately share P0 — SABnzbd round-robins within a priority,
so US and EU are used as one pool rather than one falling back to the other. The block accounts
below them are strictly ordered so the metered ones are only touched on a miss.

The expired NewsDemon block account was removed on 2026-09-02 (#1890). Provider credentials are
stored only in `sabnzbd.ini`, not in 1Password — the `sabnzbd` item there holds just the API keys.

## qBittorrent

**There is no Gluetun sidecar and no VPN.** The HelmRelease has a single `app` container; a
`grep -c gluetun` over the whole app directory returns 0. Torrent traffic egresses directly
through a second `LoadBalancer` Service (`service.bittorrent`) pinned to `10.10.99.95` via
`io.cilium/lb-ipam-ips`, with `externalTrafficPolicy: Local`. If a doc claims a shared network
namespace with a VPN container, it is describing a configuration that no longer exists.

- Torrenting port: `31288` (`QBT_TORRENTING_PORT`, exposed on the `bittorrent` LB Service, UPnP
  disabled in the app and on the UCG). Reachable from the internet only through a **manual** UCG
  port forward `31288 → 10.10.99.95`, kept deliberately for peer connectivity; it is not in
  OpenTofu.
- DHT/PeX/Local Peer Discovery: disabled (private trackers only)
- Seeding rules via qui Automation, in this order. **Every delete rule removes the torrent only** —
  files are deleted solely by the orphan scan below:
    1. unregistered on its tracker (`IS_UNREGISTERED`, e.g. "Torrent has been deleted.") AND seeded ≥ 1
       day (gives Sonarr/Radarr time to import) → removed;
    2. cross-seeds (tag `cross-seed`) after 7 days with `HARDLINK_SCOPE = none` (no file in the library),
       any ratio → removed — cross-seeds download nothing, so no hit-and-run risk;
    3. cross-seeds at ratio ≥ 1.1 AND 7 days → removed;
    4. originals on Luminarr, DigitalCore, Rastastugan, HD-Space, BakaBT with `HARDLINK_SCOPE = none`
       after 7 days, **any ratio** → removed;
    5. originals on every other tracker with `HARDLINK_SCOPE = none` at ratio ≥ 1.1 AND 7 days → removed;
    6. everything else at ratio ≥ 1.1 AND 7 days → paused.

    Why torrent-only: qui's `deleteWithFilesPreserveCrossSeeds` detects shared files by identical
    content path. A folder-layout original and file-layout cross-seeds of the same release
    (The Wind Rises, 2026-09-30) did not match, so the original's delete took the cross-seeds' data.
    The orphan scan checks every file path each torrent references, so it cannot make that mistake.
    Rule 4's tracker list is time-only because each of those trackers' hit-and-run rule is satisfied by
    ≤ 5 days of seeding (checked 2026-09-30). AvistaZ is excluded — it needs 72h + 2h/GB, which exceeds
    7 days above ~48 GB. A new tracker belongs in rule 4 only after its rules are checked. Read them live
    with `select row_to_json(a) from automations a` in the `qui` database

- qui orphan scan runs daily with auto-cleanup (60 min grace, ≤1000 files per run). It deletes files
  under torrent save paths that no torrent references — anything dropped into `torrents/complete` by
  hand is fair game. Deleting a hardlinked file there only drops the download-folder link; the library
  copy survives. **Auto-cleanup refuses to run after a partial scan**, which happens when a torrent's
  save path no longer exists — remove that torrent (files already gone) to unblock it
- Global share limits in qBittorrent: disabled (qui handles it)
- Carries `components/zeroscaler`. Note it does **not** idle out when nothing is downloading —
  the HPA reads a shared `probe_success` metric, not this app's traffic, and it has sat at one
  replica throughout. See § Scale-to-zero.

## autobrr

- **A dropped IRC network does not come back on its own.** If the reconnect after a tracker's IRC
  restart fails (Luminarr, 2026-09-30: `SASL negotiation failed` while its services restarted),
  autobrr parks the network in an error state and never retries. The `irc-watchdog` CronJob
  (every 15 min, `app/resources/irc-watchdog.sh`, own API key `AUTOBRR_WATCHDOG_API_KEY` in the
  `autobrr` 1Password item) restarts networks that are unhealthy **with** a connection error, and
  fails if any network is still unhealthy. It never restarts a network that is merely slow to
  join — restarting one mid-connect leaves it stuck in `JoiningChannels` (“invalid state
  transition”), which only a pod restart clears.
- **Alert on the watchdog, not on autobrr's IRC metrics.** `autobrr_irc_channel_monitored_total`
  and `…_last_announced_timestamp_seconds` kept reporting Luminarr as live through a 20-hour
  outage. `AutobrrIrcNetworkDown` fires when the watchdog has not passed for an hour; the API's
  `healthy` field is the only reliable signal.
- Filters 1–3 exclude non-video categories (`except_categories`); every accepted grab over the
  30 days before the change came from a TV or movie category.

## Jellyfin

- **Two hostnames across two HTTPRoutes, and neither is on the internal gateway.**
  `jellyfin-app` binds `jellyfin.dcunha.io` to **`external-gateway` only**; `jellyfin-frostlink`
  binds `jellyfin.frostlink.dev` to `edge-gateway` (towonel). An older note here said three
  hostnames on internal + external — it is wrong, and it matters: there is no internal-gateway
  path to Jellyfin, so LAN clients egress and re-enter through the external gateway. See
  `.agents/references/networking.md` and `towonel-agent.md`.
- Service port is **`8096`**, not `80` — Jellyfin was not part of the `:80` normalisation.
- Carries `components/zeroscaler` — so `kubectl rollout restart deployment jellyfin -n media` is
  a **no-op while it is scaled to zero**. Wake it with a request first, or delete the running
  pod. For read-only inspection prefer the `-ops` MCP k8s tools over `kubectl`
  (`cluster-conventions.md` § Cluster Inspection).
- Trickplay: enabled. If it stops, restart the pod once it is awake.
- **New files reach Jellyfin only through autopulse.** Real-time folder monitoring is off on every
  media library (inotify never fires on the NFS share), and Radarr's built-in Emby/Jellyfin
  connection was removed. Sonarr and Radarr each have an `AutoPulse` webhook
  (`/triggers/sonarr`, `/triggers/radarr`, basic auth from the `autopulse` secret) on import,
  upgrade, rename and delete-for-upgrade; autopulse waits 60 s, then scans that path. If an
  import never shows up in Jellyfin, check `kubectl -n media logs deploy/autopulse -c app` for
  `added 1 file` / `sent 1 file to targets` before anything else.
- **Client IPs come from Envoy's `X-Forwarded-For`.** Jellyfin's network config trusts
  `KnownProxies: 10.42.0.0/16` (the pod range the Envoy pods live in) and treats
  `10.10.0.0/16` + `10.42.0.0/16` as local. KnownProxies is read only at startup — restart Jellyfin
  after changing it. Without it every viewer shows as an Envoy pod IP and counts as LAN.
- **The Arc A380 has no Resizable BAR and it cannot be enabled on that host.** Stay on VAAPI
  (+ OpenCL tone mapping, 4K HDR→1080p measured at 1.46× realtime); QSV's zero-copy path is the one
  that suffers most without ReBAR. Transcode throttling is on.
- **Sonarr and Radarr are the only metadata source — Jellyfin fetches nothing online.** Every
  media library has all metadata fetchers disabled and reads only the `.nfo` files and artwork the
  arrs' "Kodi (XBMC) / Emby" metadata writes at import; the `Nfo` saver is off so Jellyfin never
  rewrites them. This offloads metadata work from Jellyfin by design. Turning the arr metadata off
  leaves every new import without metadata (it was, briefly, on 2026-09-30 — no imports landed).
- **On 12.x, `X-Emby-Token` and `?api_key=` are dead.** The 12.0 upgrade runs a migration that
  forces `EnableLegacyAuthorization` to `false`, and `AuthorizationContext` gates both of those
  behind it. Only `Authorization: MediaBrowser Token="<key>"` (and `?ApiKey=`) still authenticate
  — anything here that talks to Jellyfin must send the header form.
- **A 12.x build may exist in a second manifest even when the documented one shows none.** Both
  Streamyfin and Neptune ship their Jellyfin 12 builds in an alternate manifest file alongside the
  10.11 one, and neither is flagged as a prerelease. Checking only the repository URL a project's
  README tells you to add produces a false negative — the 12.1 upgrade dropped three plugins on
  exactly that mistake. Before concluding a plugin has no 12.x build, list every `manifest*.json`
  in its repo:

    ```bash
    curl -sL 'https://api.github.com/repos/<owner>/<repo>/git/trees/main?recursive=1' \
      | jq -r '.tree[].path' | grep -i manifest
    ```

- **Custom Tabs was dropped deliberately (2026-09-19) and is not tracked.** It has no 12.x build,
  and it is not wanted — do not reinstate it or reopen an issue for it.
- **Neptune Indexers + MDM reinstalled (2026-09-19)** from
  `https://raw.githubusercontent.com/need4swede/neptune-plugins/main/manifest-12.0.json`, registered
  as the `Neptune (Jellyfin 12)` repository. The `jf-12.0` assets are attached to the ordinary
  stable `v1.3.2` release; only the manifest is separate. The README's documented repository URL
  (`https://plugins.neptuneplayer.com/manifest.json`) is 10.11-only and will never offer them.
  That repo also carries Neptune Transcoder and Studio, which are **not** installed.
- The pre-upgrade 10.11 plugin directories are parked on the config PVC at
  `/config/plugins.pre12-backup`.
- **Streamyfin is back (2026-09-19) and installed from the unstable channel.** It was dropped at the
  upgrade on the belief that it bundled a .NET 9 HarmonyLib that broke Harmony-patching plugins —
  that was a **misdiagnosis** (upstream #146); Streamyfin ships no `0Harmony.dll`. The real culprit
  was Home Screen Sections' first `3.0.0.0` upload for 12.0, re-uploaded fixed under the same
  version number. Streamyfin's 12.x build is not in `manifest.json` but in a second manifest:
  `https://raw.githubusercontent.com/streamyfin/jellyfin-plugin-streamyfin/main/manifest-unstable.json`,
  registered as the `Jellyfin Unstable` repository. Swap it for `manifest.json` once a 12.x stable
  lands, since that repo only ever serves unstable builds.
- **Ani-Sync was removed on 2026-09-19 and is not coming back.** It had been sideloaded by hand from
  the `v4.6b` prerelease because upstream never published a 12.x build to its manifest, leaving it
  unmanaged with no update path. Rather than carry that indefinitely it was uninstalled and its
  repository entry deleted. Anime scrobbling is now **AniList + AniDB + MyAnimeSync** only. Do not
  re-add it without being asked.
- The old `AnilistSync` (ARufenach) repo is dead — last built for 10.7 — and its repository entry
  was removed.

## seerr (formerly Jellyseerr)

The app was renamed. The directory is `kubernetes/apps/media/seerr/`, the image is
`ghcr.io/seerr-team/seerr`, and there is **no `jellyseerr` directory**. Anything still saying
"Jellyseerr" is stale — the `litellm-media` MCP tools also surface as `seerr-*`.

- One HTTPRoute carrying both `seerr.dcunha.io` and `requests.dcunha.io`, attached to internal
  **and** external gateways. Service port `80`.
- Tag Requests enabled (tags pass to Sonarr/Radarr → visible in Jellyfin metadata)
- Webhook to Streamyfin for push notifications — live. `POST http://jellyfin/Streamyfin/notification`
  with an `Authorization: MediaBrowser Token="…"` header holding a Jellyfin API key, and a JSON
  payload that is an **array**:

    ```json
    [
        {
            "title": "{{event}}: {{subject}}",
            "body": "{{message}}",
            "username": "{{requestedBy_username}}"
        }
    ]
    ```

    `username` must match a **Jellyfin** username exactly, and that user needs a registered Streamyfin
    device token. A mismatch is not an error: the endpoint answers `202` and logs
    `Received 0 valid notifications`, so the request is silently dropped. A match answers `200` and
    logs `Received 1 valid notifications`. Probe with the real username before concluding it is broken.

## Data layer

Media apps that need a real database use the shared services in `database`, not their own —
see `.agents/references/postgres-dragonfly.md`.

| App            | Postgres                      | Dragonfly index |
| -------------- | ----------------------------- | --------------- |
| `paperless`    | shared, via `postgres-rw`     | 1               |
| `streamystats` | shared, via pgbouncer sidecar | —               |
| `bookboss`     | shared, via `postgres-rw`     | —               |
| `trawl`        | —                             | 5               |

## TrueNAS NFS

- Server: `10.10.99.100` | Path: `/mnt/atlas/media`
- Mounted at `/media` in pods
- `force user = apps` / `force group = apps` (UID 1000) — all writes land as UID 1000
- `rensaio` is the exception: it runs PUID 99 / PGID 100
