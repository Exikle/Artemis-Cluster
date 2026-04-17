# Storage

The cluster uses three distinct storage tiers: distributed block storage (Rook-Ceph), local host-path storage (OpenEBS), and network-attached bulk storage (TrueNAS).

---

## Rook-Ceph (Block Storage)

Three OSDs — one per control plane node — provide replicated block storage for stateful apps.

| Node        | OSD Device      | Capacity                   |
| ----------- | --------------- | -------------------------- |
| talos-cp-01 | 256 GB SATA SSD | ~85 GB usable (3× replica) |
| talos-cp-02 | 256 GB SATA SSD |                            |
| talos-cp-03 | 256 GB SATA SSD |                            |

- **Failure domain:** host
- **Default StorageClass:** `ceph-blockpool` (RWO, replicated ×3, volume expansion enabled)
- **Filesystem StorageClass:** `ceph-filesystem` (RWX, CephFS)
- `useAllNodes: false` — nodes are explicitly listed; do not change to `useAllNodes: true`
- `pg_autoscaler` is enabled but capped at `mon_max_pg_per_osd=250`

> **Rule:** Rook-Ceph block storage is for app config, databases, and PVCs that need replication. Bulk media lives on TrueNAS NFS — never on Ceph.

---

## OpenEBS (Local Storage)

OpenEBS provides `hostpath` local PVCs for workloads that need fast local storage without replication. Uses a bind mount at `/var/local/openebs` (configured in the Talos kubelet `extraMounts`).

- **StorageClass:** `openebs-hostpath`
- Used for: scratch space, cache, temporary data
- No replication — data is lost if the node is destroyed

---

## TrueNAS (`atlas`)

The NAS hosts all bulk media and is the backing store for Jellyfin, the arr stack, and download clients.

| Field    | Value                                                                          |
| -------- | ------------------------------------------------------------------------------ |
| Hostname | atlas                                                                          |
| IP       | 10.10.99.100                                                                   |
| Hardware | Supermicro, Xeon E5-2643 v0                                                    |
| RAM      | 94.3 GB ECC                                                                    |
| OS       | TrueNAS SCALE                                                                  |
| Pool     | 3× RAIDZ2 6-wide of 3.49 TB drives + 1 TB mirror metadata vdev (~41 TB usable) |

### NFS Mount

The export `/mnt/atlas/media` is mounted into pods at `/media`.

```yaml
# Example NFS PVC
apiVersion: v1
kind: PersistentVolume
spec:
    nfs:
        server: 10.10.99.100
        path: /mnt/atlas/media
```

NFS version 4.2 is enforced cluster-wide via `/etc/nfsmount.conf` on all Talos nodes:

```ini
[ NFSMount_Global_Options ]
nfsvers=4.2
hard=True
noatime=True
```

### SMB

SMB shares use `force user = apps` / `force group = apps` (UID/GID 1000) for read/write access from management machines.

---

## VolSync (Backup & Restore)

VolSync provides automated PVC backup and restore using Kopia as the backend. Backups are stored in an S3-compatible bucket via the `volsync-system` namespace.

See the [VolSync operations runbook](../operations/volsync.md) for backup and restore procedures.
