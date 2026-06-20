# Skill: Kopiur Restore

Restore a kopiur-managed PVC from a snapshot on Frostlink.

## Critical Rules

- **Always use `target.pvcRef`** — `target.pvc` creates an OWNED PVC that gets GC'd when the Restore completes, deleting your data. Pre-create the PVC manually and point `pvcRef` at it.
- Scale the app to 0 before restoring — RWO volumes can only be mounted once.
- kopiur mover cache defaults to `1Mi` — always set `mover.cache.capacity: 2Gi` in the SnapshotPolicy or the snapshot will fail with disk quota exceeded.
- For postgres PVCs (uid 999, mode 700): use `copyMethod: Snapshot` + `moverSecurityContext: runAsUser: 999, runAsGroup: 999`.
- openebs-zfs does NOT support remounting a live volume — `copyMethod: Direct` fails if the app is running. Always use `copyMethod: Snapshot`.
- Namespace for Frostlink kustomizations is `fediverse` (not `flux-system`).

## Step 1 — Confirm

Ask:

- **App name** and **namespace**
- **Which PVC** to restore (name, size, storageClass)
- **Which snapshot** (latest or specific snapshot name from `kubectl get snapshot -n <ns>`)
- **Reason** (data corruption, accidental delete, migration)

Warn: restoring overwrites current PVC contents. Get explicit confirmation.

## Step 2 — Check Available Snapshots

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get snapshot -n <namespace>
```

Note the snapshot name — you'll need it for the Restore spec.

## Step 3 — Scale Down the App

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig scale deployment/<app> -n <namespace> --replicas=0
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get pods -n <namespace>
```

Wait until no pods remain.

## Step 4 — Patch PV Reclaim Policy to Retain (if replacing existing PVC)

Get the PV name from the existing PVC, then:

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig patch pv <pv-name> \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Delete the old PVC:

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig delete pvc <pvc-name> -n <namespace>
```

If the PVC is stuck Terminating, a completed mover pod may hold the `pvc-protection` finalizer — delete it:

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig delete pod <mover-pod> -n <namespace>
```

## Step 5 — Pre-Create the Target PVC

Create the PVC BEFORE creating the Restore. Do NOT use `dataSourceRef` — the Restore populates it via mover, not the populator API.

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig apply -f - <<'EOF'
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
  storageClassName: openebs-zfs
EOF
```

## Step 6 — Create the Restore

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig apply -f - <<'EOF'
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
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get restore <app>-restore -n <namespace> -w
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get pods -n <namespace>
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig logs -n <namespace> <mover-pod> --tail=30
```

Wait for Restore phase to become `Succeeded`.

## Step 8 — Scale Back Up and Verify

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig scale deployment/<app> -n <namespace> --replicas=1
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get pods -n <namespace>
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig logs -n <namespace> deployment/<app> --tail=20
```

## Step 9 — Clean Up

Delete the Restore object (the mover pod will be GC'd automatically):

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig delete restore <app>-restore -n <namespace>
```

Check for any orphan kopia cache PVCs:

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get pvc -n <namespace> | grep kopia-cache
```

Delete them if present.

## Common Issues

- **Snapshot stuck with `snapshot-cleanup` finalizer**: remove it manually and re-delete
    ```bash
    kubectl --kubeconfig /home/exikle/frostlink/kubeconfig patch snapshot <name> -n <ns> \
      --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
    ```
- **Mover pod `Init:0/1` with FailedMount**: volume still mounted by another pod — scale app to 0 first
- **`disk quota exceeded`**: SnapshotPolicy missing `mover.cache.capacity: 2Gi` — add it and re-snapshot
- **Restore stuck Pending**: check that the source snapshot is `Succeeded` phase, not `Failed`
- **openebs-zfs WaitForFirstConsumer**: PVC stays Pending until a pod actually mounts it — the Restore mover pod counts
