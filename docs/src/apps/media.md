# Media Stack

The media stack lives in the `media` namespace. All apps share the TrueNAS NFS mount at `/media`.

---

## Applications

| App                   | Purpose                         | URL                        |
| --------------------- | ------------------------------- | -------------------------- |
| Jellyfin              | Media server                    | https://jellyfin.dcunha.io |
| Jellyseerr            | Request management              | https://requests.dcunha.io |
| Sonarr (TV)           | TV series management            | internal                   |
| Sonarr (K-Drama)      | K-Drama library                 | internal                   |
| Sonarr (Anime)        | Anime library                   | internal                   |
| Radarr                | Movie management                | internal                   |
| Bazarr                | Subtitle management             | internal                   |
| Prowlarr              | Central indexer manager         | internal                   |
| SABnzbd               | Usenet download client          | internal                   |
| qBittorrent + Gluetun | Torrent client (VPN)            | internal                   |
| qui                   | qBittorrent web UI + automation | internal                   |
| autobrr               | IRC-based release automation    | internal                   |
| Dispatcharr           | IPTV management                 | internal                   |
| Recyclarr             | Quality profile sync (CronJob)  | —                          |
| FlareSolverr          | Cloudflare bypass proxy         | internal                   |
| TheLounge             | Web IRC client                  | internal                   |
| cross-seed            | Cross-seeding (built into qui)  | —                          |

---

## Jellyfin

- **Trickplay:** enabled
- **Streamyfin plugin:** installed — users connect via Streamyfin app for push notifications, casting, and TV login
- **AnilistSync (Fallenbagel's plugin):** per-user AniList scrobbling

If Trickplay stops working:

```bash
kubectl rollout restart deployment jellyfin -n media
```

---

## Jellyseerr

- **Tag Requests enabled** — passes tags to Sonarr/Radarr for Kodi metadata, visible in Jellyfin
- **Streamyfin webhook** for user-targeted push notifications:
    ```json
    { "title": "{{subject}}", "body": "{{message}}", "username": "{{requestedBy_username}}" }
    ```

---

## Arr Stack

Three Sonarr instances manage separate libraries. All connect to Prowlarr as the single indexer source of truth.

**Rule:** Never add indexer API keys directly to Sonarr/Radarr. All indexers are managed in Prowlarr and synced automatically. Indexer configs live in Prowlarr's internal SQLite DB (stateful PVC), not in Git.

Internal cluster routing uses `<app>.media.svc.cluster.local`:

- Sonarr TV: `http://sonarr.media.svc.cluster.local:8989`
- Prowlarr: `http://prowlarr.media.svc.cluster.local:9696`

---

## SABnzbd (Usenet)

SABnzbd incomplete dir must be on **Rook-Ceph block storage** (not TrueNAS NFS) — NFS cannot handle the random IOPS of RAR unpacking.

Server configuration:

| Priority | Server                        | Host                    | Connections | Notes                  |
| -------- | ----------------------------- | ----------------------- | ----------- | ---------------------- |
| P0       | Frugal US (Omicron)           | news.frugalusenet.com   | 50          | ~3000 day retention    |
| P1       | Frugal EU                     | eunews.frugalusenet.com | 30          | EU/NTD fallback        |
| P2       | Frugal Bonus (Usenet.Farm EU) | bonus.frugalusenet.com  | 50          | 1 TB/month cap         |
| P3       | NGD 1 TB block                | us.newsgroupdirect.com  | 20          | UsenetExpress backbone |
| P4       | Blocknews 300 GB              | us.blocknews.net        | 10          | 6000+ day retention    |

Config: `article_cache=2G`, `receive_threads=4`, SSL port 563, ciphers `CHACHA20`.

---

## qBittorrent + Gluetun

qBittorrent and the Gluetun VPN sidecar run in the same pod (shared network namespace). All torrent traffic is tunnelled through Gluetun.

- **Port forwarded:** configured in qBittorrent Connection settings (UPnP disabled)
- **DHT/PeX/Local Peer Discovery:** disabled (private trackers only)
- **Torrent queueing:** disabled (all torrents active 24/7)
- **Global share limits:** disabled — handled by qui Automation

### qui Seeding Automation

qui manages qBittorrent with AND-logic seeding rules (qBittorrent native is OR-only):

- **Condition:** ratio ≥ 1.1 **AND** seeding time ≥ 259,200 s (3 days)
- **Action:** Pause

Minimum tracker requirements apply — check each tracker's rules for ratio and seed time.

---

## autobrr

autobrr monitors IRC announcers for private torrent trackers and Prowlarr feeds. Used primarily for ratio racing — grabbing releases the moment they're announced.

Connected to:

- Prowlarr (for indexer feeds)
- NZBGeek (as Newznab feed, secondary)

The `AutobrrNetworkUnmonitored` PrometheusRule fires if an IRC channel goes unmonitored for more than 1 hour. If it fires for a specific network, restart autobrr:

```bash
kubectl rollout restart deployment autobrr -n media
```

---

## Cross-seeding

Cross-seeding is built into **qui** — there is no separate cross-seed deployment.

**Critical:** Never enable "Remove Completed" in Sonarr/Radarr download client settings. Enabling it deletes source files that cross-seed depends on.

---

## Recyclarr

Runs as a CronJob to sync quality profiles from [TRaSH Guides](https://trash-guides.info/) to Sonarr and Radarr.

```bash
# Force a manual run
kubectl create job --from=cronjob/recyclarr recyclarr-manual -n media
```
