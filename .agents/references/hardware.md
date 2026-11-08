# Reference: Hardware — Artemis-Cluster

This file is the physical inventory and the traps that come with it. Read it before you size a workload, pin it
to a node, buy a part, or explain a latency symptom that appears to come from software.

Node names and roles are live facts. `kubectl get nodes -o wide` and `talosctl get members` are
the ground truth. This file records what those commands cannot tell you: which part is in
which box, and which part caused problems.

## Control Planes (metal)

**3× Lenovo M710q**: `talos-cp-01/02/03`. Each has a 256GB NVMe (Samsung MZVLW256HEHP) for cluster storage
and sits on VLAN 1099 (LAB). IPs come from DHCP reservations on the UCG, not from static config.

The three boot SSDs are not the same, and it matters. cp-02/03 have an 860 EVO 500GB (TLC).
cp-01 has a Dell/Intel D3-S4610 240GB (`SSDSC2KG240G8R`, 3D TLC with power-loss protection),
swapped in on 2026-09-19.

It replaced an **860 QVO 1TB (QLC)**. The worst case for that drive was exactly the access pattern of etcd:
sustained small sync writes. `sda` average device write latency measured **61.3ms on cp-01
against 1.9ms on cp-02/03**. That made the apiserver of cp-01 roughly 7× slower on pod reads, and it
drove the cluster-wide Multus sandbox failures in #1956 / #2088. The QVO was not failing. It had no
ATA errors, was 8% full, and had been stable for months. It was the wrong class of drive for etcd, and tuning
around it was never going to work.

The power-loss-protection capacitors of the S4610 are what actually fix the problem. The drive acknowledges an fsync
out of its DRAM and does not wait on NAND. After the swap, latency settled to ~3ms within
half an hour of the rebuild, against 1.3ms on cp-02. cp-01 was still draining the image-pull storm at
that point, so treat 3ms as a ceiling, not the steady state.

cp-01 has the least headroom in the fleet: 240GB against 500GB on cp-02/03. Kubelet image GC
(85% threshold) keeps it in hand, and images are the bulk of the usage, so nothing needs doing. But
it is the node to check first if a disk-pressure eviction ever shows up.
Full model strings come from the `by-id` symlink (`talosctl get disk sda -o yaml`). The `model:`
field truncates at 16 bytes to `Samsung SSD 860` and hides the EVO/QVO distinction entirely.
This is why nobody noticed the mismatch for months.

## Workers (Proxmox VMs on `pantheon`)

- `talos-w-01`, `talos-w-02`: 32GB RAM, 6 vCPU (NUMA-pinned), 128GB disk
- `talos-gpu-01`: 32GB RAM, 6 vCPU, ASRock Arc A380 passthrough (6GB)

## Workers (metal)

**ymir**: Gigabyte C246N-WU2 | Xeon E-2124G (4C/4T) | 16GB, 2 slots free | 128GB SATA M.2.

- It has a 1U chassis. A discrete card needs a riser and must lie flat. Before you order one, check the cooling clearance and
  the availability of 8-pin PCIe.
- The UHD Graphics P630 iGPU handles HEVC 10-bit and VP9 decode. It is a better transcoder than the M710q HD 530s.
- `eno1` (`d8:5e:d3:00:ea:81`) is the cabled NIC. `enp3s0` (`…:82`) is unused.
- BIOS F1: leave the defaults. `Initial Display Output → IGFX` and `CSM → Disabled` each kill
  video output on their own.

## Proxmox host (`pantheon`)

HPE ML150 G9 | 2× Xeon E5-2620 v3 (24 cores total).

The drives sit on an LSI SAS2116 HBA in IT mode, not on a Smart Array card. So there is no
`ssacli` and no RAID mode to flip. For the pool layout and the drive-bay mapping, see `pantheon-zfs.md`. For the host NIC and bridge shape, see
`pantheon-networking.md`.

## Storage

- **TrueNAS** (`atlas`, 10.10.99.100): 3× RAIDZ2 (run `zpool list` on the box for capacity), NFS at `/mnt/atlas/media`.
- **miroir** (`miroir-system`): replicated block storage on the M710q NVMe. StorageClasses
  `miroir` (default, 2 replicas) and `miroir-local`. App config and databases only, never media.

Rook-Ceph is gone. `AGENTS.md` § What was deliberately removed is the home for that, and it wins.

For everything else about volumes (the NFS media mount, orphaned PVCs, the Prometheus WAL sizing), see
`storage.md`.

## Known hardware and ops issues

**Eaton UPS**: the batteries are dead. It does not provide real protection. Treat the cluster as
having no power backup.

**TrueNAS netdata metrics**: automated since 2026-08-22, no longer a manual chore. A TrueNAS
update replaces `/etc/netdata`. That silently stops the `[web]` bind that VMStaticScrape
`netdata-atlas` scrapes on `10.10.99.100:19999`. `ansible/roles/netdata_exporter` keeps the
canonical config on a dataset (`/mnt/atlas/config/netdata/`) and registers a POSTINIT init script
so the box repairs itself at boot. If it ever drifts, run `just ansible apply atlas` again. The team retired the
graphite bridge (`truenas-exporter`). `ansible.md` § The netdata.conf chore has the
current path and the reason that `exporting.conf` belongs to TrueNAS middleware.
