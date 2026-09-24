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
| `prowlarr`    | `ghcr.io/home-operations/prowlarr`                 | Central indexer manager → syncs to all arr apps + autobrr                                                          |
| `sabnzbd`     | `ghcr.io/home-operations/sabnzbd`                  | Usenet downloads                                                                                                   |
| `qbittorrent` | `ghcr.io/home-operations/qbittorrent-libtorrentv1` | Torrents — **single container, no VPN sidecar**                                                                    |
| `qui`         | `ghcr.io/autobrr/qui`                              | qBittorrent web UI + cross-seed automation — **upstream autobrr, not a fork**                                      |
| `autobrr`     | `ghcr.io/autobrr/autobrr`                          | IRC announcers for private trackers (`id.dcunha.io` OIDC)                                                          |
| `bazarr`      | `ghcr.io/home-operations/bazarr`                   | Subtitles (behind the `tinyauth` component)                                                                        |
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
- **SABnzbd incomplete dir on block storage (`miroir`)** — NFS chokes on RAR unpacking IOPS; incomplete must be
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
- Seeding rule via qui Automation: ratio ≥ 1.1 AND seeding time ≥ 259,200s (3 days) → Pause
- Global share limits in qBittorrent: disabled (qui handles it)
- Carries `components/zeroscaler`. Note it does **not** idle out when nothing is downloading —
  the HPA reads a shared `probe_success` metric, not this app's traffic, and it has sat at one
  replica throughout. See § Scale-to-zero.

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
