# Reference: Storage — Artemis-Cluster

## NFS Media Mount

- **Server**: `10.10.99.100` (TrueNAS `atlas`)
- **Path**: `/mnt/atlas/media` → mounted at `/media` in pods
- **Usable**: ~41TB (3× RAIDZ2)

## Rook-Ceph

- 3 OSDs total on M710q control plane nodes — do not add without explicit direction
- `useAllNodes: false` — never change to `useAllNodes: true`
- `pg_autoscaler` hard limit: `mon_max_pg_per_osd=250` — cannot be exceeded by adding pools
- Storage classes:
    - `ceph-block` — RWO block storage (RBD), for app config/DBs
    - `ceph-filesystem` — RWX shared filesystem (CephFS)

## VolSync

- Referenced in `ks.yaml` components: `../../../../components/volsync`
- PVC size: set in `ks.yaml` postBuild substitute `VOLSYNC_CAPACITY` — **not** in app manifests
- `moverSecurityContext.fsGroupChangePolicy: OnRootMismatch` — prevents kubelet rechowning all files on every backup
- `moverAffinity` podAntiAffinity required — prevents all mover pods landing on `talos-w-01`, which causes RBD mount storms
- If wrong ownership after restore: set `fsGroupChangePolicy: Always` on the **app pod** (not the mover)
- PVC in HelmRelease: `existingClaim: <app>` when using VolSync component

```bash
just kube snapshot            # trigger VolSync manual snapshots
just kube browse-pvc <ns> <pvc>  # browse a PVC interactively
just kube volsync <state>     # suspend or resume VolSync (suspend/resume)
```

## RBD CSI Recovery (pods stuck ContainerCreating)

Symptoms: `input/output error` on mounts, `operation already exists` in CSI logs, `MountVolume.SetUp failed`.

```bash
# Step 1 — restart CSI node plugin on the affected node
kubectl delete pod -n rook-ceph -l app=csi-rbdplugin --field-selector spec.nodeName=<node>
# wait ~30s; check if pods recover
kubectl get pods -A | grep ContainerCreating

# Step 2 — clean stale VolumeAttachments (if pods still stuck)
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>

# Step 3 — if kernel-level RBD module is broken
talosctl reboot -n <ip> --wait

# Step 4 — hard reset (last resort)
# Proxmox: qm reset <vmid>
```

## Prometheus WAL Corruption (after crash)

- **Never** delete individual WAL segments — creates sequential gaps that break Prometheus
- Scale down Prometheus → wipe entire `/prometheus/prometheus-db/wal/` → scale back up
