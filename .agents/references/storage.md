# Reference: Storage — Artemis-Cluster

The entry point for cluster storage: what StorageClasses exist, the NFS media mount, and the PVC
lifecycle — including the orphans nothing reclaims. Read this first, then go sideways:

| File              | Covers                                                        |
| ----------------- | ------------------------------------------------------------- |
| `kopiur.md`       | Backups — repository, component defaults, mover uid, restores |
| `pantheon-zfs.md` | `pantheon`'s ZFS pools — host storage, not Kubernetes storage |

## Storage Classes

| Class          | Backing          | Modes | Binding                | Reclaim  | Notes                                     |
| -------------- | ---------------- | ----- | ---------------------- | -------- | ----------------------------------------- |
| `miroir`       | lvmthin + DRBD9  | RWO   | `WaitForFirstConsumer` | `Delete` | cluster **default**, 2 replicas           |
| `miroir-local` | lvmthin, no DRBD | RWO   | `WaitForFirstConsumer` | `Delete` | 1 replica — kopiur caches, staging clones |

**These two are all that exist** (`kubectl get sc`). Rook-Ceph is gone — `AGENTS.md` § "What was
deliberately removed" is the home for that, and it wins.

**There is no RWX StorageClass.** An app that needs RWX has nothing to ask for — use the NFS mount
below. A PVC naming `ceph-filesystem` sits `Pending` forever.

### Binding mode decides how a restore is driven

Both classes are `volumeBindingMode: WaitForFirstConsumer`.

**This governs POPULATOR restores only — a `Restore` CR handing a volume to a new, unbound PVC.
Those must be driven with the workload scaled back UP;** scaling to 0 and waiting is a deadlock.

**It does not apply to an in-place restore into an existing, bound PVC** — `kopiur restore
--to-pvc <claim>`, which is what `just kube restore-pvc` runs. A bound PVC stays bound when its
consumer scales to 0, and the mover pod is itself the consumer. There you _must_ scale to 0, so
nothing is writing while the data is replaced. The two flows are opposites; pick by whether the
claim already exists.

On a miroir-backed PVC the populator only starts once a pod referencing the PVC is scheduled: the
pod sits `Pending`, that sets the PVC's selected node, the `xbrowsersync-populate` job runs, the
PVC binds, and only then does the pod start. Scaling to 0 and waiting is a deadlock — nothing will
ever happen. Verified during the first miroir migration on 2026-09-05.

## miroir `quorum: freeze` means DRBD `on-no-quorum io-error`

The StorageClass parameter is misleadingly named. `quorum: freeze` does **not** configure
DRBD's freeze/suspend-io — `drbdsetup show` on such a volume prints `on-no-quorum io-error`.
So any momentary quorum dip returns hard I/O errors, ext4 aborts its journal and latches
`emergency_ro` (visible in `/proc/mounts` on kernel 6.15+), and the filesystem stays read-only
**after DRBD has returned to Primary/UpToDate**. Only an unmount+remount clears it.

A momentary quorum dip once took 20 volumes read-only across all seven nodes at once, cascading
postgres → apoci → `registry.dcunha.io` → every Flux OCIRepository pull. Many apps stayed `Running`
while silently discarding writes.

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

**Quorum loss only happens on the worker nodes.** They hold diskless legs — the `nvme` pool is
control-plane-only — so their quorum depends entirely on the network to cp-01/02/03.

## miroir alerts — which ones are structural here

`MiroirVolumeRemoteConsumer` is **disabled** via `monitoring.prometheusRule.overrides` on the miroir
chart, and additionally blackholed by alertname in Alertmanager. Do not re-enable it.

**The exposure is real; this alert cannot report it.** It is true of ~30 volumes permanently, so it
never transitions and can never mark an event. That makes it an inventory, and an inventory is a
PromQL query, not an alert — `miroir_volume_diskless_primary == 1` in VictoriaMetrics returns the
same list on demand. Blackholing alone was not enough: `siren` renders Alertmanager's whole alert
list, so receiver routing governs delivery, not membership. The blackhole route is kept as a
backstop so a future re-enable cannot page. Its suggested remedy (`autoDiskfulAfter`) cannot apply
here: a diskful replica needs the volume's pool on that node, and `nvme` exists only on the three
control planes.

**There is no direct detector for a diskless leg dropping.** A diskless leg exports only
`miroir_volume_diskless_primary`, and `miroir_volume_connected` never moves when a client leg drops.
`node_filesystem_readonly` would catch the `emergency_ro` latch, but node-exporter's default
`--collector.filesystem.mount-points-exclude` drops `/var/lib/kubelet/pods/.+`, so no `/dev/drbd*`
mount is scraped. Narrowing that exclusion is the real fix if this failure mode recurs.

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

## Orphaned PVCs — nothing reclaims them, and they are replicated

Deleting a HelmRelease, a StatefulSet, or migrating an app off its own database leaves the PVC
behind. Both classes have `reclaimPolicy: Delete`, but that only fires when the **PVC** is deleted —
an unreferenced PVC is not garbage, it is just idle, and Kubernetes will hold it forever. The
`nvme` pool is small (control planes only), and every idle gibibyte on `miroir` costs one per
replica. `kubectl get sc miroir -o jsonpath='{.parameters}'` is the live replica count — do not
trust one written in prose.

The earlier audit is [#1889](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/1889). Match a
suspect claim to its live workload by the claim name the workload actually mounts, not by a shared
prefix — a renamed workload owns a differently named claim.

**Known orphan: `forgejo/exikle-pvc-setup-c77f6`** — `Bound`, no `ownerReferences`, no pod mounts
it, created by the current runner. It contradicts the ownerReference claim below; tracked in
[#2765](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2765).

**`exikle-pvc-setup-<suffix>` is recurring litter, and there is no Job.** It is the workspace that
`forgejo-tekton-runner`'s `tekton/setup@v0` action provisions per workflow run. The name is
`generateName: exikle-pvc-setup-`, unique per run **by design** — `RUNNER_CAPACITY: 6` means six runs
can be in flight, each needing its own RWO workspace. A stable claim name would serialise or corrupt
CI. Do not "fix" it to a fixed name. `.forgejo/workflows/oci-push.yaml` binds its own `source`
workspace to an `emptyDir`, so the claim comes from the runner, not from that file.

The PVC carries an `ownerReference` to its PipelineRun and the runner deletes it explicitly, ~2
minutes after the run ends. **What stalls it is `kubernetes.io/pvc-protection`.** That controller
only ignores pods that are being deleted, not pods in a terminal phase — so the run's own
`Succeeded` TaskRun pods keep holding the claim, and it sits in `Terminating`. Confirm rather than
guess:

```bash
kubectl describe pvc -n forgejo <claim> | grep -A2 'Unused'
# Unused  False  ...  PodUsingPVC  A pod is currently referencing this PVC
```

Only the Tekton operator pruner removing the TaskRuns deletes those pods
(`kubernetes/apps/tekton-system/tekton-operator/app/tektonconfig.yaml`). So the pruner's `schedule`
— not its `keep` — bounds the litter. `keep` is a retention floor, so tightening the schedule costs
no log history; raising `keep` costs volumes, since each run is several TaskRuns.

A `Bound` claim that survives days is a different failure. Claims normally carry an
`ownerReference` to their PipelineRun and are garbage-collected with it, but at least one has
none (#2765). If one appears, check `.metadata.ownerReferences` before assuming the above
explains it.

Find orphans with a pod-volume diff, never by eyeballing `kubectl get pvc` — a bound PVC with no
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
kills that run. The same shape exists in R2 for barman — see `postgres-dragonfly.md` § Orphaned
prefixes are never reclaimed by `retentionPolicy`.
