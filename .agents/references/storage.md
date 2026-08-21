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

### OSD topology and drive selection — evaluation 2026-08-21 (issue #1524 §5)

**Nothing was changed. No OSD was added and the CRUSH map was not touched.** This is the written
recommendation §5 asked for, measured against the live cluster.

#### The PM961s are not the problem — the slow-counter premise does not reproduce

§5 was opened because `slow_committed_kv_count` was the one non-zero BlueStore slow counter, which
is the classic no-PLP sync-write signature. Re-measured after **18.6 h** of uninterrupted steady
state (OSDs started 04:15–04:25 UTC, read at 22:58 UTC), against a real workload — **3.1 M
`kv_sync` calls and 875 k–1.50 M client writes per OSD** — every slow counter is zero:

| counter                      | osd.0    | osd.1    | osd.2    |
| ---------------------------- | -------- | -------- | -------- |
| `slow_committed_kv_count`    | 0        | 0        | 0        |
| `slow_aio_wait_count`        | 0        | 0        | 0        |
| `slow_read_onode_meta_count` | 0        | 0        | 0        |
| `slow_read_wait_aio_count`   | 0        | 0        | 0        |
| `kv_sync_lat` mean           | 2.157 ms | 2.079 ms | 2.067 ms |
| `op_w_latency` mean          | 16.17 ms | 17.48 ms | 17.28 ms |

This is a clean result, not the inconclusive one from earlier the same day. `kv_sync_lat` at ~2.1 ms
is exactly what a no-PLP consumer drive costs (a PLP drive lands around 0.1–0.3 ms because it can
acknowledge a flush from DRAM), but it is a steady tax, not a stall. **There is no health-driven
case for replacing these drives.**

#### SMART — all three drives are healthy, and the scary number is noise

Read directly with `smartctl -a /dev/nvme0` inside each OSD container (`smartctl` and `nvme` are
both present in the rook OSD image), cross-checked against `smartctl-exporter` history in
VictoriaMetrics.

|                                   | osd.0 / talos-cp-03 | osd.1 / talos-cp-01 | osd.2 / talos-cp-02 |
| --------------------------------- | ------------------- | ------------------- | ------------------- |
| serial                            | S35ENA1J931606      | S35ENX1JA07306      | S35ENA1J931618      |
| firmware                          | 4L7QCXB7            | 4L7QCXB7            | 4L7QCXB7            |
| **Percentage Used**               | **12%**             | **13%**             | **13%**             |
| Available Spare                   | 100%                | 100%                | 100%                |
| **Media & Data Integrity Errors** | **0**               | **0**               | **0**               |
| Data Units Written                | 38.3 TB             | 42.0 TB             | 39.2 TB             |
| Power On Hours                    | 10,224              | 16,411              | 9,957               |
| Power Cycles                      | 141                 | 215                 | 324                 |
| **Unsafe Shutdowns**              | **63**              | **121**             | **136**             |
| Error Information Log Entries     | 9,576               | 10,275              | 10,224              |
| Temperature                       | 49 °C               | 50 °C               | 51 °C               |

Two things that look alarming and are not:

- **The ~10,000 error-log entries are benign.** Every entry reads `status_field: 0x2002 (Invalid
Field in Command)` with `nsid: 0`, `lba: 0` — admin-command probes for log pages the PM961 does
  not implement, i.e. monitoring asking politely and being told no. They are not media events, and
  `increase(smartctl_device_num_err_log_entries[7d])` is **1 per drive per week**. Do not read this
  counter as a fault signal on these drives.
- **The unsafe shutdowns are historical.**
  `increase(smartctl_device_power_cycle_count{device="nvme0"}[90d])` is **0 on all three** — these
  drives have not been power-cycled at all, cleanly or otherwise, in 90 days. The 63/121/136 is
  accumulated earlier life.

#### Endurance is a non-constraint — measured, not assumed

Per-drive host writes from `smartctl_device_bytes_written`, by window:

| window                           | GiB/day per drive |
| -------------------------------- | ----------------- |
| days −30 to −14 (quiet baseline) | **12.3**          |
| days −14 to −7                   | 207.8             |
| last 7 d                         | 122.6             |
| last 24 h                        | 155.7             |
| 50 d average                     | 50.2              |

The last two weeks are remediation traffic — the §9 compression rewrite, the §10 cache deletions,
the §1 PG split — not organic load. **Steady state is 12.3 GiB/day per drive (~4.5 TB/yr).** Even
taking the 50-day average of 50 GiB/day (~18 TB/yr) as a pessimistic planning figure, the _cheapest_
PLP M.2 on the market — a Kingston DC1000B 240 GB at 248 TBW — lasts **13+ years**. Endurance and
capacity are both non-binding. **The only spec that matters is power-loss protection.**

#### The real exposure is the dead UPS, not the drives

`AGENTS.md` § Known Hardware & Ops Issues records that the Eaton UPS batteries are dead. Combined
with no PLP on any OSD, that means **one mains outage is a simultaneous unclean power-off of every
copy of every object**, plus all three mons. No amount of Ceph replication helps with a correlated
event, and the drives have gone 90 days without a power cycle precisely because nothing has tested
this yet.

**Replace the UPS batteries before buying any SSD.** It is cheaper, it protects the mons, the
switch and `pantheon` as well as the OSDs, and it removes the failure mode that PLP exists to
survive. PLP on the drives is defence in depth behind it, not instead of it.

#### Where additional OSDs could physically go

| candidate       | free slot?                                  | verdict                                                   |
| --------------- | ------------------------------------------- | --------------------------------------------------------- |
| `ymir` (metal)  | **PCIe x16 slot free**, miniSAS HD free     | **Yes** — the only genuinely independent 4th host         |
| `talos-w-01/02` | VM — needs a passthrough NVMe on `pantheon` | Possible, but shares one physical machine                 |
| `talos-gpu-01`  | VM — already has 2 `hostpci` devices        | Same as above; least preferred                            |
| `pantheon`      | 3 free PCIe 3.0 slots (Slots 1, 3, 6)       | Not a k8s node itself — only as a VM's passthrough source |

**`ymir` has exactly one M.2 slot and it is occupied.** The Gigabyte C246N-WU2 carries a single M.2
2280 socket (M key, SATA _or_ PCIe x4), and the 128 GB `SPCC M.2 SSD` boot drive is in it, in SATA
mode — which is why PCH root port `0000:00:1b.0` reads `max_link_width: 4` with
`current_link_width: 0`. There is no second M.2 slot to fill. Three ways in, in order of preference:

1. **PCIe x16 slot + a passive x4-to-M.2 adapter card.** The x16 slot is empty (no device on the
   CPU PEG port) and the board bifurcates it to 2× x8. Leaves the boot drive alone. Cheapest and
   least disruptive. _Verify the case has physical clearance for a card — mini-ITX, unconfirmed._
2. **miniSAS HD (SFF-8643) → U.2.** The board's miniSAS HD connector carries a PCIe x4 U.2 lane.
   U.2 enterprise drives have PLP as standard and are cheap used, but need a 2.5" mount and power.
3. **Move boot to 2.5" SATA** (4 SATA 6 Gb/s ports free), freeing the M.2 2280 slot. Requires
   re-imaging `ymir`. Only worth it if 1 and 2 are both blocked.

**`ymir` needs RAM before it can host an OSD — this is a hard blocker, measured.** It is at
**11,572 Mi of 13,581 Mi allocatable (87%)** in memory requests. The rook OSD requests 2 Gi, which
does not fit; the pod would sit `Pending`. Talos SMBIOS reports four DIMM slots with two populated
(2× 8 GB Samsung `M378A1K43CB2-CTD`), but the C246N-WU2 is mini-ITX and its published spec is two
DIMM slots — **so the upgrade is most likely _replacing_ both 8 GB DIMMs, not adding to them.**
`AGENTS.md` says "16GB (2 slots free)"; treat that as unverified and open the case before ordering.

`pantheon` can host a passed-through NVMe: 3 free PCIe 3.0 long slots, VT-d confirmed on (DMAR
present, and the Arc A380 passthrough to `talos-gpu-01` already works), 180 GB RAM free. Pass the
whole NVMe device through with `hostpci`; **do not** back a Ceph OSD with a zvol on `vmpool` — that
is a 2-way mirror of 600 GB 10 K SAS spinners, and it stacks ZFS CoW under BlueStore CoW.

#### 3 OSDs / 3 hosts vs 4 vs 5 — the redundancy win lands at 4, not 5

The failure domain is `host` and both CRUSH rules are `chooseleaf_firstn 0 type host`, so with three
hosts and `size=3` there is exactly one legal mapping for every PG. That is the whole problem:

- One OSD down → **65 of 65 PGs go `undersized+degraded` and stay there.** CRUSH has nowhere to put
  the third copy. `min_size=2` keeps I/O alive, with zero further tolerance.
- An OSD rebuild backfills all **~78 GiB** onto the new drive from the two survivors, and the entire
  window runs at 2 copies.

**At 4 hosts this inverts.** `ceph osd out` the drive you are about to replace, let CRUSH
re-replicate onto the other three hosts, and the cluster is back to a full 3 copies _before_ you
pull anything. The rebuild then runs at full redundancy. That is the property §5 was after, and it
arrives at the 4th host.

|                                    | 3 OSDs / 3 hosts (now)          | 4 / 4 (+ `ymir`)     | 5 / 5 (+ one `pantheon` VM) |
| ---------------------------------- | ------------------------------- | -------------------- | --------------------------- |
| PG replicas (64 + 1 pools, size 3) | 195                             | 195                  | 195                         |
| **PGs per OSD**                    | **65**                          | **~49**              | **~39**                     |
| raw capacity                       | 715 GiB                         | 954 GiB              | 1,192 GiB                   |
| usable at size=3                   | 238 GiB                         | 318 GiB              | 397 GiB                     |
| headroom to `nearfull` (0.85)      | 373 GiB                         | 576 GiB              | 778 GiB                     |
| runway at §8's +3.10 GiB raw/day   | ~120 d                          | ~186 d               | ~251 d                      |
| **maintenance at full redundancy** | **impossible**                  | **yes**              | yes                         |
| one host down                      | 65/65 PGs degraded, no recovery | recovers to 3 copies | recovers to 3 copies        |
| two hosts down                     | 100% of PGs below `min_size`    | 100%                 | **~30%** (3/10 of PGs)      |
| data moved to add the OSD          | —                               | ~58 GiB              | ~46 GiB                     |

The two-hosts-down row is the only thing the 5th OSD buys that the 4th does not: with five hosts a
given PG occupies 3 of 5, so two specific hosts both being in its acting set has probability
`C(3,2)/C(5,2) = 3/10`. Everything else at 5 is incremental — more capacity, smaller per-OSD
backfill, more parallel recovery sources.

**PG budget is fine at both, and `pg_num` does not need to move.** The autoscaler's ideal is
`ratio × 100 × num_osds / size`; adding OSDs raises `num_osds` and lowers `ratio` by almost exactly
the same factor, so ideal stays at **~32** at 3, 4 and 5 OSDs. The live `pg_num` of 64 is 2× ideal,
and the autoscaler only acts on a ≥3× divergence — so **64 holds, `would_adjust` stays false, and
nothing needs re-planning.** Per-OSD PG count falls 65 → 49 → 39, all comfortably between
`mon_pg_warn_min_per_osd` (30) and `mon_max_pg_per_osd` (250, back at its default since §1).
**At 7 OSDs, 195/7 = 27.9 crosses under the min warning** — that is the point where `pg_num` would
have to go to 128.

#### The failure-domain trap: `pantheon` is one machine wearing three hostnames

`talos-w-01`, `talos-w-02` and `talos-gpu-01` are all VMs on `pantheon`, and their disks are all on
the same `vmpool`. CRUSH sees three independent `host` buckets and will cheerfully place 2 of 3
copies of a PG on two of them.

**Never put OSDs on more than one `pantheon` VM while `failureDomain: host`.** One is fine — a
`pantheon` reboot then costs exactly one OSD, the same as any other host. Two is a hidden
correlated pair that defeats `size=3`. If a second is ever wanted, add a CRUSH bucket above `host`
(`chassis`) grouping the `pantheon` VMs and move the pool's failure domain up to it first.

This also caps the design: counting `pantheon` as one machine, **the cluster has at most 5
independent failure domains** — `talos-cp-01/02/03`, `ymir`, and `pantheon`. There is no 6th.

#### Rook config changes an OSD addition would require — design only, not applied

- `storage.nodes` gains the new node.
- **`devicePathFilter: ^/dev/disk/by-id/nvme-SAMSUNG_MZVLW256HEHP.*` is model-locked.** A
  differently-modelled PLP drive will not be picked up. Prefer replacing the global filter with
  per-node `devices:` entries — that also removes the risk of a filter accidentally matching a boot
  device on a new node.
- `mon`/`mgr` `placement` is pinned to `talos-cp-01/02/03` and `count: 3` — **no change needed.**
  Adding an OSD host does not add a mon.
- `cephBlockPools[0].spec.failureDomain` stays `host` (see the `pantheon` trap above).
- The `osd-rebuild` skill is the mechanism for the drive swaps.

#### Replacement drive spec and pricing

Requirement, from the measurements above: **power-loss protection, M.2 2280, ≥240 GB.** Nothing
else binds — endurance is over-served by an order of magnitude at every capacity on the market, and
256 GB matches the current per-OSD footprint (78 GiB used of 238 GiB).

Verified quotes, 2026-08-21 — **Canadian retail for PLP M.2 2280 is effectively unavailable**:

| part                       | PLP | endurance         | quote            | source                                                |
| -------------------------- | --- | ----------------- | ---------------- | ----------------------------------------------------- |
| Kingston DC1000B 240 GB    | yes | 0.5 DWPD, 248 TBW | **out of stock** | Newegg.ca and Newegg.com both                         |
| Kingston DC1000B 480 GB    | yes | 475 TBW           | **out of stock** | Newegg.com                                            |
| Kingston DC2000B 480 GB    | yes | 0.4 DWPD          | CAD $799.99      | Canada Computers — _custom order, not a street price_ |
| Micron 7450 PRO 480 GB M.2 | yes | 1 DWPD, 800 TBW   | USD $144.17      | CompSource                                            |
| Micron 7450 PRO 480 GB M.2 | yes | 1 DWPD, 800 TBW   | USD $589.95      | MITXPC — reseller outlier, ignore                     |
| Micron 7450 PRO 480 GB M.2 | yes | 1 DWPD, 800 TBW   | out of stock     | Newegg.ca                                             |

The only sane verified number is the **Micron 7450 PRO 480 GB at USD $144.17**. At 1.3764 USD→CAD
(2026-08-21) plus ~15% shipping and duty on a US order, that lands at **~CAD $230/drive**.

Planning figures below. The used-market and RAM rows are **estimates, not quotes** — nothing was
priced live on eBay:

| line item                           | new (CAD) | used/pull (CAD, estimate) |
| ----------------------------------- | --------- | ------------------------- |
| PLP M.2 2280, per drive             | ~$230     | ~$80–145                  |
| Passive PCIe x4→M.2 adapter, each   | ~$25      | —                         |
| `ymir` RAM, 2× 16 GB DDR4 ECC UDIMM | ~$140     | ~$70                      |

| option                                           | drives | adapters | total (CAD, new)               |
| ------------------------------------------------ | ------ | -------- | ------------------------------ |
| **A** — replace the 3 PM961s only, stay at 3/3   | 3      | 0        | **~$690**                      |
| **B** — 4 OSDs / 4 hosts (3 replaced + `ymir`)   | 4      | 1        | **~$1,085** (incl. `ymir` RAM) |
| **C** — 5 OSDs / 5 hosts (B + one `pantheon` VM) | 5      | 2        | **~$1,340**                    |

#### Recommendation

**Option B, in this order.** The sequencing is the point: doing the topology work _first_ is what
makes the drive swaps safe.

1. **Replace the Eaton UPS batteries.** Highest value per dollar in this whole evaluation, and it
   addresses the correlated failure that PLP is a partial hedge against.
2. **RAM in `ymir`.** Hard prerequisite — an OSD cannot schedule there today. Open the case and
   confirm the DIMM slot count before ordering.
3. **One PLP M.2 + a PCIe adapter into `ymir` → 4th OSD.** This is the packet that removes "CRUSH
   can never re-replicate", and it is the smallest change that does so.
4. **Then** swap the three PM961s for PLP drives one at a time via the `osd-rebuild` skill — which
   now runs at full redundancy, because there are four hosts. There is no urgency: the drives are at
   12–13% wear with zero media errors and clean slow counters, so this is opportunistic, not
   scheduled.
5. **A 5th OSD on one `pantheon` VM only if capacity demands it.** At §8's +3.10 GiB raw/day, four
   OSDs give ~186 days of runway; revisit when that shortens.

Do **not** do Option A. Replacing three healthy drives while still unable to re-replicate spends
the money and keeps the structural problem.

### Ceph version selection — no `cephImage` pin (2026-08-20)

**The `rook-ceph-cluster` chart's default `cephImage.tag` selects the Ceph version. Do not
re-add a repo-side pin.** This reverses the earlier "always pin `cephImage.tag`" convention.

Rook moves its chart default in lockstep with the CephX defaults each release needs, so the
chart is internally consistent and pinning desynchronizes it:

| chart   | default `cephImage.tag` | `security.cephx.csi.keyType` | `mgr.modules[rook]`  |
| ------- | ----------------------- | ---------------------------- | -------------------- |
| v1.20.4 | v20.2.2                 | _(absent)_                   | commented out        |
| v1.20.5 | **v20.2.4**             | `aes`                        | commented out        |
| v1.20.6 | **v20.2.4**             | `aes`                        | **`enabled: false`** |

Our pin is what left the cluster on v20.2.3 after the v1.20.5 chart landed — i.e. it held us
on a CVE-vulnerable Ceph rather than protecting us from anything. Removing it also retired the
`quay.io/ceph/ceph` `allowedVersions` guard in `.renovaterc.json5`: rook will never default to
a Ceph its own operator refuses, which is what that regex approximated.

The trade is that the chart version now moves Ceph, and a chart _patch_ is enough to cross a
security boundary (v1.20.4 ➔ v1.20.5 moved v20.2.2 ➔ v20.2.4). The `rook-ceph` Renovate group
is therefore `automerge: false`. **Re-pin only as a temporary hold** if a specific Ceph release
must be avoided, and remove the pin again once it is.

### CephX AES256K / CVE-2025-30156 (resolved 2026-08-20)

Ceph v20.2.4 (and v19.2.6) introduce the `aes256k` CephX key type. The old AES service tickets
have no effective integrity check, so an attacker holding any CephX key could bit-flip their way
to cluster admin in linear time. Resolution needs rook ≥ v1.20.6 **and** Ceph ≥ v20.2.4 **and** a
daemon key rotation — the version bump alone does nothing.

Applied here as `spec.security.cephx` in the cluster HelmRelease:

- `daemon.keyRotationPolicy: KeyGeneration` + `keyGeneration: 2` — one-shot rotation of mon, mgr,
  osd, mds, admin, exporter and crash keys to `aes256k`. Bump `keyGeneration` again to re-rotate.
- `csi.keyType: aes` — **load-bearing.** AES256K CSI keys require **Linux kernel 7.0+** and every
  node runs 6.18. Rook autodetects key type otherwise, and an autodetected `aes256k` CSI key makes
  new PVC kernel mounts fail. `rbdMirrorPeer` stays `aes` for the same reason.

End state (`ceph auth dump-keys --format=json`): 11 keys `aes256k`, 5 `aes` (4× `client.csi-*`
plus `client.rbd-mirror-peer`). That split is correct and is not a partial migration.

`healthCheck.muteHealthWarning` mutes the four `AUTH_INSECURE_*` **warnings**, which persist by
design while non-core clients stay on AES. The two `AUTH_INSECURE_SERVICE_*` **errors** are not
muted and must be resolved by rotation, not suppressed.

The rolling upgrade takes ~15 min for 3 OSDs and does two passes — version first, then rotation.
PVCs stay mounted throughout. Restart `rook-ceph-tools` afterwards for its admin keyring; a
transient `[errno 13] RADOS permission denied` right at toolbox start is expected and clears.

**This is complete, not half-done.** `ceph config get mon auth_service_cipher` returns `aes256k`,
which is the setting that actually closes the CVE — every service ticket is now AES256K, so no
CephX key can be escalated, including the CSI keys still on `aes`. Rook's guidance is explicit
that older kernels keep using AES authentication keys safely once Ceph issues AES256K service
tickets. The remaining work below is optional hardening that clears two muted cosmetic warnings.

**Kernel 7.0 is not coming soon — do not plan around it.** Talos tracks the _LTS_ kernel and
6.18 is the current longterm (Talos `main`, `release-1.14` and `release-1.13` are all on 6.18.4x
as of 2026-08-20). Linux 7.0/7.1/7.2 exist only as mainline/stable. The Ceph client's aes256k
support arrived via the `ceph-for-7.0-rc1` merge — a feature merge, not a stable backport — so
6.18 LTS will never gain it. Unblocking needs the next LTS designation (conventionally the last
release of a calendar year) plus Talos adopting it.

**Parked — do not attempt without a kernel 7.0+ fleet:** migrating CSI keys to `aes256k` (needs
`keepPriorKeyCountMax: 1` and a cordon/drain/reboot pass per node), and `security.cephx.allowedCiphers:
[aes256k]`. The latter can lock rook out of the cluster entirely with the same `[errno 13] RADOS
permission denied`, requiring an emergency `daemon.keyType: aes` + both-ciphers patch to recover.

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

**Superseded 2026-08-20 — keep `enabled: false` permanently; do not revert.** Rook made this the
chart default in v1.20.6 ("mgr: Disable the rook mgr module", rook#18213), with the values comment
"The rook mgr module is not recommended. The only impact is that some small features will be
disabled in the Ceph dashboard." So this is upstream policy now, not a local workaround.
[ceph#70280](https://github.com/ceph/ceph/pull/70280) is still open regardless (checked 2026-08-20).

Note `mgr.modules` is a **list**, and Helm replaces lists rather than merging them — our explicit
`- name: rook / enabled: false` entry must stay in the values even though it matches the default,
or the rest of our list (`diskprediction_local`, `insights`, `pg_autoscaler`) would drop it.

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

### The kopia web UI is deliberately removed (2026-08-09)

`ClusterRepository/atlas` no longer sets `spec.server`, and the standalone `httproute.yaml` for
`kopiur.dcunha.io` is deleted. **Do not re-add it as a "missing" route** — the operator creates the
Service from `spec.server`, so the route exists only when the UI does.

Removed at the user's request; it was barely used and its pod had been restarting (25× in 12h,
all clean `exit=0`). Note the security property that made it worth removing cheaply: the server
pod holds the repository **decryption key** even in `readOnly: true` mode, which is why its
Service was ClusterIP and internal-gateway-only in the first place.

Repository inspection without the UI: `kopiur status -n <ns>` and `kopiur doctor -n <ns>`.

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
