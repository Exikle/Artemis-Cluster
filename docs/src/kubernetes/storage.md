# Storage

See also [Hardware → Storage](../hardware/storage.md) for the physical/NAS tier details.

---

## Storage Classes

| StorageClass               | Provisioner      | Access Mode | Use Case                              |
| -------------------------- | ---------------- | ----------- | ------------------------------------- |
| `ceph-blockpool` (default) | Rook-Ceph RBD    | RWO         | App databases, stateful services      |
| `ceph-filesystem`          | Rook-Ceph CephFS | RWX         | Shared config across pods             |
| `openebs-hostpath`         | OpenEBS          | RWO         | Local scratch/cache, single-node only |

---

## Rook-Ceph

Deployed in `rook-ceph` namespace. The cluster consists of:

- **3 OSDs** — one per control plane node (256 GB SATA SSD each)
- **3 MONs / 1 MGR** — on control plane nodes
- **`ceph-blockpool`** — replicated ×3, host-level failure domain
- **`ceph-filesystem`** — CephFS for RWX workloads

### Common Commands

```bash
# Check Ceph cluster health
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd status

# Check OSD usage
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df

# Check PG status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg stat

# Get pool list
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd lspools
```

### Known Limits

- `pg_autoscaler` enabled but capped at `mon_max_pg_per_osd=250` — cannot scale past this without adding OSDs or reducing pool count
- Adding a new OSD requires adding a new node to the explicit node list in the `CephCluster` resource (`useAllNodes: false`)

---

## OpenEBS

Deployed in `openebs-system`. Provides local `hostpath` PVCs for workloads that don't need replication. The mount point `/var/local/openebs` is configured as a bind mount in Talos kubelet `extraMounts`.

Used for: download client incomplete dirs (SABnzbd), cache volumes, scratch space.

---

## VolSync (PVC Backup/Restore)

VolSync automates PVC backups using Kopia. Deployed in `volsync-system`.

### Components

- `volsync` — operator
- `kopia` — backup engine (S3-compatible backend)

### Shared Components

Reusable Kustomize components in `kubernetes/components/volsync/`:

| File                          | Purpose                        |
| ----------------------------- | ------------------------------ |
| `pvc.yaml`                    | PVC template                   |
| `replicationsource.yaml`      | Backup schedule + Kopia config |
| `replicationdestination.yaml` | Restore destination config     |
| `externalsecret.yaml`         | S3 credentials from 1Password  |

### Key Settings Applied

- `fsGroupChangePolicy: OnRootMismatch` — prevents slow recursive chown on every backup (critical for Jellyfin with 21k+ files)
- `moverAffinity` podAntiAffinity — spreads backup pods across nodes to avoid RBD mount storms on a single worker

See [VolSync Operations](../operations/volsync.md) for backup and restore procedures.

---

## NFS (TrueNAS)

Bulk media storage is served via NFS from `atlas` (10.10.99.100). All media pods mount `/mnt/atlas/media` as `/media`.

NFS v4.2 is enforced via `/etc/nfsmount.conf` on all Talos nodes (configured in `machineconfig.yaml.j2`).

### KEDA NFS Scaler

A KEDA `ScaledObject` in `kubernetes/components/nfs-scaler/` can scale deployments based on NFS availability. Used to gate pods that depend on the NFS mount being healthy.
