# Skill: RBD CSI Recovery

Diagnose and recover from RBD CSI failures causing pods to get stuck in `Init:0/1` or `ContainerCreating`.

> Read `.agents/references/storage.md` for full RBD CSI and VolSync context.

## Two Distinct Failure Modes

### A — Stale RBD Watcher (common; triggered by GitOps pod restarts)

**Symptoms:**

- `FailedAttachVolume: Multi-Attach error — Volume is already exclusively attached`
- `FailedMount: MountVolume.SetUp failed ... lstat ... input/output error`
- Single pod stuck in `Init:0/1`; all other pods on the node are healthy

**Cause:** `rbd unmap` lost a race with in-flight kernel I/O during pod termination. The kernel RBD driver kept its TCP connection to the Ceph OSD alive, so Ceph's 30s watch timeout never fired. The stale watcher holds the exclusive lock and blocks any new attachment.

**Fix — Ceph blocklist only. Never restart the CSI node plugin.**

Restarting the CSI node plugin on a live node disrupts the kernel-level mounts for every other RBD volume on that node — turning a single stuck pod into a cluster-wide cascade.

```bash
# 1. Find the stuck pod's PV and CSI volume handle
kubectl get pvc -n <namespace> <pvc-name> -o jsonpath='{.spec.volumeName}'
kubectl get pv <pv-name> -o jsonpath='{.spec.csi.volumeHandle}'
# volumeHandle format: 0001-0009-rook-ceph-...-<csi-vol-uuid>
# RBD volume name: csi-vol-<csi-vol-uuid>

# 2. Check for stale watcher
kubectl exec -n rook-ceph <tools-pod> -c rook-ceph-tools -- \
  rbd status ceph-blockpool/csi-vol-<uuid>
# If "Watchers: watcher=<ip>:0/<client-id> ..." → stale watcher present

# 3. Blocklist the watcher client
kubectl exec -n rook-ceph <tools-pod> -c rook-ceph-tools -- \
  ceph osd blocklist add <ip>:0/<client-id>

# 4. Verify watcher is gone
kubectl exec -n rook-ceph <tools-pod> -c rook-ceph-tools -- \
  rbd status ceph-blockpool/csi-vol-<uuid>
# Should show "Watchers: none"

# 5. Force-delete the stuck pod (Deployment/StatefulSet will reschedule)
kubectl delete pod -n <namespace> <pod-name> --force --grace-period=0

# 6. Remove from blocklist
kubectl exec -n rook-ceph <tools-pod> -c rook-ceph-tools -- \
  ceph osd blocklist rm <ip>:0/<client-id>

# 7. Verify pod comes up Running on new node
kubectl get pod -n <namespace> <new-pod-name> -w
```

---

### B — Broken Kernel RBD Module (rare; triggered by host storage I/O errors)

**Symptoms:**

- `Cannot send after transport endpoint shutdown`
- `operation already exists` in CSI node plugin logs
- Multiple pods failing on the same node simultaneously (not a single stuck pod)
- Node-level RBD errors in `talosctl dmesg`

**Cause:** Underlying VM host storage I/O errors (Proxmox disk failure, NCQ timeouts) corrupted the kernel RBD module state.

**Fix — Drain then reboot the node:**

```bash
# 1. Drain the node to move pods off cleanly
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# 2. Reboot
talosctl reboot -n <node-ip> --wait

# If the node hangs (kernel RBD unmount stalls) → hard reset via Proxmox:
ssh pantheon "qm reset <vmid>"
# VM IDs: talos-w-01=101, talos-w-02=102, talos-gpu-01=103

# 3. After node is Ready, clean up stale VolumeAttachments
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>

# 4. Force-delete any Error/Unknown pods that didn't reschedule
kubectl get pods -A | grep -E "Error|Unknown"
kubectl delete pod <pod> -n <namespace> --force --grace-period=0
```

---

## Which Mode Am I In?

| Signal                                        | Mode              |
| --------------------------------------------- | ----------------- |
| Single pod stuck, others on same node healthy | A — Stale watcher |
| `Multi-Attach error` in pod events            | A — Stale watcher |
| Multiple pods failing on same node at once    | B — Kernel broken |
| `transport endpoint shutdown` in CSI logs     | B — Kernel broken |
| Node went NotReady or had I/O errors          | B — Kernel broken |

---

## After a Node Reboot — VolumeAttachment Cleanup

Node reboots leave VolumeAttachment objects in the Kubernetes API even after the node's kernel mounts are cleared. Pods rescheduled to other nodes will hit `Multi-Attach error` until these are removed:

```bash
# Find stale VolumeAttachments (attached=true but no pod on that node using the PVC)
kubectl get volumeattachment | grep <rebooted-node>

# For each one where no pod on that node needs the volume:
kubectl delete volumeattachment <name>
```

---

## Root Cause Context

- **Stale watcher:** `rbd unmap` fails silently during pod termination (kernel race with in-flight I/O). The kernel holds the Ceph OSD TCP connection open, preventing the 30s watch timeout from clearing the watcher.
- **Kernel broken:** VM host-level storage errors (Proxmox NCQ, disk failure) corrupt the RBD kernel module state. Requires node reboot.

## Prevention

- A PrometheusRule fires when any pod is scheduled but still Pending for > 10 minutes — catch stale watchers before they're noticed by the user. See `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` (`volume-mount-rules`).
- VolSync movers use `moverAffinity` podAntiAffinity to prevent concurrent RBD mounts on the same node. Already set in `kubernetes/components/volsync/replicationsource.yaml`.
