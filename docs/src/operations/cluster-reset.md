# Cluster Reset

Full procedure to destroy and rebuild the cluster. See [Talos → Node Reset](../talos/reset.md) for single-node reset.

---

## Before You Start

- Ensure any critical PVC data has been backed up (VolSync or manual snapshot)
- This is **irreversible** — all data on node disks is permanently deleted

---

## Phase 1: Reset All Nodes

```bash
# Control planes
talosctl -n 10.10.99.101 reset --graceful=false --reboot
talosctl -n 10.10.99.102 reset --graceful=false --reboot
talosctl -n 10.10.99.103 reset --graceful=false --reboot

# Workers
talosctl -n 10.10.99.201 reset --graceful=false --reboot
talosctl -n 10.10.99.202 reset --graceful=false --reboot
talosctl -n 10.10.99.203 reset --graceful=false --reboot
```

Nodes reboot after wiping. Because the OS disk is wiped, they cannot boot from disk.

---

## Phase 2: Boot from Talos ISO

Each node needs to boot into Talos maintenance mode from an ISO.

### Download ISOs

```bash
just talos download-image v1.12.6 controlplane
just talos download-image v1.12.6 worker
just talos download-image v1.12.6 gpu
```

### Physical nodes (talos-cp-01/02/03)

1. Flash ISO to USB (`dd if=talos-v1.12.6-controlplane.iso of=/dev/sdX bs=4M status=progress`)
2. Insert USB and boot each node — select USB from boot menu (F10/F12)

### Proxmox VMs (talos-w-01/02, talos-gpu-01)

1. Upload the worker/gpu ISO to Proxmox storage
2. Attach ISO to each VM's CD drive: `qm set <vmid> -ide2 local:iso/talos-v1.12.6-worker.iso,media=cdrom`
3. Set boot order to CD first: `qm set <vmid> -boot order=ide2;scsi0`
4. Start VMs: `qm start 101; qm start 102; qm start 104`

---

## Phase 3: Re-Bootstrap

Once all nodes are in maintenance mode:

```bash
# Verify nodes are reachable
ping 10.10.99.101
ping 10.10.99.201

# Run full bootstrap
just
```

See [Bootstrap](../talos/bootstrap.md) for stage details.

---

## Phase 4: Restore PVC Data

After Flux has reconciled all apps, restore PVC data from VolSync backups:

See [VolSync Backup & Restore](volsync.md).

---

## Post-Reset Checklist

```bash
# Nodes ready
kubectl get nodes -o wide

# Flux reconciling
flux get kustomizations -A

# Rook-Ceph healthy
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status

# BGP peers established
kubectl -n kube-system exec ds/cilium -- cilium bgp peers

# Check all pods
kubectl get pods -A | grep -v Running | grep -v Completed
```
