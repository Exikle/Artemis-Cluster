# Reference: Hardware — Artemis-Cluster

The physical inventory and the traps that come with it. Read before sizing a workload, pinning it
to a node, buying a part, or explaining a latency symptom that manifests as software.

Node names and roles are live facts — `kubectl get nodes -o wide` and `talosctl get members` are
the ground truth. What is written here is what those commands cannot tell you: which part is in
which box, and which one has bitten us.

## Control Planes (metal)

**3× Lenovo M710q** — `talos-cp-01/02/03`. 256GB NVMe (Samsung MZVLW256HEHP) for cluster storage,
VLAN 1099 (LAB). IPs come from DHCP reservations on the UCG, not static config.

**The three boot SSDs are not the same, and it matters.** cp-02/03 are 860 EVO 500GB (TLC);
**cp-01 is a Dell/Intel D3-S4610 240GB** (`SSDSC2KG240G8R`, 3D TLC with power-loss protection),
swapped in on 2026-09-19.

It replaced an **860 QVO 1TB (QLC)**, whose worst case was exactly etcd's access pattern —
sustained small sync writes. `sda` average device write latency measured **61.3ms on cp-01
against 1.9ms on cp-02/03**, making cp-01's apiserver roughly 7× slower on pod reads, and that
drove the cluster-wide Multus sandbox failures in #1956 / #2088. The QVO was not failing — no
ATA errors, 8% full, stable for months. It was the wrong class of drive for etcd, and tuning
around it was never going to work.

The S4610's power-loss-protection capacitors are what actually fix it: an fsync is acknowledged
out of the drive's DRAM instead of waiting on NAND. Post-swap latency settled to ~3ms within
half an hour of the rebuild, against 1.3ms on cp-02 — still draining the image-pull storm at
that point, so treat 3ms as a ceiling, not the steady state.

**cp-01 now has the least headroom in the fleet**: 240GB against cp-02/03's 500GB, roughly 62%
full at current image load where cp-02 sits at 24%. Kubelet image GC (85% threshold) keeps it in
hand, and images are the bulk of it, so there is nothing to do — but it is the node to check
first if a disk-pressure eviction ever shows up.

Full model strings come from the `by-id` symlink (`talosctl get disk sda -o yaml`). The `model:`
field truncates at 16 bytes to `Samsung SSD 860` and hides the EVO/QVO distinction entirely —
this is why the mismatch went unnoticed for months.

## Workers (Proxmox VMs on `pantheon`)

- `talos-w-01`, `talos-w-02` — 32GB RAM, 6 vCPU (NUMA-pinned), 128GB disk
- `talos-gpu-01` — 32GB RAM, 6 vCPU, ASRock Arc A380 passthrough (6GB)

## Workers (metal)

**ymir** — Gigabyte C246N-WU2 | Xeon E-2124G (4C/4T) | 16GB, 2 slots free | 128GB SATA M.2.

- **1U chassis.** A discrete card needs a riser and must lie flat; check cooling clearance and
  8-pin PCIe availability before ordering one.
- UHD Graphics P630 iGPU — HEVC 10-bit and VP9 decode, a better transcoder than the M710q HD 530s.
- `eno1` (`d8:5e:d3:00:ea:81`) is the cabled NIC; `enp3s0` (`…:82`) is unused.
- BIOS F1 — leave the defaults. `Initial Display Output → IGFX` and `CSM → Disabled` each kill
  video output on their own.

## Proxmox host (`pantheon`)

HPE ML150 G9 | 2× Xeon E5-2620 v3 (24 cores total).

**The HP RAID card must be in HBA mode** (via `ssacli`, or F9 at boot) or Proxmox never sees the
raw disks. Pool layout and drive-bay mapping: `pantheon-zfs.md`. Host NIC and bridge shape:
`pantheon-networking.md`.

## Storage

- **TrueNAS** (`atlas`, 10.10.99.100) — ~41TB usable across 3× RAIDZ2, NFS at `/mnt/atlas/media`.
- **miroir** (`miroir-system`) — replicated block storage on the M710q NVMe. StorageClasses
  `miroir` (default, 2 replicas) and `miroir-local`. App config and databases only, never media.

**Rook-Ceph was removed in `b9008ac55`.** There is no `ceph-block`, no CephFS, and no CephCluster
CRD. A manifest or doc that names one is stale.

Everything else about volumes — the NFS media mount, orphaned PVCs, the Prometheus WAL sizing:
`storage.md`.

## Known hardware and ops issues

**Eaton UPS** — batteries are dead. It is not providing real protection; treat the cluster as
having no power backup.

**TrueNAS netdata metrics** — automated since 2026-08-22, no longer a manual chore. A TrueNAS
update replaces `/etc/netdata`, which silently stops metrics reaching `truenas-exporter` in the
cluster. `ansible/roles/netdata_exporter` keeps the canonical config on a dataset
(`/mnt/atlas/config/netdata/`) and registers a POSTINIT init script so the box repairs itself at
boot. Re-run `just ansible apply atlas` if it ever drifts.

> The instruction here used to say to re-fetch `netdata.conf` from the
> `truenas-graphite-to-prometheus` repo. That named the wrong file. The exporting config lives in
> **`/etc/netdata/exporting.conf`** — a `[graphite:prometheus]` block pointing at
> `10.10.99.93:9109`. `netdata.conf` itself is stock and does not need touching.
