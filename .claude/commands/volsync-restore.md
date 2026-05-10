Restore a VolSync-managed PVC from its most recent backup snapshot.

## Step 1 — Identify the app and confirm

Ask the user:

- **App name** and **namespace**
- **Reason for restore** (data corruption, accidental delete, migration)

Warn: restoring overwrites the current PVC contents. Confirm before proceeding.

## Step 2 — Check current backup state

```bash
kubectl get replicationsource -n <namespace>
kubectl get replicationdestination -n <namespace>
kubectl describe replicationsource <app>-src -n <namespace>
```

Check `lastSyncTime` and `lastSyncDuration` — confirm a recent successful backup exists before restoring.

## Step 3 — Scale down the app

The PVC must be unmounted before VolSync can restore into it.

```bash
kubectl scale deployment <app> -n <namespace> --replicas=0
# Wait for pod to terminate
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
```

## Step 4 — Delete the existing PVC

VolSync restore creates a new PVC via ReplicationDestination. The old PVC must be gone first.

```bash
kubectl delete pvc <app> -n <namespace>
```

## Step 5 — Trigger the restore

VolSync uses a ReplicationDestination to restore. Check if one exists:

```bash
kubectl get replicationdestination -n <namespace>
```

If none exists, create one — use the existing ReplicationSource as reference for storageClassName, capacity, and accessModes:

```bash
kubectl describe replicationsource <app>-src -n <namespace> | grep -A10 "Spec"
```

Create the ReplicationDestination:

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
    name: <app>-restore
    namespace: <namespace>
spec:
    trigger:
        manual: restore-1
    restic:
        repository: <app>-volsync-secret # same secret the source uses
        destinationPVC: <app>
        storageClassName: ceph-block
        accessModes:
            - ReadWriteOnce
        capacity: <capacity> # must match ks.yaml VOLSYNC_CAPACITY
        copyMethod: Snapshot
        moverSecurityContext:
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            fsGroupChangePolicy: OnRootMismatch
```

Apply it:

```bash
kubectl apply -f /tmp/restore.yaml
```

## Step 6 — Monitor the restore

```bash
kubectl get replicationdestination <app>-restore -n <namespace> -w
kubectl logs -n <namespace> -l app.kubernetes.io/component=mover --tail=30
```

Wait for `latestImage` to be populated in the ReplicationDestination status — that means the PVC has been restored.

## Step 7 — Verify PVC and scale back up

```bash
kubectl get pvc <app> -n <namespace>
kubectl scale deployment <app> -n <namespace> --replicas=1
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl logs -n <namespace> deployment/<app> --tail=20
```

## Step 8 — Clean up the ReplicationDestination

Once the app is confirmed healthy, delete the restore object:

```bash
kubectl delete replicationdestination <app>-restore -n <namespace>
```

## Common issues

- **Mover pod stuck pending**: check `moverAffinity` — all movers landing on same node causes RBD mount storms. Add podAntiAffinity to the ReplicationDestination moverAffinity field.
- **Wrong ownership after restore**: if the app gets permission errors, set `fsGroupChangePolicy: Always` on the app deployment (not the mover) to force chown on mount.
- **Restore PVC wrong size**: capacity in ReplicationDestination must exactly match `VOLSYNC_CAPACITY` in ks.yaml — Restic will fail if there's a mismatch.
- **Repository secret not found**: secret is named `<app>-volsync-secret` and lives in the same namespace — verify with `kubectl get secret -n <namespace> | grep volsync`.
- **latestImage never populates**: check mover pod logs for Restic errors — common cause is wrong S3/B2 credentials in the volsync secret.
