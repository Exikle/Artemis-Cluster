# Skill: RBD CSI Recovery

Diagnose and recover from RBD CSI node plugin failures causing pods to get stuck in `ContainerCreating`.

> Read `.agents/references/storage.md` for the full RBD CSI and VolSync context if this is your first time running this recovery.

## Symptoms

- Pods stuck in `ContainerCreating` with `input/output error` on mounts
- CSI node plugin logs: `operation already exists` or `Cannot send after transport endpoint shutdown`
- `MountVolume.SetUp failed` with `lstat ... input/output error`
- VolSync jobs stuck in `Init:0/1`

## Step 1 — Identify the Affected Node

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl describe pod <stuck-pod> -n <namespace> | grep -A10 Events
```

Find the node name from the events output.

## Step 2 — Restart the CSI Node Plugin

```bash
kubectl delete pod -n rook-ceph -l app=csi-rbdplugin --field-selector spec.nodeName=<node>
# Wait ~30s, then check if pods recover
kubectl get pods -A | grep ContainerCreating
```

If pods recover → done. If not, the RBD module is broken at the kernel level → continue.

## Step 3 — Reboot the Worker Node

```bash
talosctl reboot -n <node-ip> --wait
```

If the node hangs during reboot (kernel RBD unmount stalls) → hard reset via Proxmox:

```bash
ssh pantheon "qm reset <vmid>"
```

VM IDs: `talos-w-01=101`, `talos-w-02=102`, `talos-gpu-01=103` (verify with `qm list`).

## Step 4 — Clean Up Stale VolumeAttachments

After node comes back, check for stale attachments:

```bash
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>
```

If a VolumeAttachment keeps coming back (finalizer loop):

```bash
kubectl patch pv <pv-name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

## Step 5 — Clean Up Stuck Pods

```bash
# Force-delete Error/ContainerStatusUnknown pods
kubectl get pods -A | grep -E "Error|Unknown"
kubectl delete pod <pod> -n <namespace> --force --grace-period=0
```

## Step 6 — Fix XFS-Corrupted VolSync PVC (if applicable)

If a VolSync snapshot PVC has XFS corruption (`mount failed: exit status 32`):

```bash
kubectl delete pvc volsync-<app>-src -n <namespace>
# VolSync recreates the snapshot PVC fresh on next backup cycle
```

## Step 7 — Verify Recovery

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
flux get all -A --status-selector ready=false
```

## Root Cause Context

`rbd: map failed: (108) Cannot send after transport endpoint shutdown` = kernel RBD module lost network transport. Requires node reboot to clear. Common trigger: underlying VM host storage I/O errors (Proxmox disk failure, NCQ timeouts).

## Prevention

- VolSync movers must have `moverAffinity` podAntiAffinity — prevents concurrent RBD mounts on same node causing mount storms
- This is already set in `kubernetes/components/volsync/replicationsource.yaml`
- descheduler won't help — it excludes Job-owned pods (`excludeOwnerKinds: - Job`)
