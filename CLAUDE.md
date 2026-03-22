# Artemis-Cluster — Claude Context

## Identity
- **Jellyfin username**: Dixon (admin)
- **Location**: Mississauga, Ontario (Eastern Time)
- **Perplexity Space**: https://www.perplexity.ai/spaces/homelab-n1LMywDXROKveP48lmw2Jg

---

## Cluster Overview
- **Name**: Artemis-Cluster
- **OS**: Talos Linux (immutable k8s OS)
- **GitOps**: Flux CD with Flux Operator (flux-operator + FluxInstance)
- **Secrets**: SOPS + age keys (`~/.config/sops/age/keys.txt`)
- **Repo**: https://github.com/Exikle/Artemis-Cluster
- **Domain**: `dcunha.io`
- **CNI**: Cilium (with BGP)
- **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)
- **Certs**: cert-manager + ExternalDNS → Cloudflare

---

## Hardware

### Kubernetes Control Planes (Metal)
- **3× Lenovo M710q**
  - Hostnames: `talos-cp-01`, `talos-cp-02`, `talos-cp-03`
  - Boot: 256GB NVMe SSD
  - Ceph OSD: 256GB SATA SSD (one per node = 3 OSDs total)
  - Network: static IPs on VLAN 1099 (LAB)

### Kubernetes Workers (Proxmox VMs on `pantheon`)
- **3× Talos VMs**: `talos-w-01`, `talos-w-02`, `talos-w-03`
  - RAM: 32GB each
  - vCPUs: 4 (can safely bump to 6-8, host has 24 cores total)
  - Disk: 64GB
  - Network: VLAN trunk 1099 (LAB) + 1152 (IOT)

### Proxmox Host (`pantheon`)
- **HPE ML150 G9**
- CPU: 2× Intel Xeon E5-2620 v3 (12c/24t per socket = 24 cores total)
- OS: Proxmox (Debian Trixie / PVE 6.17.2)
- Also hosts: Technitium DNS VM, pve-scripts, ubuntu-cl
- HP RAID card (P440/H240) needs HBA mode enabled via BIOS (ssacli) to expose raw disks

### Firewall/Router
- **pfSense** (metal 1U): Intel Xeon E-2124G, 16GB RAM, Mellanox SFP+ card → Mikrotik
- **Recently migrated to UniFi Cloud Gateway Max** (pfSense replaced)
- **Mikrotik CRS309-1G-8S+**: L3 mode with BGP

### Switches & APs
- UniFi US-48 PoE 500W
- UniFi UCK-G2-PLUS
- UniFi US-16 PoE 150W (+ downstream Dell switch)
- 3× UniFi AC Lite APs (one per floor)

### Storage
- **TrueNAS host** (`atlas`): Xeon E5-2643 v0, 94.3GB ECC RAM
  - Pool: 3× RAIDZ2 6-wide of 3.49TB drives + 1TB mirror metadata vdev (~41TB usable)
  - NFS export: `/mnt/atlas/media` → mounted in pods as `/media`
  - SMB: `force user = apps` / `force group = apps` (UID 1000) for read/write access

### Offline / Storage
- **Dell R710**: in rack, powered off — potential GPU node if CPUs are decent
- **IBM Storwize V7000**: ~80-100TB, in storage, powered off
- **Xyratex JBOC**: expansion array, no drives, in storage
- **MSI RX 5700 XT**: available for GPU node (RDNA1, 8GB, VAAPI h264/h265 encode)

### UPS
- **Eaton UPS**: second hand, batteries are dead — not providing real protection

### WAN
- 1.5 Gbps down / 45 Mbps up

---

## Networking

### VLANs
| ID | Name | Subnet | Purpose |
|---|---|---|---|
| 1 | LAN | 192.168.1.0/24 | Legacy/default |
| 1088 | TST | 192.168.88.0/24 | Testing |
| 1001 | HME | 10.10.1.0/24 | Trusted home users |
| 1099 | LAB | 10.10.99.0/24 | Servers, K8s nodes (static IPs) |
| 1151 | GST | 10.10.151.0/24 | Guest |
| 1152 | IOT | 10.10.152.0/24 | IoT |
| 99 | TRANSIT | 172.16.99.0/30 | pfSense ↔ Mikrotik BGP |

- **DNS**: Technitium @ 10.10.99.3 (Proxmox VM)
- K8s worker pods can reach IOT VLAN (intentional, for Frigate/Home Assistant)

---

## Repo Structure
```
bootstrap/      # Bootstrap justfile (mod.just) — run order matters
talos/          # Talos node configs (controlplane.yaml, worker.yaml)
kubernetes/
  apps/         # App HelmReleases by namespace
    flux-system/ # flux-operator, flux-instance, flux-monitor, notifications, secrets/
  components/   # Shared kustomize components
  flux/
    sync/       # Entrypoint: single Kustomization pointing to ./kubernetes/apps
  mod.just      # Kubernetes task recipes
scripts/        # Utility scripts
mise.toml       # Tool version management
```

---

## Flux Operator Architecture
- **Pattern**: Flux Operator (manages Flux lifecycle) + FluxInstance (defines sync config)
- **Sync entrypoint**: `kubernetes/flux/sync/` → points to `kubernetes/apps`
- **FluxInstance** lives in `kubernetes/apps/flux-system/flux-instance/`
- **Upgrade Flux**: change version in `flux-instance.yaml` — operator handles rolling update
- **Bootstrap secrets** (manually applied first, then Flux manages):
  - `age-key.secret.sops.yaml` — SOPS decryption key
  - `github.secret.sops.yaml` — Git auth for Flux
  - `cluster-secrets.secret.sops.yaml`
  - `bitwarden-provider.secret.sops.yaml`
  - All live in `kubernetes/apps/flux-system/secrets/`
- `flux-instance` Kustomization must have `prune: false` — never prune Flux itself

---

## Namespaces & Apps
| Namespace | Key Apps |
|---|---|
| `flux-system` | flux-operator, flux-instance, flux-monitor, notifications, bootstrap secrets |
| `media` | Sonarr (×3), Radarr, Jellyfin, Jellyseerr, SABnzbd, qBittorrent+Gluetun, Prowlarr, autobrr, cross-seed, qui, Recyclarr, Bazarr, seasonpackarr, Dispatcharr |
| `rook-ceph` | Rook-Ceph cluster (block storage) |
| `network` | Ingress, Cloudflare tunnel |
| `cert-manager` | TLS certs |
| `observability` | Prometheus, Grafana, Loki |
| `home-automation` | Home Assistant, Homebridge, Frigate, Mosquitto, Zigbee2MQTT, Matter Server |
| `external-secrets` | External Secrets Operator (Bitwarden provider) |

---

## Storage (Rook-Ceph)
- 3 OSDs on M710q nodes (256GB SATA SSD each)
- `useAllNodes: false` with explicit node list — do NOT change to `useAllNodes: true`
- Usable: ~256GB (replicated ×3) — fine for app config/databases, not bulk media
- `pg_autoscaler` enabled but cannot scale past `mon_max_pg_per_osd=250` hard limit
- Media data lives on TrueNAS NFS, not Ceph

---

## Media Stack Architecture

### Arr Stack
- **Sonarr**: 3 separate instances — TV, K-Drama, Anime (one per library type)
- **Radarr**: Movies
- **Bazarr**: Subtitles
- **Prowlarr**: Central indexer manager → syncs to all arr apps + autobrr
  - Uses internal cluster DNS: `http://sonarr.media.svc.cluster.local:8989`
  - HD-Space indexer added with Flaresolverr proxy
  - NZBGeek: `URL=https://api.nzbgeek.info`, `Indexer URL=https://nzbgeek.info`
  - NZBPlanet: lifetime account, via API key
- **Recyclarr**: CronJob (bjw-s app-template) for quality profile sync
- **seasonpackarr**: Season pack handling

### Download Clients
- **SABnzbd** (Usenet):
  - SABnzbd incomplete dir must be on Rook-Ceph block storage (not TrueNAS NFS) — NFS chokes on RAR unpacking IOPS
  - Server tiering (final config, username `exikle` for all Frugal):
    - P0: Frugal US `news.frugalusenet.com` 50 conn (Omicron, ~3000 day retention)
    - P1: Frugal EU `eunews.frugalusenet.com` 30 conn (Omicron EU/NTD fallback)
    - P2: NewsDemon `news.newsdemon.com` 40 conn — **expires 2026-04-21**, delete then
    - P3: Frugal Bonus `bonus.frugalusenet.com` 50 conn (Usenet.Farm EU, 1TB/month cap)
    - P4: NGD 1TB block `us.newsgroupdirect.com` 20 conn (UsenetExpress backbone)
    - P5: Blocknews 300GB `us.blocknews.net` 10 conn (Omicron, 6000+ day retention)
  - `article_cache=2G`, `receive_threads=4`, SSL port 563, SSL ciphers `CHACHA20`

- **qBittorrent 5.1.4** + **Gluetun VPN sidecar** (same pod, shared network namespace)
  - Port forwarded: 31288 (set in Connection settings, UPnP disabled)
  - DHT/PeX/Local Peer Discovery: disabled (private trackers only)
  - Torrent queueing: disabled (all torrents active 24/7)
  - **qui** manages qBittorrent (autobrr team's web UI)
  - Seeding rule via **qui Automation** (AND logic — qBittorrent native is OR):
    - Condition: ratio ≥ 1.1 AND seeding time ≥ 259,200 seconds (3 days)
    - Action: Pause
  - qBittorrent global share limits: disabled (let qui handle it)

### Cross-seeding
- **cross-seed** + **qui** for cross-seeding across trackers
- Private tracker: **Luminarr** (requires 3 days seed + 1.0 ratio minimum)
- **CRITICAL**: Never enable "Remove Completed" in Sonarr/Radarr download client — deletes data cross-seed depends on

### Jellyfin
- URL: https://jellyfin.dcunha.io
- Trickplay enabled; if it stops: `kubectl rollout restart deployment jellyfin -n media`
- **Streamyfin** plugin installed — users use Streamyfin app for push notifications, casting, TV login
- **AnilistSync** (Fallenbagel's plugin) for per-user AniList scrobbling
- Admin notifications (playback started, session started) can be disabled in Jellyfin Dashboard → Notifications

### Jellyseerr
- Requests URL: https://requests.dcunha.io
- Tag Requests enabled → passes tags to Sonarr/Radarr → Kodi metadata → visible in Jellyfin
- Webhook to Streamyfin plugin for user-targeted push notifications:
  ```json
  {"title": "{{subject}}", "body": "{{message}}", "username": "{{requestedBy_username}}"}
  ```

### Dispatcharr
- IPTV management (deployed in media namespace)

### autobrr
- Connected to Prowlarr + NZBGeek (as Newznab feed)
- NZBGeek in autobrr: less useful (Sonarr/Radarr handles Usenet fine); most valuable for private torrent tracker IRC announcers (ratio racing)
- Used for racing on private torrent trackers

---

## Helm Charts
- **Primary**: `bjw-s/app-template` v3.x — used for almost all app HelmReleases
- **Rook-Ceph**: official rook-ceph charts
- **Flux Operator**: `oci://ghcr.io/controlplaneio-fluxcd/charts`
- Source repos defined in `kubernetes/flux/`

---

## Dev Tooling
Managed via `mise` (`mise.toml` in repo root):
```toml
[tools]
uv = "latest"
"pipx:flux-local" = "latest"
tahelper = "latest"
prettier = "latest"
node = "latest"
helm = "4.1.3"
k9s = "latest"
```
Install: `mise install`
Task runner: `just` (recipes in `bootstrap/mod.just` and `kubernetes/mod.just`)

---

## Bootstrap Order (after Talos install)
1. `talosctl apply-config --insecure --nodes <cp-ip> --file talos/controlplane.yaml`
2. `talosctl apply-config --insecure --nodes <worker-ip> --file talos/worker.yaml`
3. `talosctl bootstrap --nodes <cp-ip>`
4. `talosctl kubeconfig --nodes <cp-ip> --force`
5. `kubectl create namespace flux-system`
6. Manually apply age key: `cat age.agekey | kubectl create secret generic sops-age -n flux-system --from-file=age.agekey=/dev/stdin`
7. Apply SOPS encrypted Cloudflare bootstrap secret (Tunnel ID: `REDACTED`)
8. Bootstrap Flux pointing at `kubernetes/flux/sync/`

---

## Cloudflare
- Tunnel ID: `REDACTED`
- Bootstrap secret: `cloudflare-bootstrap` in `flux-system`, encrypted with SOPS

---

## Known Issues & Fixes
- **Rook-Ceph mgr/mon crash**: `device_failure_prediction_mode: local` in cephConfig with `diskprediction_local` module disabled → remove that line or enable the module
- **Cross-seed data loss**: Never enable "Remove Completed" in download client settings
- **Rook-Ceph TOO_MANY_PGS**: `pg_autoscaler` can't exceed `mon_max_pg_per_osd=250` → add OSDs or reduce pool count
- **Proxmox HP RAID card**: Use ssacli or BIOS (F9 → System Utilities) to switch controller to HBA mode so raw disks are visible
- **NewsDemon expiry**: Delete SABnzbd server P2 (NewsDemon) on/after 2026-04-21

---

## Conventions
- All secrets encrypted with SOPS before committing
- `kubectl rollout restart` to restart pods (avoid deleting pods directly)
- Kustomize configmap generators to bundle multiple config files into one ConfigMap
- Reloader annotations (`reloader.stakater.com/auto: "true"`) on controllers needing restart on config change
- Prowlarr is the single indexer source of truth — do not add indexer API keys directly to Sonarr/Radarr/etc.
- Indexer configs live in Prowlarr's internal SQLite DB (stateful PVC), not in Git
- Internal cluster routing: always use `<app>.<namespace>.svc.cluster.local` (not external DNS) for pod-to-pod comms
