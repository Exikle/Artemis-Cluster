---
name: kopiur-restore
description: Restore a PVC from a kopiur backup or snapshot — recovering an app's data after loss, corruption, or a bad change. Use for "restore X from backup", "restore from kopiur", "kopiur restore", "recover PVC", "recover X's data", "roll back X's data", "undo a bad migration", or "the PVC is empty". Scoped to the Artemis cluster.
---

# Skill: Kopiur Restore

Restore a kopiur-managed PVC from a snapshot in **Artemis-Cluster**.

The default kubeconfig context is `artemis`; confirm with `kubectx` before running anything
destructive. (This runbook was originally written against Frostlink — if you find a
`--kubeconfig /home/exikle/frostlink/kubeconfig` flag or an `openebs-zfs` StorageClass anywhere
below, it is a leftover and it is wrong for this repo.)

## Critical Rules

- **Always use `target.pvcRef`** — `target.pvc` creates an OWNED PVC that gets GC'd when the Restore completes, deleting your data. Pre-create the PVC manually and point `pvcRef` at it.
- Scale the app to 0 before restoring — RWO volumes can only be mounted once.
- kopiur mover cache defaults to `1Mi` — always set `mover.cache.capacity: 2Gi` in the SnapshotPolicy or the snapshot will fail with disk quota exceeded.
- For postgres PVCs (uid 999, mode 700): use `copyMethod: Snapshot` + `moverSecurityContext: runAsUser: 999, runAsGroup: 999`.
- `copyMethod: Direct` fails while the app is running — it cannot remount a live RWO volume. Scale to 0 first, or use `copyMethod: Snapshot`.
- Artemis StorageClasses are `ceph-block` (block, the kopiur default) and `ceph-filesystem`. There is no `openebs-zfs` here — that is Frostlink.
- Flux Kustomizations live in the app's **target namespace** (`media`, `cortex`, …), not always `flux-system`. Look up the real name: `grep "^  name:" kubernetes/apps/<ns>/<app>/ks.yaml`.
- `just kube apply-ks` suspends the root Kustomization and the target child. Whatever you suspend by hand during a restore, finish with `just kube resume-ks`.

## Step 1 — Confirm

Ask:

- **App name** and **namespace**
- **Which PVC** to restore (name, size, storageClass)
- **Which snapshot** (latest or specific snapshot name from `kubectl get snapshot -n <ns>`)
- **Reason** (data corruption, accidental delete, migration)

Warn: restoring overwrites current PVC contents. Get explicit confirmation.

## Step 2 — Check Available Snapshots

```bash
kubectl get snapshot -n <namespace>
```

Note the snapshot name — you'll need it for the Restore spec.

## Step 3 — Scale Down the App

```bash
kubectl scale deployment/<app> -n <namespace> --replicas=0
kubectl get pods -n <namespace>
```

Wait until no pods remain.

## Step 4 — Patch PV Reclaim Policy to Retain (if replacing existing PVC)

Get the PV name from the existing PVC, then:

```bash
kubectl patch pv <pv-name> \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Delete the old PVC:

```bash
kubectl delete pvc <pvc-name> -n <namespace>
```

If the PVC is stuck Terminating, a completed mover pod may hold the `pvc-protection` finalizer — delete it:

```bash
kubectl delete pod <mover-pod> -n <namespace>
```

## Step 5 — Pre-Create the Target PVC

Create the PVC BEFORE creating the Restore. Do NOT use `dataSourceRef` — the Restore populates it via mover, not the populator API.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <capacity>
  storageClassName: ceph-block
EOF
```

## Step 6 — Create the Restore

```bash
kubectl apply -f - <<'EOF'
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata:
  name: <app>-restore
  namespace: <namespace>
spec:
  credentialProjection:
    enabled: true
  source:
    snapshotRef:
      name: <snapshot-name>
  target:
    pvcRef:
      name: <pvc-name>
EOF
```

## Step 7 — Monitor

```bash
kubectl get restore <app>-restore -n <namespace> -w
kubectl get pods -n <namespace>
kubectl logs -n <namespace> <mover-pod> --tail=30
```

Wait for Restore phase to become `Succeeded`.

## Step 8 — Scale Back Up and Verify

```bash
kubectl scale deployment/<app> -n <namespace> --replicas=1
kubectl get pods -n <namespace>
kubectl logs -n <namespace> deployment/<app> --tail=20
```

## Step 9 — Clean Up

Delete the Restore object (the mover pod will be GC'd automatically):

```bash
kubectl delete restore <app>-restore -n <namespace>
```

Check for any orphan kopia cache PVCs:

```bash
kubectl get pvc -n <namespace> | grep kopia-cache
```

Delete them if present.

## Common Issues

- **Snapshot stuck with `snapshot-cleanup` finalizer**: remove it manually and re-delete
    ```bash
    kubectl patch snapshot <name> -n <ns> \
      --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
    ```
- **Mover pod `Init:0/1` with FailedMount**: volume still mounted by another pod — scale app to 0 first
- **`disk quota exceeded`**: SnapshotPolicy missing `mover.cache.capacity: 2Gi` — add it and re-snapshot
- **Restore stuck Pending**: check that the source snapshot is `Succeeded` phase, not `Failed`
- **PVC stays `Pending` on a `WaitForFirstConsumer` StorageClass**: nothing has mounted it yet — the Restore mover pod is what binds it. Not a failure until the mover has started and it is still Pending.
