# Nodes

## Control Planes

Three bare-metal **Lenovo M710q** mini PCs running Talos Linux as Kubernetes control plane nodes. Workloads are permitted to schedule on control planes (`allowSchedulingOnControlPlanes: true`).

| Hostname    | IP           | Boot Disk                      | Ceph OSD        |
| ----------- | ------------ | ------------------------------ | --------------- |
| talos-cp-01 | 10.10.99.101 | 256 GB NVMe (Samsung MZVLW256) | 256 GB SATA SSD |
| talos-cp-02 | 10.10.99.102 | 256 GB NVMe (Samsung MZVLW256) | 256 GB SATA SSD |
| talos-cp-03 | 10.10.99.103 | 256 GB NVMe (Samsung MZVLW256) | 256 GB SATA SSD |

- **RAM:** 16 GB each
- **Network:** Physical NIC (MAC prefix `6c:4b:90`), bonded as `bond0`, VLAN 1099 (LAB) tagged as `bond0.1099`
- **Secure Boot:** Enabled
- **Talos schematic extensions:** `i915`, `intel-ucode`, `mei`, `nfsrahead`, `util-linux-tools`

---

## Workers

Three Talos Linux VMs on Proxmox host `pantheon` (HPE ML150 G9).

| Hostname     | IP           | VM ID | Disk                     | GPU                                |
| ------------ | ------------ | ----- | ------------------------ | ---------------------------------- |
| talos-w-01   | 10.10.99.201 | 101   | `/dev/sda` (virtualized) | —                                  |
| talos-w-02   | 10.10.99.202 | 102   | `/dev/sda` (virtualized) | —                                  |
| talos-gpu-01 | 10.10.99.203 | 104   | `/dev/sda` (virtualized) | ASRock Arc A380 6 GB (passthrough) |

- **RAM:** 32 GB each
- **vCPUs:** 6 (sockets=1, cores=6, NUMA enabled)
- **Network:** QEMU NIC (MAC prefix `bc:24:11`), bonded as `bond0`, VLAN 1099 LAB (`bond0.1099`) + VLAN 1152 IOT (`bond0.1152`)
- **Secure Boot:** Enabled (UKI cmdline via `grubUseUKICmdline: true`)
- **Talos schematic extensions:** `i915`, `intel-ucode`, `mei`, `nfsrahead`, `qemu-guest-agent`, `util-linux-tools`
- **GPU schematic adds:** `intel_iommu=on`, `iommu=pt`, `i915.enable_guc=3`, `pcie_aspm=off`

### GPU Worker Notes

- **Small BAR detected** — HPE ML150 G9 does not support Resizable BAR (ReBAR). This is not fixable at the firmware level. VAAPI transcoding is unaffected.
- **xpu-smi / Level Zero error `zeInit: 78000001`** — Level Zero compute API is unavailable inside VMs (expected). VAAPI/DRM still works correctly.
- **`model: Unknown`, `memory: "0"` in ResourceSlice** — cosmetic result of xpu-smi failure above; no functional impact.

---

## Proxmox Host (`pantheon`)

The virtualization host for all three worker VMs.

| Field     | Value                                      |
| --------- | ------------------------------------------ |
| Hostname  | pantheon                                   |
| IP        | 10.10.99.104                               |
| Hardware  | HPE ML150 G9                               |
| CPU       | 2× Intel Xeon E5-2620 v3 (12 c/24 t total) |
| RAM       | 192 GB                                     |
| OS        | Proxmox VE (Debian Trixie)                 |
| Boot disk | T-FORCE 1 TB SSD                           |

SSH access: `root@10.10.99.104`

Worker VMs are managed via the Proxmox web UI or CLI (`qm`). The Arc A380 GPU is passed through to `talos-gpu-01` (VM 104) via VFIO.

### VM Management Quick Reference

```bash
# List VMs
qm list

# Start/stop a VM
qm start 104
qm stop 104

# Hard reset (use when talosctl reboot hangs)
qm reset 104

# Console access
qm terminal 101
```
