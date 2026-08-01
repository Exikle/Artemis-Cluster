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

## kopiur

VolSync was fully removed 2026-08-01. All 29 apps back up via kopiur to `ClusterRepository/atlas`
(NFS `10.10.99.100:/mnt/atlas/Kopiur`). The old VolSync kopia repo remains on the NAS at
`atlas/VolsyncKopia` as a frozen historical fallback — restoring from it needs a manual kopia client.

- Referenced in `ks.yaml` components: `../../../../components/kopiur/backup`
- PVC size: set in `ks.yaml` postBuild substitute `KOPIUR_CAPACITY` — **not** in app manifests
- Each backed-up namespace also needs `../../components/kopiur/secret` in its namespace
  kustomization — the mover reads the repo password from its OWN namespace (`envFrom` is
  namespace-local), so the Secret name is fixed and cannot be per-app
- PVC in HelmRelease: `existingClaim: <app>`
- **Mover uid**: defaults to 1000. Override with `KOPIUR_PUID`/`KOPIUR_PGID` **only when the
  app's on-disk data is owned by something else** — read actual ownership, never trust the pod's
  `fsGroup` (it misleads: apoci reported 999 but data was 1000, pocket-id 65534 but data 1000).
  With `copyMethod: Snapshot` the source clone is mounted read-only, so the kubelet cannot chgrp
  it and a mismatched mover just gets permission denied. Cluster-wide only xbrowsersync needs it
  (999, mongodb sidecar).
- **`restore.yaml` must mirror the SnapshotPolicy's mover identity** or a restore writes files as
  1000 regardless of the app's uid and the app cannot open its own data.
- **A completed `Restore` is never re-reconciled.** If Flux changes its spec, `observedGeneration`
  lags forever, kstatus reports InProgress, and any `wait: true` Kustomization hangs the full 60m
  timeout. Annotating does not help — delete the Restore and let Flux recreate it (the PVC stays
  bound, no data moves).

```bash
just kube snapshot               # snapshot every kopiur SnapshotPolicy now
just kube browse-pvc <ns> <pvc>  # browse a PVC interactively
just kube kopiur <state>         # suspend or resume kopiur (suspend/resume)
just kube restore <ns> <app> [offset]  # restore a PVC in place (0 = latest)
kopiur status -n <ns>            # repositories, policies, schedules
kopiur doctor -n <ns>            # diagnose an installation
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
