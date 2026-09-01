# Reference: Storage — Artemis-Cluster

The entry point for cluster storage: what StorageClasses exist, the NFS media mount, and the PVC
lifecycle — including the orphans nothing reclaims. Read this first, then go sideways:

| File                         | Covers                                                                  |
| ---------------------------- | ----------------------------------------------------------------------- |
| `rook-ceph.md`               | OSD topology rules, Ceph versions, CephX, mgr modules, RBD CSI recovery |
| `kopiur.md`                  | Backups — repository, component defaults, mover uid, restores           |
| `osd-topology-2026-08-21.md` | Dated capacity/redundancy evaluation behind the OSD rules               |
| `pantheon-zfs.md`            | `pantheon`'s ZFS pools — host storage, not Kubernetes storage           |

## Storage Classes

| Class             | Backing              | Modes | Binding     | Reclaim  | Exists?                                                          |
| ----------------- | -------------------- | ----- | ----------- | -------- | ---------------------------------------------------------------- |
| `ceph-block`      | `ceph-blockpool` RBD | RWO   | `Immediate` | `Delete` | yes — the cluster **default**, and the only class on the cluster |
| `ceph-filesystem` | CephFS               | RWX   | —           | —        | **no** — see below                                               |

**There is no `ceph-filesystem` StorageClass and no `CephFilesystem` CR.** Verified against the
live cluster 2026-08-21: `kubectl get sc` returns `ceph-block` alone, and all 54 PVCs are on it.
Nothing in `kubernetes/` declares `cephFileSystems`. Older docs and skills still name
`ceph-filesystem` as the RWX option — treat that as aspirational, not available. **An app that
needs RWX today has no StorageClass to ask for**; a PVC naming `ceph-filesystem` sits `Pending`
forever with `storageclass.storage.k8s.io "ceph-filesystem" not found`. Either add the
`CephFilesystem` + its class first, or use the NFS mount above.

`ceph-block` is `volumeBindingMode: Immediate`, the **opposite** of Frostlink's `openebs-zfs`
(`WaitForFirstConsumer`). A new PVC here binds and provisions with no consumer, so a restore can
be driven with the workload scaled to zero — the Frostlink rule that "the workload must be scaled
back up to drive the restore" is a `WaitForFirstConsumer` property and does **not** apply here.

## NFS Media Mount

- **Server**: `10.10.99.100` (TrueNAS `atlas`)
- **Path**: `/mnt/atlas/media` → mounted at `/media` in pods
- **Usable**: ~41TB (3× RAIDZ2)

## Orphaned PVCs — nothing reclaims them, and they are 3× replicated

Deleting a HelmRelease, a StatefulSet, or migrating an app off its own database leaves the PVC
behind. `ceph-block` has `reclaimPolicy: Delete`, but that only fires when the **PVC** is deleted —
an unreferenced PVC is not garbage, it is just idle, and Kubernetes will hold it forever. On a
715 GiB raw / ~238 GiB usable cluster at `size=3`, every idle gibibyte costs three.

This table is the single inventory of orphaned PVCs in the repo — do not start a second one
elsewhere. Reclaiming the three left by retired per-app Postgres instances is tracked in
[#1889](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/1889).

Live audit 2026-08-21; **full re-verification 2026-09-01** (every row re-checked against the repo
tree and live pods, not just re-listed) — **~76 GiB logical (~228 GiB raw) bound to no pod**:

| PVC                                                                    | Size | Left behind by                          |
| ---------------------------------------------------------------------- | ---- | --------------------------------------- |
| `observability/prometheus-kube-prometheus-stack-db-prometheus-…-0`     | 50Gi | kube-prometheus-stack → VictoriaMetrics |
| `observability/alertmanager-kube-prometheus-stack-db-alertmanager-…-0` | 1Gi  | same                                    |
| `observability/config-gatus-0`                                         | 5Gi  | gatus → `gatus-sidecar` (see note)      |
| `media/data-streamystats-vectorchord-0`                                | 10Gi | streamystats → shared CNPG Postgres     |
| `media/data-rreading-glasses-postgres-0`                               | 5Gi  | per-app Postgres retired                |
| `tekton-system/postgredb-tekton-results-postgres-0`                    | 1Gi  | tekton-results Postgres retired         |
| `forgejo/exikle-pvc-setup-<suffix>`                                    | 4Gi  | a one-shot setup Job — see note         |

**Two rows that read as false positives and are not.** Both were nearly mis-triaged on 2026-09-01:

- **`config-gatus-0` does not mean gatus is gone.** `gatus-sidecar` is the current, running
  deployment (`kubernetes/apps/observability/gatus-sidecar`) and it has its **own** 5Gi claim named
  `gatus-sidecar`, which is mounted and correctly absent from this table. `config-gatus-0` (171d) is
  the pre-rename StatefulSet claim. Checking `find kubernetes -ipath '*gatus*'` rather than
  `kubernetes/apps/*/gatus` is what distinguishes them.
- **The two `kube-prometheus-stack` rows collide by name with live workloads.** `prometheus-adapter`
  runs but is a different component and uses no PVC; `alertmanager-0` runs but mounts a claim simply
  named `alertmanager`. Neither live workload touches the `*-kube-prometheus-stack-*` claims here.

**The forgejo row is recurring litter, not a one-time orphan.** Its suffix is random per Job run
(`85c88` on 2026-08-21, `lqx8q` on 2026-09-01), so deleting it reclaims 4Gi and a new one appears
on the next run. The durable fix is at the Job, not here.

Find them with a pod-volume diff, never by eyeballing `kubectl get pvc` — a bound PVC with no
consumer looks identical to a healthy one:

```bash
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $n
  | .spec.volumes[]? | select(.persistentVolumeClaim) | "\($n)/\(.persistentVolumeClaim.claimName)"' \
  | sort -u > /tmp/used
kubectl get pvc -A --no-headers -o custom-columns=A:.metadata.namespace,B:.metadata.name \
  | awk '{print $1"/"$2}' | sort -u | comm -23 - /tmp/used
```

**Check the list against a live restore before deleting anything.** Two entries are legitimately
consumer-free: `kopiur-system/kopiur-cache-atlas` (mounted only while the maintenance Job runs) and
any `*-kopia-cache` / `*-src` PVC that belongs to a mover mid-run. Deleting either during a backup
kills that run. The same shape exists in R2 for barman — see
`postgres-dragonfly.md` § Orphaned prefixes are never reclaimed by `retentionPolicy`.

## Prometheus is gone — the old WAL-corruption recipe no longer applies

`kube-prometheus-stack` was replaced by VictoriaMetrics. There is **no** `Prometheus` CR and no
Prometheus pod on this cluster (verified 2026-08-21); the only survivor of the old stack is
`prometheus-adapter`, which stores nothing. The former advice here — "scale down Prometheus, wipe
`/prometheus/prometheus-db/wal/`, scale back up, and never delete individual WAL segments" — is
kept only as history. Do not apply it to `vm-single`: VictoriaMetrics has a different on-disk
layout and its own recovery path, and the leftover 50Gi PVC named for Prometheus is in the orphan
table above, not a live database.
