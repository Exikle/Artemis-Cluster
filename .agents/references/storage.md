# Reference: Storage — Artemis-Cluster

This file is the entry point for cluster storage. It covers the StorageClasses, the NFS media mount, and the PVC lifecycle, including the orphans that nothing reclaims. Read this file first, then go to these files:

| File              | Covers                                                        |
| ----------------- | ------------------------------------------------------------- |
| `kopiur.md`       | Backups — repository, component defaults, mover uid, restores |
| `pantheon-zfs.md` | `pantheon`'s ZFS pools — host storage, not Kubernetes storage |

## Storage Classes

| Class          | Backing          | Modes | Binding                | Reclaim  | Notes                                     |
| -------------- | ---------------- | ----- | ---------------------- | -------- | ----------------------------------------- |
| `miroir`       | lvmthin + DRBD9  | RWO   | `WaitForFirstConsumer` | `Delete` | cluster **default**, 2 replicas           |
| `miroir-local` | lvmthin, no DRBD | RWO   | `WaitForFirstConsumer` | `Delete` | 1 replica — kopiur caches, staging clones |

These two classes are all that exist (`kubectl get sc`). Rook-Ceph is gone. `AGENTS.md` § "What was deliberately removed" covers that, and it wins.

There is no RWX StorageClass. An app that needs RWX has nothing to ask for, so use the NFS mount below. A PVC that names `ceph-filesystem` stays `Pending` forever.

### Binding mode decides how a restore is driven

Both classes use `volumeBindingMode: WaitForFirstConsumer`.

This applies to POPULATOR restores only. A populator restore is a `Restore` CR that hands a volume to a new, unbound PVC. You must drive these restores with the workload scaled back UP. If you scale to 0 and wait, the restore deadlocks.

It does not apply to an in-place restore into an existing, bound PVC. That restore is `kopiur restore
--to-pvc <claim>`, which `just kube restore-pvc` runs. A bound PVC stays bound when its consumer scales to 0, and the mover pod is itself the consumer. For this restore you _must_ scale to 0, so that nothing writes while the data is replaced. The two flows are opposites. Pick the flow by whether the claim already exists.

On a miroir-backed PVC, the populator starts only after a pod that references the PVC is scheduled. The sequence is:

1. The pod sits `Pending`.
2. That sets the selected node of the PVC.
3. The `xbrowsersync-populate` job runs.
4. The PVC binds.
5. The pod starts.

If you scale to 0 and wait, nothing ever happens. This was verified during the first miroir migration on 2026-09-05.

## miroir `quorum: freeze` means DRBD `on-no-quorum io-error`

The name of the StorageClass parameter is misleading. `quorum: freeze` does **not** configure the freeze/suspend-io action of DRBD. `drbdsetup show` on such a volume prints `on-no-quorum io-error`. So any momentary quorum dip returns hard I/O errors. ext4 aborts its journal and latches `emergency_ro` (visible in `/proc/mounts` on kernel 6.15+). The filesystem stays read-only **after DRBD has returned to Primary/UpToDate**. Only an unmount and remount clears it.

A momentary quorum dip once took 20 volumes read-only across all seven nodes at once. The failure cascaded from postgres to apoci to `registry.dcunha.io` to every Flux OCIRepository pull. Many apps stayed `Running` while they silently discarded writes.

The default class is now `quorum: last-man-standing`, which configures no `on-no-quorum` action at all. To check a volume, run:

```bash
kubectl exec -n miroir-system <miroir-agent> -c agent -- drbdsetup show <pv> | grep on-no-quorum
```

No output = last-man-standing. `on-no-quorum io-error` = the volume is still on the old setting. You must recreate it (`.agents/skills/recreate-pvc/SKILL.md`), because StorageClass parameters are immutable and are set when the volume is provisioned.

miroir exposes only `freeze` and `last-man-standing`. It has no `suspend-io` option. `nklmilojevic/home` runs an identical topology and differs from ours in this one parameter.

Quorum loss happens only on the worker nodes. They hold diskless legs, because the `nvme` pool is control-plane-only. Their quorum depends entirely on the network to cp-01/02/03.

## miroir alerts — which ones are structural here

`MiroirVolumeRemoteConsumer` is **disabled** through `monitoring.prometheusRule.overrides` on the miroir chart. Alertmanager also blackholes it by alertname. Do not re-enable it.

The exposure is real, but this alert cannot report it. It is true of about 30 volumes permanently, so it never transitions and can never mark an event. That makes it an inventory, and an inventory is a PromQL query, not an alert. The query `miroir_volume_diskless_primary == 1` in VictoriaMetrics returns the same list on demand. Blackholing alone was not enough, because `siren` renders the whole alert list of Alertmanager. Receiver routing governs delivery, not membership. The blackhole route stays as a backstop, so a future re-enable cannot page. The remedy that the alert suggests (`autoDiskfulAfter`) cannot apply here. A diskful replica needs the pool of the volume on that node, and `nvme` exists only on the three control planes.

No direct detector exists for a diskless leg that drops. A diskless leg exports only `miroir_volume_diskless_primary`, and `miroir_volume_connected` never moves when a client leg drops. `node_filesystem_readonly` would catch the `emergency_ro` latch. But the default `--collector.filesystem.mount-points-exclude` of node-exporter drops `/var/lib/kubelet/pods/.+`, so no `/dev/drbd*` mount is scraped. If this failure mode recurs, the real fix is to narrow that exclusion.

`MiroirVolumeOutOfSync` is deliberately left alone, although it is noisy. Its rule is `miroir_volume_out_of_sync_bytes > 0`, so it trips on a few KiB of ordinary write-in-flight lag. But it is also the only alert that caught a genuinely stalled resync. Read `peer-disk-state` before you react. `UpToDate` means both copies are good and the count is stale bitmap bits. `Inconsistent` means that leg really is missing data. A byte floor would be the right fix, but the `overrides` of the chart accept only `disabled`, `for` and `labels`, not `expr`.

The Alertmanager config routes `MiroirPoolUsageHigh` for `pool=client` to blackhole. A loopfile pool reports the root filesystem of the node, and those pools hold no replicas at all.

## NFS Media Mount

- **Server**: `10.10.99.100` (TrueNAS `atlas`)
- **Path**: `/mnt/atlas/media` → mounted at `/media` in pods
- **Usable**: ~41TB (3× RAIDZ2)

## Orphaned PVCs — nothing reclaims them, and they are replicated

If you delete a HelmRelease or a StatefulSet, or migrate an app off its own database, the PVC stays behind. Both classes have `reclaimPolicy: Delete`, but that fires only when someone deletes the **PVC**. An unreferenced PVC is not garbage. It is idle, and Kubernetes holds it forever. The `nvme` pool is small (control planes only), and every idle gibibyte on `miroir` costs one gibibyte per replica. `kubectl get sc miroir -o jsonpath='{.parameters}'` gives the live replica count. Do not trust a count written in prose.

The earlier audit is [#1889](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/1889). Match a suspect claim to its live workload by the claim name that the workload actually mounts. Do not match by a shared prefix, because a renamed workload owns a claim with a different name.

Claims named `exikle-pvc-setup-*`, and retained `lint`/`grype` cache claims in `forgejo`, are Tekton-era leftovers. The Tekton runner that provisioned and reaped them was retired on 2026-10-27 (`ci.md`). The plain runner uses emptyDirs and the actions cache. Any such claim that is still present is an orphan, and you can delete it safely.

Find orphans with a pod-volume diff. Do not look at `kubectl get pvc` by eye, because a bound PVC with no consumer looks identical to a healthy one:

```bash
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $n
  | .spec.volumes[]? | select(.persistentVolumeClaim) | "\($n)/\(.persistentVolumeClaim.claimName)"' \
  | sort -u > /tmp/used
kubectl get pvc -A --no-headers -o custom-columns=A:.metadata.namespace,B:.metadata.name \
  | awk '{print $1"/"$2}' | sort -u | comm -23 - /tmp/used
```

Before you delete anything, check the list against a live restore. Two entries legitimately have no consumer. One is `kopiur-system/kopiur-cache-atlas`, which is mounted only while the maintenance Job runs. The other is any `*-kopia-cache` or `*-src` PVC that belongs to a mover in the middle of a run. If you delete either during a backup, you kill that run. The same shape exists in R2 for barman. See `postgres-dragonfly.md` § Orphaned prefixes are never reclaimed by `retentionPolicy`.
