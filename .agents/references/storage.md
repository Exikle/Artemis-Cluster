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

Capping the ring at 100 bounds retention to ~80 MB. Upstream fix
([ceph#69609](https://github.com/ceph/ceph/pull/69609)) landed in v21.3.0 and has **not** been
backported to 20.2.x — drop this setting once the cluster is on a Ceph release that carries it.

Refs: [rook#17786](https://github.com/rook/rook/issues/17786),
[tracker#77538](https://tracker.ceph.com/issues/77538), [tracker#78165](https://tracker.ceph.com/issues/78165)

A second, smaller leak in the same issue is a thread leak in the `rook` module
([ceph#70071](https://github.com/ceph/ceph/pull/70071)) — visible as the active mgr's thread count
drifting up (169 vs 81 on standby, 2026-08-04). Others worked around it with
`ceph mgr module disable rook`, which we do **not** do: that drops the orchestrator integration the
dashboard relies on. The log cap alone keeps memory inside the limit.

### RESOLVED 2026-08-05: `rook-ceph-cluster` ks back to `wait: true`

cp-01 was uncordoned, `mon-a` and `osd-1` scheduled, and Ceph returned to 3/3 mons and 3/3 OSDs.
`wait: true` was restored and the stalled HelmRelease cleared with
`flux reconcile helmrelease rook-ceph-cluster -n rook-ceph --reset` — it had been Failed for 74
days on `MissingRollbackTarget` (last `deployed` release was v108, everything after it `failed`,
so Flux had no rollback target). It upgraded cleanly to v142 once the cluster was healthy.
`ceph crash archive-all` cleared a `HEALTH_WARN` for two mgr crashes dated 2026-08-03, i.e. from
before the repair; health is `HEALTH_OK`.

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
