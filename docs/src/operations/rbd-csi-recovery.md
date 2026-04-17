# RBD CSI Recovery

When worker VMs experience storage I/O errors, the RBD kernel driver can enter a broken state causing cascading pod failures across the node.

---

## Symptoms

- Pods stuck in `ContainerCreating` with `input/output error` on mounts
- CSI node plugin logs: `operation already exists` or `Cannot send after transport endpoint shutdown`
- `MountVolume.SetUp failed` with `lstat ... input/output error`
- VolSync jobs stuck in `Init:0/1`
- `rbd: map failed: (108) Cannot send after transport endpoint shutdown`

---

## Recovery (in order)

### Step 1: Restart the RBD CSI node plugin on the affected node

```bash
# Find the CSI node plugin pod on the affected node
kubectl get pods -n rook-ceph -l app=csi-rbdplugin --field-selector spec.nodeName=talos-w-01

# Delete it (it will restart automatically)
kubectl delete pod -n rook-ceph <csi-nodeplugin-pod>
```

If the pod restarts and errors clear, you're done.

### Step 2: If CSI restart doesn't help — reboot the worker node

The kernel RBD module may have lost network transport. A reboot is required:

```bash
just talos reboot-node talos-w-01
```

If the node hangs during reboot (kernel stalls on RBD unmount):

```bash
# Hard reset via Proxmox
qm reset 101   # talos-w-01
qm reset 102   # talos-w-02
qm reset 104   # talos-gpu-01
```

### Step 3: After reboot — clean up stale resources

```bash
# Force-delete pods stuck in Error or ContainerStatusUnknown
kubectl delete pod <pod> -n <namespace> --force --grace-period=0

# Find stale VolumeAttachments for the rebooted node
kubectl get volumeattachment | grep talos-w-01

# Delete stale VolumeAttachments
kubectl delete volumeattachment <name>
```

### Step 4: If a VolSync PVC has XFS corruption

If volsync reports `mount failed: exit status 32` on a snapshot PVC:

```bash
# Delete the volsync source PVC — it will be recreated fresh on the next backup run
kubectl delete pvc volsync-<app>-src -n <namespace>
```

---

## Stale VolumeAttachment with Stuck Finalizers

Some PVs (notably Mosquitto) have VolumeAttachments that re-appear after deletion due to stuck finalizers:

```bash
# Find the PV for the stuck VA
kubectl get volumeattachment <name> -o jsonpath='{.spec.source.persistentVolumeName}'

# Remove finalizers from the PV
kubectl patch pv <pv-name> --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

---

## Root Cause

The RBD kernel module (`rbd: map failed: (108) Cannot send after transport endpoint shutdown`) loses its network transport to the Ceph cluster when the Proxmox host disk experiences I/O errors. Worker VMs freeze and the kernel RBD state becomes irrecoverable without a node reboot.

**Prevention:** The Proxmox OS disk was replaced (T-FORCE 1 TB SSD) after the WD Blue SSD that caused this reached 85% wear. VolSync `moverAffinity` podAntiAffinity was added to spread backup jobs across nodes, reducing the chance of a concurrent RBD mount storm.

---

## Prometheus WAL Corruption (After Node Crash)

If Prometheus fails to start after a crash with `segments are not sequential` errors:

```bash
# Scale down Prometheus
kubectl scale -n observability statefulset prometheus-kube-prometheus-stack-prometheus --replicas=0

# Get a shell (pod must exist — scale to 1 with a sleep command if needed, or use a debug pod)
# Wipe the entire WAL directory (NOT individual segments)
kubectl -n observability exec <prometheus-pod> -- rm -rf /prometheus/prometheus-db/wal/

# Scale back up
kubectl scale -n observability statefulset prometheus-kube-prometheus-stack-prometheus --replicas=1
```

This loses ~2 hours of uncompacted metrics only. Compacted TSDB blocks on disk are untouched.
