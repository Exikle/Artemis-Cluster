# VolSync Backup & Restore

VolSync provides automated PVC backup and restore using Kopia. All backup configuration is templated via shared Kustomize components.

---

## Architecture

```
ReplicationSource (per app)
  └── VolSync operator → Kopia mover pod → S3 backup repository
ReplicationDestination (per app)
  └── VolSync operator → Kopia mover pod → restores to new PVC
```

Credentials (S3 endpoint, bucket, keys) are synced from 1Password via ExternalSecret in `kubernetes/components/volsync/externalsecret.yaml`.

---

## Shared Components

Located in `kubernetes/components/volsync/`. Apps include them via:

```yaml
# app/kustomization.yaml
components:
    - ../../../components/volsync
```

| File                          | Purpose                        |
| ----------------------------- | ------------------------------ |
| `pvc.yaml`                    | PVC definition                 |
| `replicationsource.yaml`      | Backup schedule + Kopia config |
| `replicationdestination.yaml` | Restore destination            |
| `externalsecret.yaml`         | S3 credentials from 1Password  |

### Key Settings

- **`fsGroupChangePolicy: OnRootMismatch`** — prevents recursive chown on every backup. Critical for apps with large filesystems (e.g. Jellyfin with 21k+ trickplay files — without this, backups take 1 hour+ just on chown).
- **`moverAffinity` podAntiAffinity** — spreads mover pods across nodes. Without this, all backup jobs land on a single node causing concurrent RBD mount storms and CSI failures.

> Note: the descheduler cannot help here — it excludes Job-owned pods from eviction. Anti-affinity must be set at scheduling time.

---

## Triggering a Manual Backup

```bash
# Annotate the ReplicationSource to trigger an immediate backup
kubectl annotate replicationsource <app> \
  volsync.backube/trigger-immediate-backup="$(date +%s)" \
  -n <namespace>

# Watch the backup job
kubectl get jobs -n <namespace> -w
kubectl logs -n <namespace> job/volsync-src-<app> -f
```

---

## Restoring a PVC

### Method 1: Restore to existing app (rolling restore)

1. Scale down the app:

    ```bash
    kubectl scale deploy/<app> -n <namespace> --replicas=0
    ```

2. Delete the existing PVC:

    ```bash
    kubectl delete pvc <app-data-pvc> -n <namespace>
    ```

3. Apply or annotate the `ReplicationDestination` to trigger a restore:

    ```bash
    kubectl annotate replicationdestination <app> \
      volsync.backube/trigger-immediate-restore="$(date +%s)" \
      -n <namespace>
    ```

4. Wait for the restore job to complete:

    ```bash
    kubectl get replicationdestination <app> -n <namespace> -w
    ```

5. The restored PVC is now bound. Scale the app back up:
    ```bash
    kubectl scale deploy/<app> -n <namespace> --replicas=1
    ```

### Method 2: Restore to a new namespace (disaster recovery)

Create a `ReplicationDestination` in the target namespace pointing to the same Kopia repository. The mover will pull the latest snapshot.

---

## Checking Backup Status

```bash
# List all ReplicationSources and their last sync time
kubectl get replicationsource -A

# Check a specific source
kubectl describe replicationsource <app> -n <namespace>

# Check mover pod logs for a running backup
kubectl logs -n <namespace> -l app.kubernetes.io/component=replication-source -f
```

---

## Volsync Maintenance

The `volsync-system/volsync/maintenance/` kustomization applies:

- `MutatingAdmissionPolicy` for default settings
- Kopia repository maintenance schedule (prune old snapshots)
- ExternalSecret for S3 credentials

---

## Troubleshooting

| Issue                          | Cause                           | Fix                                                   |
| ------------------------------ | ------------------------------- | ----------------------------------------------------- |
| Job stuck in `Init:0/1`        | RBD mount failure on mover node | See [RBD CSI Recovery](rbd-csi-recovery.md)           |
| `mount failed: exit status 32` | XFS corruption on snapshot PVC  | Delete `volsync-<app>-src` PVC                        |
| All movers on same node        | Missing `moverAffinity`         | Already applied in component; check patch is included |
| Backup taking 1h+              | `fsGroupChangePolicy` not set   | Already set in component; check patch is included     |
