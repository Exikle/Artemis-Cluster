# Reference: Storage — Artemis-Cluster

## pantheon (Proxmox host) — ZFS pools

HPE ML150 Gen9, 8 SFF bays on an LSI **SAS2116** HBA (IT mode, 16 ports). The OS SSD is on
the onboard Intel C610 AHCI controller and does **not** occupy a hot-swap bay.

| Pool       | Layout                   | Usable   | Holds                            |
| ---------- | ------------------------ | -------- | -------------------------------- |
| `vmpool`   | 2× mirror, 600GB 10K SAS | 1.09 TiB | Talos worker zvols + efidisks    |
| `bulkpool` | RAIDZ1, 3× 2TB 7.2K SATA | 3.52 TiB | vzdump backups (`recordsize=1M`) |

`hddpool` (RAIDZ1 of 3× worn ST500LM laptop drives) was destroyed 2026-08-04 — it was the
root cause of the recurring krbd wedges.

Both pools were created with `ashift=12`, `compression=lz4`, `atime=off`, and **WWN paths
from `/dev/disk/by-id`** — never `sdX`, which reshuffles across reboots and rescans.

### Chassis bay ↔ HBA bay mapping

The backplane's two SFF-8087 connectors are cabled in **swapped** order, so nothing lines up
intuitively. `bay_identifier` (from `/sys/class/sas_device/end_device-*/`) is the only
reliable physical identifier — SCSI target IDs and `sdX` names are both meaningless here and
`sdX` reshuffles whenever a drive moves.

| Chassis bay | 1   | 2   | 3   | 4   | 5   | 6   | 7   | 8   |
| ----------- | --- | --- | --- | --- | --- | --- | --- | --- |
| HBA bay     | 12  | 13  | 14  | 15  | 8   | 9   | 10  | 11  |

Read a drive's bay with:

```sh
p=$(readlink -f /sys/block/sdX/device)
cat /sys/class/sas_device/$(echo $p | grep -oE "end_device-[0-9:]+")/bay_identifier
```

**Chassis bay 1 is suspect and left empty/blanked (2026-08-04).** Two different drives in it
threw transport errors: a NetApp X422 was ejected from `vmpool` twice with `DID_SOFT_ERROR`
on large writes, and its HP replacement accrued +2,666 non-medium errors during one resilver
while the other three pool drives accrued zero. Moving that HP to chassis bay 6 dropped the
rate from ~68/min to ~0.4/min. Re-test before trusting bay 1 again.

### Migrating VM storage — mirror live, never drain

`qm move-disk <vmid> <disk> <target> --delete 1` on a **running** VM does a QEMU
drive-mirror: zero downtime, no pod eviction, no RBD detach. Always prefer this to
cordon/drain, because draining forces RWO Ceph volumes to detach and re-attach, which is
the exact operation that has wedged krbd on this hardware (see
[[project_pantheon_storage_root_cause]]).

Two constraints:

- **`efidisk0` cannot be moved live** — it is attached as pflash, not a block device, so
  QEMU can't mirror it. It needs the VM stopped. Fold this into a tuppr upgrade reboot
  rather than scheduling dedicated downtime.
- **Migrate serially, not in parallel.** The source pool is the bottleneck; concurrent
  mirrors just convert one sequential stream into N seeking against each other, and starve
  the VMs still running off it.

### Used-drive intake checklist

Failure rate on used enterprise stock is high — 2026-08-04 saw 1-of-5 600GB and 1-of-4 2TB
dead on arrival. Screen every drive **before** it enters a pool:

1. `smartctl -a` — **grown defect list** is the key number; also check the drive's own
   `SMART Health Status`, which trips a failure prediction before ZFS notices anything.
2. **Logical block size must be 512.** Array pulls (NetApp/EMC) are often formatted 520 or
   528-byte, which Linux cannot use without a low-level reformat.
3. `smartctl -t long`, then re-check grown defects — a _static_ count is fine, a growing
   one is not.
4. **Wipe stale array metadata.** Ex-Ceph drives carry LVM2 members that auto-activate and
   make `zpool attach` fail with "is in use and contains a LVM2_member filesystem". Verify
   the OSD's `ceph.cluster_fsid` tag is foreign before wiping:
   `lvs -o lv_tags | grep cluster_fsid`, then `vgchange -an <vg>; wipefs -a /dev/sdX`.

### Identifying a physical drive — no LEDs on this chassis

There is **no SES enclosure**, so there is no locate LED and no slot mapping in sysfs. SCSI
target IDs do **not** correspond to bay numbers. Two things that actually work:

- Generate real host I/O (`dd if=/dev/sdX of=/dev/null`) and watch for activity.
- Pull the drive and check which serial left the bus — safe for any drive not currently in
  a pool, and safe for any redundant member.

An extended **background** self-test generates no bus traffic and therefore lights **no**
activity LED. Do not use "which drive is idle/blinking" to identify a drive mid-test.

### `DID_SOFT_ERROR` — transport faults look like drive faults

A drive can be ejected by ZFS with dozens of write errors while its own SMART stays
pristine (defect count unchanged, zero uncorrected errors). The tell is `DID_SOFT_ERROR`
in `dmesg` on large multi-segment writes: the HBA aborted the command, so the drive never
saw it fail. That means a marginal link — drive interface, caddy, or backplane path — not
media. Distinguish by moving the drive to a different bay: errors that follow the drive
mean the drive, errors that stay mean the bay.

### Alerting

ZED posts to Alertmanager via `/etc/zfs/zed.d/statechange-alertmanager.sh` (symlinked for
`data`/`io`/`checksum`/`scrub_finish`/`resilver_finish`), reaching
`https://alertmanager.dcunha.io/api/v2/alerts` over the internal gateway. Alerts carry
`job=zed, instance=pantheon` and route to `chaski-critical`.

**Outbound mail from pantheon is broken** — do not configure anything to notify via `root`
mail, it goes nowhere. This is why a faulted drive went unnoticed before the bridge existed.

Hot spares **auto-engage** on OpenZFS 2.4.x — spare handling is built into ZED's
`zfs_retire` agent, not a shell zedlet (`spare.sh` no longer exists). Adding one is just
`zpool add vmpool spare <wwn>`.

## NFS Media Mount

- **Server**: `10.10.99.100` (TrueNAS `atlas`)
- **Path**: `/mnt/atlas/media` → mounted at `/media` in pods
- **Usable**: ~41TB (3× RAIDZ2)

## Rook-Ceph

- 3 OSDs total on M710q control plane nodes — do not add without explicit direction
- `useAllNodes: false` — never change to `useAllNodes: true`
- `pg_autoscaler` hard limit: `mon_max_pg_per_osd=250` — cannot be exceeded by adding pools
- Storage classes:
    - `ceph-block` — RWO block storage (RBD), for app config/DBs
    - `ceph-filesystem` — RWX shared filesystem (CephFS)

### `cephConfig.mgr.log_max_recent: "100"` — do not remove while on Ceph 20.2.x

Ceph 20.2.2 ([ceph#67515](https://github.com/ceph/ceph/pull/67515)) made the `rook` mgr module log
the full body of every `list_namespaced_pod` response at debug level. The `prometheus` module calls
`orch_is_available()` every 15s, which lists every pod in `rook-ceph` — on this cluster that is
~810 KB of JSON per call, ~9 calls per 5 min.

Those entries are retained in the in-memory `EntryRing` sized by `log_max_recent`. The documented
default of 500 is the _client_ default; daemons default to **10000**, so nothing is ever evicted and
the active mgr grows ~90 MB/hr until it OOMs against its 2Gi limit (observed: ~daily restarts).

Capping the ring at 100 bounds retention to ~80 MB.

**Correction (2026-08-09):** the upstream fix ([ceph#69609](https://github.com/ceph/ceph/pull/69609))
_was_ backported to tentacle as [ceph#69927](https://github.com/ceph/ceph/pull/69927), merged
2026-07-21, and its merge commit is an ancestor of the `v20.2.3` tag — so the cluster already carries
it. An earlier revision of this note said it had not been backported; that was wrong. The setting is
now redundant but harmless, and is kept as belt-and-braces (it also bounds any future log-volume
regression). `melotic/home-ops` keeps it on v20.2.3 for the same reason.

Refs: [rook#17786](https://github.com/rook/rook/issues/17786),
[tracker#77538](https://tracker.ceph.com/issues/77538), [tracker#78165](https://tracker.ceph.com/issues/78165)

The same issue also reports a thread leak in the `rook` module
([ceph#70071](https://github.com/ceph/ceph/pull/70071), still open against `main`). **It is not
active here** — measured 2026-08-09, the active mgr's thread count was flat at 168 across 12.5
minutes, and tchaikov's signature for that bug is a monotonically _growing_ `/proc/<pid>/task`
count. The 169-vs-81 reading from 2026-08-04 was steady-state, not drift.

### RESOLVED 2026-08-05: `rook-ceph-cluster` ks back to `wait: true`

cp-01 was uncordoned, `mon-a` and `osd-1` scheduled, and Ceph returned to 3/3 mons and 3/3 OSDs.
`wait: true` was restored and the stalled HelmRelease cleared with
`flux reconcile helmrelease rook-ceph-cluster -n rook-ceph --reset` — it had been Failed for 74
days on `MissingRollbackTarget` (last `deployed` release was v108, everything after it `failed`,
so Flux had no rollback target). It upgraded cleanly to v142 once the cluster was healthy.
`ceph crash archive-all` was run against a `HEALTH_WARN` for two mgr crashes — **that was a
misread and archiving is not a fix**, see the next section.

Kept for the next time a control-plane node is down:

- With cp-01 cordoned, `mon-a`/`osd-1` sit `Pending`, so the operator can never satisfy
  `ceph mon ok-to-stop` when rolling a mon. It loops on `deployment rook-ceph-mon-b cannot be
stopped ... Error EBUSY: not enough monitors would be available` every 60s and `CephCluster`
  stays `phase: Progressing` indefinitely. Under `wait: true` that pins the Kustomization at
  `Ready=False` and dependency-blocks **29** downstream Kustomizations.
- Ceph serves normally throughout (pools active, client I/O flowing) — the gate is wrong, not the
  storage. Dropping to `wait: false` is the correct temporary unblock.
- Do **not** reach for `continueUpgradeAfterChecksEvenIfNotHealthy: true`: it would let the
  operator restart `mon-b` while `mon-a` is down, dropping quorum to a single mon and taking the
  cluster offline. The operator's refusal loop is correct — leave it looping.

### RESOLVED 2026-08-09: `rook` mgr module crash loop — `node_proxy_fullreport`

**Caller identified: the `prometheus` mgr module, not the dashboard.** Ceph **v20.2.3** added
hardware metrics to `src/pybind/mgr/prometheus/module.py`; `collect()` calls `get_hardware_metrics()`
unconditionally on every scrape, which calls `node_proxy_fullreport()`. Rook's orchestrator backend
does not implement it (rook has _no_ `node_proxy` code, `master` included), so every 15s scrape threw
`NotImplementedError` from `orchestrator/_interface.py:369`. There is no config option to disable it —
the only guard is `orch_is_available()`.

**Fix: `cephClusterSpec.mgr.modules` → `- name: rook, enabled: false`.** That makes
`orch_is_available()` false so `get_hardware_metrics()` returns early. Verified in rook v1.20.3
source that the toggle sticks: `configureMgrModules` calls `MgrDisableModule` on the `else` branch,
and the force-enabling `configureOrchestratorModules` only runs under `if module.Enabled`.

This **reverses the earlier decision** recorded above ("we do not disable the rook module — it drops
the orchestrator integration the dashboard relies on"). Two things changed that calculus:

- The cost was measured, not assumed. There are **no CephNFS CRs** and no `CephNFS` references in
  `kubernetes/`; all pool/OSD management is CRD-driven. The actual loss is the `ceph orch` CLI and the
  dashboard's host/device/inventory pages. Pools, RBD, CephFS, metrics, alerts and CSI are unaffected.
- It was **not cosmetic**. Each `NotImplementedError` was recorded as a module crash; 4151 of them
  overflowed the `crash` module, which then died on its own `dictionary changed size during iteration`
  bug, putting the cluster in `HEALTH_ERR`. The crash store was also the "mgr memory leak" — the active
  mgr fell from **1702 MiB to 241 MiB** once cleared. Storage I/O was fine throughout, so the earlier
  "cosmetic" read was right about the data path and wrong about the mgr.

**Revert `enabled: false` → `true` once [ceph#70280](https://github.com/ceph/ceph/pull/70280)
("mgr/prometheus: skip hardware metrics when node-proxy is disabled") ships.** Still open as of
2026-08-09.

Cleanup, if this recurs: `ceph crash archive-all` alone is not enough. The crash **collector** replays
unposted files from `/var/lib/ceph/crash` on the node running the active mgr at ~1.5/s, so the count
climbs back even after the source is stopped — there were 16,543 unposted files here. Stop the source
first, verify with `ceph crash ls-new | tail` that no crash is newer than the fix, then delete the
backlog directories directly before a final `archive-all`.

Do not "fix" this with `mgr/crash/warn_recent_interval` (auto-archive after a day) — it hides the
storm without stopping it, and the mgr keeps paying for the crash store.

## kopiur

VolSync was fully removed 2026-08-01. All 29 apps back up via kopiur to `ClusterRepository/atlas`
(NFS `10.10.99.100:/mnt/atlas/Kopiur`). The old VolSync kopia repo remains on the NAS at
`atlas/VolsyncKopia` as a frozen historical fallback — restoring from it needs a manual kopia client.

- Referenced in `ks.yaml` components: `../../../../components/kopiur/backup`
- PVC size: set in `ks.yaml` postBuild substitute `KOPIUR_CAPACITY` — **not** in app manifests
- Each backed-up namespace also needs `../../components/kopiur/secret` in its namespace
  kustomization — the mover reads the repo password from its OWN namespace (`envFrom` is
  namespace-local), so the Secret name is fixed and cannot be per-app
- PVC in HelmRelease: `existingClaim: <app>`
- **Mover uid**: defaults to 1000. Override with `KOPIUR_PUID`/`KOPIUR_PGID` **only when the
  app's on-disk data is owned by something else** — read actual ownership, never trust the pod's
  `fsGroup` (it misleads: apoci reported 999 but data was 1000, pocket-id 65534 but data 1000).
  With `copyMethod: Snapshot` the source clone is mounted read-only, so the kubelet cannot chgrp
  it and a mismatched mover just gets permission denied. Cluster-wide only xbrowsersync needs it
  (999, mongodb sidecar).
- **`restore.yaml` must mirror the SnapshotPolicy's mover identity** or a restore writes files as
  1000 regardless of the app's uid and the app cannot open its own data.
- **A completed `Restore` is never re-reconciled.** kopiur writes `observedGeneration` once and
  never again, so if the spec is edited after creation the object sits at
  `generation != observedGeneration` forever, kstatus reports InProgress, and any `wait: true`
  Kustomization hangs the full 60m timeout — every cycle, indefinitely. This stalled `arcade/eco`
  for 24 days (its `KOPIUR_PUID/PGID` override was added after the CR existed; `xbrowsersync`
  overrides the same values but was created with them, so its generation never moved past 1).
- **The component now carries `kustomize.toolkit.fluxcd.io/ssa: ignore`** (2026-08-05, matching
  frostlink). Flux still creates the Restore but reports it `skipped` and excludes it from health
  checks, so the stale field can no longer stall anything. An earlier revision of this note said
  annotating does not help — that is wrong for this annotation specifically; it was verified live
  on `arcade/eco`, which went Ready immediately.
- **Consequence of that annotation:** Flux no longer pushes later edits to an existing Restore. If
  you change `KOPIUR_PUID`/`KOPIUR_PGID` on an app that has already been backed up, delete the
  Restore and let Flux recreate it, or the restore mover keeps the old uid (the PVC stays bound,
  no data moves).

### Mover cache budgets — `contentCacheSizeMb` / `metadataCacheSizeMb` are mandatory

Set on `ClusterRepository/atlas`. Without them the maintenance mover fills its cache PVC and every
run fails with `no space left on device` (first hit 2026-08-09; the full-maintenance job had been
failing for ~53 min).

kopia's own defaults are **5000 MB content + 5000 MB metadata**, so a 5Gi cache PVC cannot hold even
the content cache alone. Observed on the full 5Gi `kopiur-cache-atlas`: `cache/contents` 4.0G,
`logs/` 359M (`content-logs` 346M — also unbounded, and there is no kopiur knob for log retention),
`cache/metadata` 295M, `cache/index-blobs` 170M. The connect then fails writing
`repository.config`, and the surfaced error is misleading — `Cannot determine current user: user:
Current requires cgo or $USER set in environment` appears _above_ the real cause in the mover log.
Read past it to the `no space left on device` lines.

Budgets must leave headroom for logs on top of the two caches:

| Scope                                   | capacity | content | metadata | headroom |
| --------------------------------------- | -------- | ------- | -------- | -------- |
| `moverDefaults.cache` (54 per-app PVCs) | 5Gi      | 2000 MB | 1000 MB  | ~2.1Gi   |
| `maintenance.mover.cache` (1 PVC)       | 10Gi     | 3000 MB | 4000 MB  | ~3.2Gi   |

Maintenance gets its own larger override because full maintenance compacts index blobs (6733
outstanding here) and is metadata-bound. **Do not raise `moverDefaults.cache.capacity` to fix a
single mover** — it multiplies across all 54 cache PVCs. At 5Gi they already reserve 270 GiB
logical, and `ceph-block` is 3× replicated on a 715 GiB cluster. Override the one recipe instead.

The cache is regenerable, so clearing it is always safe: delete the PVC and let kopiur recreate it.

```bash
just kube snapshot               # snapshot every kopiur SnapshotPolicy now
just kube browse-pvc <ns> <pvc>  # browse a PVC interactively
just kube kopiur <state>         # suspend or resume kopiur (suspend/resume)
just kube restore <ns> <app> [offset]  # restore a PVC in place (0 = latest)
kopiur status -n <ns>            # repositories, policies, schedules
kopiur doctor -n <ns>            # diagnose an installation
```

## RBD CSI Recovery (pods stuck ContainerCreating)

Symptoms: `input/output error` on mounts, `operation already exists` in CSI logs, `MountVolume.SetUp failed`.

```bash
# Step 1 — restart CSI node plugin on the affected node
kubectl delete pod -n rook-ceph -l app=csi-rbdplugin --field-selector spec.nodeName=<node>
# wait ~30s; check if pods recover
kubectl get pods -A | grep ContainerCreating

# Step 2 — clean stale VolumeAttachments (if pods still stuck)
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>

# Step 3 — if kernel-level RBD module is broken
talosctl reboot -n <ip> --wait

# Step 4 — hard reset (last resort)
# Proxmox: qm reset <vmid>
```

## Prometheus WAL Corruption (after crash)

- **Never** delete individual WAL segments — creates sequential gaps that break Prometheus
- Scale down Prometheus → wipe entire `/prometheus/prometheus-db/wal/` → scale back up
