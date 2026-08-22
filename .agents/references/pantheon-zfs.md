# Reference: pantheon ZFS — Artemis-Cluster

Bare-metal host storage on `pantheon`, the Proxmox box that runs the Talos worker and GPU VMs.
This is ZFS on an LSI HBA — pools, bays, drive intake, transport faults, and ZED alerting. **None
of it is Kubernetes storage**, and nothing here is reachable from a manifest. For cluster storage
see `storage.md` (storage classes, NFS, PVC lifecycle), `rook-ceph.md` (OSDs, CephX, RBD CSI), and
`kopiur.md` (backups). The one place the two worlds touch is OSD placement: `pantheon` is a single
machine wearing three hostnames, which `rook-ceph.md` § failure-domain trap covers.

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
