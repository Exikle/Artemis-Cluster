# Skill: CNPG Database

Deploy and manage PostgreSQL via CloudNativePG in Artemis-Cluster. One Cluster per app — never shared.

## Directory Structure

```text
kubernetes/apps/<namespace>/<app>/
└── app/
    ├── cluster.yaml          # CNPG Cluster
    ├── scheduledbackup.yaml  # ScheduledBackup (optional)
    └── externalsecret.yaml   # DB credentials from 1Password
```

Add `cluster.yaml` and `scheduledbackup.yaml` to `app/kustomization.yaml` resources.

## Cluster Template

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
    name: <app>-pg
    namespace: <namespace>
spec:
    instances: 1
    storage:
        size: 10Gi
        storageClass: ceph-block
    walStorage:
        size: 2Gi
        storageClass: ceph-block
    bootstrap:
        initdb:
            database: <app>
            owner: <app>
            secret:
                name: <app>-pg-credentials
```

**Always include `walStorage` on its own volume.** If WAL shares the data disk and archiving lags (or isn't configured), WAL fills the data PVC and the pod enters CrashLoopBackOff. Separate volumes prevent this.

## Credentials via ExternalSecret

CNPG expects keys `username` and `password` exactly:

```yaml
target:
    template:
        data:
            username: "{{ .db_username }}"
            password: "{{ .db_password }}"
```

Store in 1Password as `<app>-pg` item with fields `db_username` and `db_password`.

App connection string env var:

```yaml
env:
    DATABASE_URL: "postgresql://$(DB_USER):$(DB_PASS)@<app>-pg-rw.<namespace>.svc.cluster.local:5432/<app>"
```

The `<app>-pg-rw` service is auto-created by CNPG (read-write). `<app>-pg-ro` is read-only.

## Monitoring

CNPG operator installs ServiceMonitor automatically. Verify:

```bash
kubectl get cluster -n <namespace>
kubectl get pods -n <namespace> -l cnpg.io/cluster=<app>-pg
kubectl describe cluster <app>-pg -n <namespace>
```

## VolSync Backup of CNPG PVCs

CNPG PVCs (`<app>-pg-1`) can use the cluster VolSync component for off-site backup. Add VolSync component to the `ks.yaml`:

```yaml
components:
    - ../../../components/volsync
```

Set `existingClaim: <app>-pg-1` in VolSync postBuild substitutions.

## Common Issues

| Symptom                          | Cause                           | Fix                                                              |
| -------------------------------- | ------------------------------- | ---------------------------------------------------------------- |
| Pod stuck Pending                | `ceph-block` PVC not bound      | Check RBD CSI pods in `rook-ceph` — use `rbd-csi-recovery` skill |
| `password authentication failed` | Secret key mismatch             | CNPG needs exactly `username` + `password` keys                  |
| WAL directory fills              | No `walStorage` separate volume | Add `walStorage` section and reapply                             |
| Cluster stuck Initializing       | CRD not installed               | Check `kubectl get crd clusters.postgresql.cnpg.io`              |
| App can't connect                | Wrong service name              | Use `<app>-pg-rw` (not `<app>-pg`) for read-write                |
