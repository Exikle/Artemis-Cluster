# Skill: VolSync Restore

Restore a VolSync-managed PVC from its most recent backup snapshot.

## Step 1 — Confirm

Ask:

- **App name** and **namespace**
- **Reason** (data corruption, accidental delete, migration)

Warn: restoring overwrites current PVC contents. Get explicit confirmation before proceeding.

## Step 2 — Check Backup State

```bash
kubectl get replicationsource -n <namespace>
kubectl describe replicationsource <app>-src -n <namespace>
```

Check `lastSyncTime` and `lastSyncDuration` — confirm a recent successful backup exists.

## Step 3 — Scale Down the App

PVC must be unmounted before VolSync can restore into it.

```bash
kubectl scale deployment <app> -n <namespace> --replicas=0
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
```

Wait until no pods remain.

## Step 4 — Delete the Existing PVC

```bash
kubectl delete pvc <app> -n <namespace>
```

## Step 5 — Trigger the Restore

Check if a ReplicationDestination already exists:

```bash
kubectl get replicationdestination -n <namespace>
```

If none exists, get the source spec to match storageClassName and capacity:

```bash
kubectl describe replicationsource <app>-src -n <namespace> | grep -A10 "Spec"
```

Create `/tmp/restore.yaml`:

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
        repository: <app>-volsync-secret
        destinationPVC: <app>
        storageClassName: ceph-block
        accessModes:
            - ReadWriteOnce
        capacity: <capacity> # must match ks.yaml VOLSYNC_CAPACITY exactly
        copyMethod: Snapshot
        moverSecurityContext:
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            fsGroupChangePolicy: OnRootMismatch
```

```bash
kubectl apply -f /tmp/restore.yaml
```

## Step 6 — Monitor

```bash
kubectl get replicationdestination <app>-restore -n <namespace> -w
kubectl logs -n <namespace> -l app.kubernetes.io/component=mover --tail=30
```

Wait for `latestImage` to be populated in status.

## Step 7 — Verify and Scale Back Up

```bash
kubectl get pvc <app> -n <namespace>
kubectl scale deployment <app> -n <namespace> --replicas=1
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl logs -n <namespace> deployment/<app> --tail=20
```

## Step 8 — Clean Up

Once app is confirmed healthy:

```bash
kubectl delete replicationdestination <app>-restore -n <namespace>
```

## Common Issues

- **Mover pod stuck pending**: add `moverAffinity` podAntiAffinity to ReplicationDestination — prevents RBD mount storms when all movers land on same node
- **Wrong ownership after restore**: set `fsGroupChangePolicy: Always` on the app deployment (not the mover)
- **Wrong PVC size**: capacity in ReplicationDestination must exactly match `VOLSYNC_CAPACITY` in ks.yaml
- **Secret not found**: secret is `<app>-volsync-secret` in same namespace — `kubectl get secret -n <namespace> | grep volsync`
- **latestImage never populates**: check mover pod logs for Restic errors — usually wrong S3/B2 credentials in volsync secret
