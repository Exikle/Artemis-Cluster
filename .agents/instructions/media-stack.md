# Media Stack — Artemis-Cluster

## Architecture

- **Sonarr**: 3 instances — TV, K-Drama, Anime (separate PVCs, separate ports)
- **Radarr**: Movies
- **Prowlarr**: Central indexer manager → syncs to all arr apps + autobrr. Single source of truth for indexers.
- **SABnzbd**: Usenet downloads (incomplete dir on Rook-Ceph block, not TrueNAS NFS)
- **qBittorrent 5.x + Gluetun**: Torrent + VPN sidecar (shared network namespace)
- **qui**: qBittorrent web UI + cross-seed automation (Exikle's fork) — cross-seed is built into qui, not a separate deployment
- **autobrr**: IRC announcers for private torrent trackers
- **Bazarr**: Subtitles
- **Recyclarr**: Quality profile sync (CronJob)
- **Jellyfin**: Media server — URL: https://jellyfin.dcunha.io
- **Jellyseerr**: Requests — URL: https://requests.dcunha.io

## Critical Rules

- **Never enable "Remove Completed"** in Sonarr/Radarr download client settings — cross-seed depends on files staying
- **Prowlarr is the indexer source of truth** — never add indexer API keys directly to Sonarr/Radarr/Bazarr
- **cross-seed is built into qui** — do not deploy it as a standalone app
- **SABnzbd incomplete dir on Ceph** — NFS chokes on RAR unpacking IOPS; incomplete must be block storage

## Internal Cluster DNS (pod-to-pod)

Always use cluster-local DNS, never external:

```
http://sonarr.media.svc.cluster.local:8989
http://radarr.media.svc.cluster.local:7878
http://prowlarr.media.svc.cluster.local:9696
http://sabnzbd.media.svc.cluster.local:8080
http://qbittorrent.media.svc.cluster.local:8080
```

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

- Port forwarded: 31288 (set in Connection settings, UPnP disabled)
- DHT/PeX/Local Peer Discovery: disabled (private trackers only)
- Seeding rule via qui Automation: ratio ≥ 1.1 AND seeding time ≥ 259,200s (3 days) → Pause
- Global share limits in qBittorrent: disabled (qui handles it)

## Jellyfin

- Trickplay: enabled. If it stops: `kubectl rollout restart deployment jellyfin -n media`
- Streamyfin plugin installed (push notifications, casting, TV login)
- AnilistSync plugin for per-user AniList scrobbling

## Jellyseerr

- Tag Requests enabled (tags pass to Sonarr/Radarr → visible in Jellyfin metadata)
- Webhook to Streamyfin for push notifications:
    ```json
    { "title": "{{subject}}", "body": "{{message}}", "username": "{{requestedBy_username}}" }
    ```

## TrueNAS NFS

- Server: `10.10.99.100` | Path: `/mnt/atlas/media`
- Mounted at `/media` in pods
- `force user = apps` / `force group = apps` (UID 1000) — all writes land as UID 1000
