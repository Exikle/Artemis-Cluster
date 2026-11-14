# Reference: pantheon ZFS — home-infra

This file covers the bare-metal host storage on `pantheon`, the Proxmox box that runs the Talos worker and GPU VMs. The storage is ZFS on an LSI HBA. The file covers pools, bays, drive intake, transport faults, and ZED alerting. **None of it is Kubernetes storage**, and no manifest can reach it. For cluster storage, see `storage.md` (storage classes, NFS, PVC lifecycle) and `kopiur.md` (backups).

The two worlds touch in one place, replica placement. `pantheon` is a single machine with three hostnames. This is the failure-domain trap. Any replicated storage that spreads copies across `talos-w-01`, `talos-w-02` and `talos-gpu-01` places all of them on one physical host. A pantheon outage then takes every replica at once. This applies to miroir. The topology makes it true, not the storage layer.

## pantheon (Proxmox host) — ZFS pools

The host is an HPE ML150 Gen9 with 8 SFF bays on an LSI **SAS2116** HBA (IT mode, 16 ports). The OS SSD is on the onboard Intel C610 AHCI controller. It does **not** occupy a hot-swap bay.

| Pool       | Layout                   | Usable   | Holds                            |
| ---------- | ------------------------ | -------- | -------------------------------- |
| `vmpool`   | 2× mirror, 600GB 10K SAS | 1.09 TiB | Talos worker zvols + efidisks    |
| `bulkpool` | RAIDZ1, 3× 2TB 7.2K SATA | 3.52 TiB | vzdump backups (`recordsize=1M`) |

`hddpool` (RAIDZ1 of 3× worn ST500LM laptop drives) was destroyed on 2026-08-04. It caused recurring storage wedges in the Ceph era and is gone.

Both pools were created with `ashift=12`, `compression=lz4`, `atime=off`, and **WWN paths from `/dev/disk/by-id`**. Never use `sdX`, which reshuffles across reboots and rescans.

### Chassis bay ↔ HBA bay mapping

The two SFF-8087 connectors of the backplane are cabled in **swapped** order, so nothing lines up intuitively. `bay_identifier` (from `/sys/class/sas_device/end_device-*/`) is the only reliable physical identifier. SCSI target IDs and `sdX` names are both meaningless here, and `sdX` reshuffles whenever a drive moves.

| Chassis bay | 1   | 2   | 3   | 4   | 5   | 6   | 7   | 8   |
| ----------- | --- | --- | --- | --- | --- | --- | --- | --- |
| HBA bay     | 12  | 13  | 14  | 15  | 8   | 9   | 10  | 11  |

To read the bay of a drive, run:

```sh
p=$(readlink -f /sys/block/sdX/device)
cat /sys/class/sas_device/$(echo $p | grep -oE "end_device-[0-9:]+")/bay_identifier
```

Chassis bay 1 is suspect, and it is empty or blanked (2026-08-04). Two different drives in it threw transport errors. A NetApp X422 was ejected from `vmpool` twice with `DID_SOFT_ERROR` on large writes. Its HP replacement accrued +2,666 non-medium errors during one resilver, while the other three pool drives accrued zero. When that HP drive moved to chassis bay 6, the rate dropped from ~68/min to ~0.4/min. Test bay 1 again before you trust it.

### Migrating VM storage — mirror live, never drain

`qm move-disk <vmid> <disk> <target> --delete 1` on a **running** VM does a QEMU drive-mirror. It causes zero downtime, no pod eviction, and no volume detach. Use it instead of cordon and drain for a disk move, because draining evicts every pod on the VM for no reason that the disk needs.

Two constraints apply:

- `efidisk0` cannot be moved live. It is attached as pflash, not as a block device, so QEMU cannot mirror it. The VM must be stopped. Do this move during a tuppr upgrade reboot, not in dedicated downtime.
- Migrate serially, not in parallel. The source pool is the bottleneck. Concurrent mirrors turn one sequential stream into N streams that seek against each other, and they starve the VMs that still run off the pool.

### Used-drive intake checklist

The failure rate on used enterprise stock is high. On 2026-08-04, 1 of 5 600GB drives and 1 of 4 2TB drives were dead on arrival. Screen every drive **before** it enters a pool:

1. Run `smartctl -a`. The **grown defect list** is the key number. Also check the drive's own `SMART Health Status`, which trips a failure prediction before ZFS notices anything.
2. The logical block size must be 512. Array pulls (NetApp/EMC) are often formatted with 520-byte or 528-byte blocks, which Linux cannot use without a low-level reformat.
3. Run `smartctl -t long`, then check the grown defects again. A _static_ count is fine. A growing count is not.
4. Wipe stale array metadata. Drives that carried LVM (ex-Ceph OSDs, for one) have LVM2 members that auto-activate and make `zpool attach` fail with "is in use and contains a LVM2_member filesystem". Make sure that the tags are foreign before you wipe: `lvs -o lv_tags`, then `vgchange -an <vg>; wipefs -a /dev/sdX`.

### Identifying a physical drive — no LEDs on this chassis

This chassis has **no SES enclosure**, so it has no locate LED and no slot mapping in sysfs. SCSI target IDs do **not** correspond to bay numbers. Two methods work:

- Generate real host I/O (`dd if=/dev/sdX of=/dev/null`) and watch for activity.
- Pull the drive and check which serial left the bus. This is safe for any drive that is not in a pool, and for any redundant member.

An extended **background** self-test generates no bus traffic, so it lights **no** activity LED. Do not use "which drive is idle or blinking" to identify a drive during a test.

### `DID_SOFT_ERROR` — transport faults look like drive faults

ZFS can eject a drive with dozens of write errors while the SMART data of the drive stays pristine (defect count unchanged, zero uncorrected errors). The sign is `DID_SOFT_ERROR` in `dmesg` on large multi-segment writes. The HBA aborted the command, so the drive never saw it fail. This means a marginal link (drive interface, caddy, or backplane path), not a media fault. To tell them apart, move the drive to a different bay. If the errors follow the drive, the drive is bad. If the errors stay, the bay is bad.

### Alerting

ZED posts to Alertmanager through `/etc/zfs/zed.d/statechange-alertmanager.sh` (symlinked for `data`/`io`/`checksum`/`scrub_finish`/`resilver_finish`). The posts reach `https://alertmanager.dcunha.io/api/v2/alerts` over the internal gateway. Alerts carry `job=zed, instance=pantheon` and route to `chaski-critical`.

Outbound mail from pantheon is broken. Do not configure anything to notify through `root` mail, because it goes nowhere. This is why nobody noticed a faulted drive before the bridge existed.

Hot spares **auto-engage** on OpenZFS 2.4.x. The `zfs_retire` agent of ZED handles spares, not a shell zedlet (`spare.sh` no longer exists). To add a spare, run `zpool add vmpool spare <wwn>`.

## What is and is not backed up on this host

`vzdump` covers **only** LXC 105 (`forgejo`). It runs nightly at 02:00 to `bulkpool-backups` and keeps 7 daily, 4 weekly, and 3 monthly backups. The three Talos worker VMs (101, 102, 104) are deliberately **not** in any backup job. The team rebuilds them from `clusters/artemis/talos/` + `terraform/stacks/proxmox`, and they hold no data that miroir does not replicate or that kopiur cannot restore. If that stops being true, add them with `pvesh set /cluster/backup/forgejo-daily --vmid 101,102,104,105` (ZFS snapshot mode, no downtime).

`pve-etc-backup.timer` tars the host configuration daily to `/bulkpool/backups/host-etc/`. The tar holds `/etc`, a plain-file copy of the pmxcfs `/etc/pve` view, guest configs, the PVE root CA key, a `pvesh` resource dump, and pool and disk inventories. It keeps 30 copies and posts a failure to Alertmanager through `alertmanager-notify@.service`. This protects against the loss of the single boot SSD, which is the realistic failure.

**Off-host since 2026-10-10:** `offsite-backup.timer` (`roles/offsite_backup`) mirrors all of `/bulkpool/backups` to `atlas:/mnt/atlas/backups/pantheon` nightly at 05:30, after the 02:00 vzdump. The 30-day snapshot task of atlas on `atlas/backups` provides the history.
