# Reference: Storage — Artemis-Cluster

The entry point for cluster storage: what StorageClasses exist, the NFS media mount, and the PVC
lifecycle — including the orphans nothing reclaims. Read this first, then go sideways:

| File                         | Covers                                                        |
| ---------------------------- | ------------------------------------------------------------- |
| `kopiur.md`                  | Backups — repository, component defaults, mover uid, restores |
| `osd-topology-2026-08-21.md` | Dated capacity/redundancy evaluation behind the OSD rules     |
| `pantheon-zfs.md`            | `pantheon`'s ZFS pools — host storage, not Kubernetes storage |

## Storage Classes

| Class          | Backing          | Modes | Binding                | Reclaim  | Notes                                     |
| -------------- | ---------------- | ----- | ---------------------- | -------- | ----------------------------------------- |
| `miroir`       | lvmthin + DRBD9  | RWO   | `WaitForFirstConsumer` | `Delete` | cluster **default**, 2 replicas           |
| `miroir-local` | lvmthin, no DRBD | RWO   | `WaitForFirstConsumer` | `Delete` | 1 replica — kopiur caches, staging clones |

**These two are all that exist.** Rook-Ceph was removed in `b9008ac55`: there is no `ceph-block`,
no `ceph-filesystem`, no `CephCluster` or `CephFilesystem` CRD. `kubectl get sc` is the live
answer and it is short.

**There is no RWX StorageClass.** An app that needs RWX has nothing to ask for — use the NFS
mount above. A PVC naming `ceph-filesystem` (older docs and skills still do) sits `Pending`
forever with `storageclass.storage.k8s.io "ceph-filesystem" not found`.

### Binding mode decides how a restore is driven

Both classes are `volumeBindingMode: WaitForFirstConsumer`.

**Both classes are `WaitForFirstConsumer`, so every restore is driven the same way: the workload
must be scaled back UP.** Scaling to 0 and waiting is a deadlock.

On a miroir-backed PVC the populator only starts once a pod referencing the PVC is scheduled: the
pod sits `Pending`, that sets the PVC's selected node, the `xbrowsersync-populate` job runs, the
PVC binds, and only then does the pod start. Scaling to 0 and waiting is a deadlock — nothing will
ever happen. Verified during the first miroir migration on 2026-09-05.

This is the same rule Frostlink's `openebs-zfs` has always had. It did not apply on Artemis while
`ceph-block` (`Immediate`) existed, which is why older restore notes say to scale to 0 — that
advice is now a deadlock, not a shortcut.

## miroir `quorum: freeze` means DRBD `on-no-quorum io-error`

The StorageClass parameter is misleadingly named. `quorum: freeze` does **not** configure
DRBD's freeze/suspend-io — `drbdsetup show` on such a volume prints `on-no-quorum io-error`.
So any momentary quorum dip returns hard I/O errors, ext4 aborts its journal and latches
`emergency_ro` (visible in `/proc/mounts` on kernel 6.15+), and the filesystem stays read-only
**after DRBD has returned to Primary/UpToDate**. Only an unmount+remount clears it.

On 2026-09-09 this took 20 volumes read-only across all seven nodes at once, cascading
postgres → apoci → `registry.dcunha.io` → every Flux OCIRepository pull. Many apps stayed
`Running` while silently discarding writes.

The default class is now `quorum: last-man-standing`, which configures no `on-no-quorum`
action at all. Verify a volume with:

```bash
kubectl exec -n miroir-system <miroir-agent> -c agent -- drbdsetup show <pv> | grep on-no-quorum
```

No output = last-man-standing. `on-no-quorum io-error` = still on the old setting, and the
volume must be recreated (`.agents/skills/recreate-pvc/SKILL.md`) — StorageClass parameters
are immutable and baked in at provision time.

miroir exposes only `freeze` and `last-man-standing`; there is no `suspend-io` option.
`nklmilojevic/home` runs an identical topology and differs from ours in this one parameter.

**Quorum loss only ever happens on the worker nodes.** They hold diskless legs — the `nvme`
pool is control-plane-only — so their quorum depends entirely on the network to cp-01/02/03.
The three storage nodes recorded zero quorum-loss events during the incident; the four
workers recorded 37.

## miroir alerts — which ones are structural here

`MiroirVolumeRemoteConsumer` is **disabled** via `monitoring.prometheusRule.overrides` on the
miroir chart. It fires whenever a pod consumes a replicated volume from a node holding no replica
— which on a 3-storage-node / 4-diskless-worker topology is the normal, permanent state, not an
event. It sat at 25-31 firing instances indefinitely. Its own suggested remedy (`autoDiskfulAfter`)
cannot apply: converting a client leg to a diskful replica needs the volume's pool on that node,
and the `nvme` pool exists only on the three control planes.

`MiroirVolumeOutOfSync` is deliberately left alone despite being noisy. Its rule is
`miroir_volume_out_of_sync_bytes > 0`, so it trips on a few KiB of ordinary write-in-flight lag —
but it is also the only thing that caught a genuinely stalled resync. **Read `peer-disk-state`
before reacting**: `UpToDate` means both copies are good and the count is stale bitmap bits;
`Inconsistent` means that leg really is missing data. A byte floor would be the right fix, but the
chart's `overrides` accept only `disabled`, `for` and `labels` — not `expr`.

`MiroirPoolUsageHigh` for `pool=client` is routed to blackhole in the Alertmanager config: a
loopfile pool reports the node's root filesystem, and those pools hold no replicas at all.

## NFS Media Mount

- **Server**: `10.10.99.100` (TrueNAS `atlas`)
- **Path**: `/mnt/atlas/media` → mounted at `/media` in pods
- **Usable**: ~41TB (3× RAIDZ2)

## Orphaned PVCs — nothing reclaims them, and they are 2× replicated

Deleting a HelmRelease, a StatefulSet, or migrating an app off its own database leaves the PVC
behind. Both classes have `reclaimPolicy: Delete`, but that only fires when the **PVC** is deleted —
an unreferenced PVC is not garbage, it is just idle, and Kubernetes will hold it forever. The
`nvme` pool is ~709 GiB raw (3 × 236 GiB on the control planes), so at the current `replicas: 2`
every idle gibibyte costs two.

All seven orphans catalogued here were **reclaimed on 2026-09-01** — see
[#1889](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/1889) for the full audit. There is
currently **no known orphaned PVC**. Verified by pod-volume diff immediately before and after
deletion, with every backing PV reclaimed.

**The replica count moved.** `miroir` was `replicas: 3` when that audit ran and the arithmetic
above was written against it; `7d5e4f2ab` dropped the default class to 2. `kubectl get sc miroir
-o jsonpath='{.parameters}'` is the live answer — do not trust a replica count written in prose
here or anywhere else.

What was deleted, and what left it behind — kept because the same migrations will recur:

| PVC                                                                    | Size | Left behind by                          |
| ---------------------------------------------------------------------- | ---- | --------------------------------------- |
| `observability/prometheus-kube-prometheus-stack-db-prometheus-…-0`     | 50Gi | kube-prometheus-stack → VictoriaMetrics |
| `observability/alertmanager-kube-prometheus-stack-db-alertmanager-…-0` | 1Gi  | same                                    |
| `observability/config-gatus-0`                                         | 5Gi  | gatus → `gatus-sidecar` (see note)      |
| `media/data-streamystats-vectorchord-0`                                | 10Gi | streamystats → shared CNPG Postgres     |
| `media/data-rreading-glasses-postgres-0`                               | 5Gi  | per-app Postgres retired                |
| `tekton-system/postgredb-tekton-results-postgres-0`                    | 1Gi  | tekton-results Postgres retired         |
| `forgejo/exikle-pvc-setup-<suffix>`                                    | 1Gi  | tekton-runner workspace — see note      |

If a new orphan is found, add it to a fresh table here — this remains the single inventory in the
repo, so do not start a second one elsewhere.

**Two rows that read as false positives and were not.** Both were nearly mis-triaged on 2026-09-01,
and the same collisions will reappear:

- **`config-gatus-0` did not mean gatus was gone.** `gatus-sidecar` is the current, running
  deployment (`kubernetes/apps/observability/gatus-sidecar`) and it has its **own** 5Gi claim named
  `gatus-sidecar`, which was mounted and correctly left alone. `config-gatus-0` (171d) was the
  pre-rename StatefulSet claim. Checking `find kubernetes -ipath '*gatus*'` rather than
  `kubernetes/apps/observability/gatus-sidecar` is what distinguishes them.
- **The two `kube-prometheus-stack` rows collided by name with live workloads.** `prometheus-adapter`
  runs but is a different component and uses no PVC; `alertmanager-0` runs but mounts a claim simply
  named `alertmanager`. Neither live workload touched the `*-kube-prometheus-stack-*` claims.

**The forgejo row is recurring litter, and there is no Job.** `exikle-pvc-setup-<suffix>` is the
`source` workspace that `forgejo-tekton-runner`'s `tekton/setup@v0` action provisions per workflow
run, from the `volumes:` block in `.forgejo/workflows/oci-push.yaml`. The name is
`generateName: exikle-pvc-setup-`, and it is unique per run **by design** — `RUNNER_CAPACITY: 6`
means six runs can be in flight, each needing its own RWO workspace. A stable claim name would
serialise or corrupt CI. Do not "fix" it to a fixed name.

The runner already does the right thing: the PVC carries an `ownerReference` to its PipelineRun and
the runner deletes it explicitly, ~2 minutes after the run ends. **What stalls it is
`kubernetes.io/pvc-protection`.** That controller only ignores pods that are being deleted, not pods
in a terminal phase — so the run's own `Succeeded` TaskRun pods keep holding the claim. The PVC sits
in `Terminating` with a live RBD image behind it, costing 3× its size at `size=3`. Confirm it rather
than guessing:

```bash
kubectl describe pvc -n forgejo <claim> | grep -A2 'Unused'
# Unused  False  ...  PodUsingPVC  A pod is currently referencing this PVC
```

Nothing releases it until those pods are deleted, and the only thing that deletes them is the Tekton
operator pruner removing their TaskRuns (`kubernetes/apps/tekton-system/tekton-operator/app/tektonconfig.yaml`).
So the pruner's `schedule` — not its `keep` — is what bounds the litter: between prune runs the
claims accumulate without a cap. `keep: 50` on a daily schedule pinned ~5 volumes for up to 24h;
`keep: 20` every 4h still let nine pile up by the 2026-09-01 sweep. It runs every 15 minutes as of
2026-09-02, which caps the pile at a quarter-hour of CI.

`keep` is a retention floor, so tightening the schedule costs no log history. Raising `keep` does
cost volumes: one `oci-push` is 10 TaskRuns, so `keep: 20` is only the last two runs' pods.

The 4Gi `Bound` claim seen on 2026-08-21 and 2026-09-01 is a **different, older** failure — the
current runner sets an `ownerReference`, so a claim whose PipelineRun is pruned is garbage-collected
outright. A genuinely `Bound` orphan surviving days means it predates that behaviour. If one appears
again, check `.metadata.ownerReferences` before assuming this section explains it.

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
