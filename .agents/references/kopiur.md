# Reference: kopiur — Artemis-Cluster

This file covers backups: the kopiur operator, `ClusterRepository/atlas` on NFS, the component
defaults, the mover uid and cache budgets, how restores behave, and the conditions that look broken
but are not. It covers backup and restore only. The StorageClass and VolumeSnapshotClass that the
movers consume are in `storage.md`.

Frostlink runs the same operator against a different backend. Its counterpart is in
`frostlink/.agents/references/storage.md` § kopiur. This file deliberately mirrors that one, so
drift between the two clusters is a one-file diff. The differences below are intentional: the
retention, the substitute var, and `usernameExpr`. They follow from NFS on a 41 TB array here
versus a metered R2 bucket there. Do **not** "align" them by copying the setting of one repo onto
the other. Read both files first.

## kopiur

VolSync is gone. `AGENTS.md` § "What was deliberately removed" is the home for that, and it wins.
Every backed-up app uses kopiur against `ClusterRepository/atlas` (NFS
`10.10.99.100:/mnt/atlas/Kopiur`). `grep -rln 'components/kopiur/backup' kubernetes/apps/` lists
them. The old VolSync kopia repo remains on the NAS at `atlas/VolsyncKopia` as a frozen historical
fallback. To restore from it, you need a manual kopia client.

These are the component defaults (`components/kopiur/backup/`). No manifest states them in one place:

| Setting        | Default                                                | Override var                                              |
| -------------- | ------------------------------------------------------ | --------------------------------------------------------- |
| Schedule       | `H * * * *` (hourly)                                   | none — edit the component or the app's `SnapshotSchedule` |
| Retention      | 5 latest / 24 hourly / 30 daily / 8 weekly / 6 monthly | none — edit the component                                 |
| `copyMethod`   | `Snapshot` (VolumeSnapshot clone)                      | —                                                         |
| Compression    | `zstd`                                                 | —                                                         |
| PVC capacity   | `5Gi`                                                  | `KOPIUR_CAPACITY`                                         |
| StorageClass   | `miroir`                                               | `KOPIUR_STORAGECLASS` (app PVC only)                      |
| Staging class  | `miroir-local`                                         | `KOPIUR_STAGING_STORAGECLASS`                             |
| Snapshot class | `miroir`                                               | `KOPIUR_SNAPSHOTCLASS`                                    |
| Mover uid/gid  | `1000` / `1000`                                        | `KOPIUR_PUID` / `KOPIUR_PGID`                             |
| Access modes   | `ReadWriteOnce`                                        | `KOPIUR_ACCESSMODES`                                      |

The retention here is deeper than the retention of Frostlink on purpose. Frostlink keeps 3 latest /
24 hourly / 7 daily / 4 weekly / 3 monthly against a metered R2 bucket. Artemis backs up to NFS on
a 41 TB array, so it keeps 30 daily and 6 monthly. Do not "align" the two, because the backends
have different prices.

The substitute var is `${APP}`, not `${KOPIUR_APP}`. The component of Frostlink uses `${KOPIUR_APP}`.
The component of Artemis uses `${APP}`, which `components/postgres/app` now also uses as its default
(`${PG_APP:=${APP}}`). Set `PG_APP` only when the database name differs. If you copy a
`postBuild.substitute` block between the two repos, a var silently stays unsubstituted.

The kopia source identity is `<policy>@<namespace>:/pvc/<pvc>`. The `identityDefaults` on
`ClusterRepository/atlas` are `usernameExpr: policyName` and `hostnameExpr: namespace`. The
`usernameExpr` of Frostlink is `namespace + '-' + policyName`, so identities are **not** portable
between the two repositories. If you rename a policy, it starts a fresh snapshot lineage and orphans
the old lineage, with nothing to prune it.

### Retiring an app does not purge its backups

If you delete the Flux Kustomization of an app, it orphans the kopia lineage of the app. It does not
delete the lineage. Pruning the `SnapshotPolicy` or `SnapshotSchedule` does cascade to the child
`Snapshot` CRs through ownerReference GC, so they vanish from `kubectl get` and it looks done. It is
not done. The controller runs that cascade as `plan=RetainSnapshotOnScheduleDelete` or
`RetainSnapshotOnPolicyDelete` (`mode=Retain`). The snapshots stay in the repository with no policy
left to prune them.

To purge, delete the `Snapshot` CRs explicitly, **before** you delete the Kustomization:

```bash
kubectl delete snapshots.kopiur.home-operations.com -n <ns> -l kopiur.home-operations.com/config=<app>
```

That path honors `spec.deletionPolicy: Delete` and the `kopiur.home-operations.com/snapshot-cleanup`
finalizer. The finalizer queues the repo-side `SnapshotDeleteBatch` job. The `MassDeletionHeld`
breaker on `ClusterRepository/atlas` trips above 10 pending external destructive deletions, so a
long lineage needs batching.

The order is the whole trick, and you cannot recover from a wrong order. After the CRs are gone, you
cannot re-attach the snapshots. The `Snapshot` CRD builds a new snapshot from a PVC source and has
no adopt or import field. The only remaining route is a manual kopia client against the repository.
The team learned this when it retired `home-automation/node-red` on 2026-09-08. It left the 56
snapshots of that app behind deliberately, rather than purge them by hand.

`status.storageStats.snapshotCount` on the ClusterRepository is **not** a check for any of this.
`status.catalog.lastRefreshAt` lags by up to `catalog.refreshInterval` (1h), so the number stays
stale for an hour. Read the `kopiur-controller` logs instead.

- Reference the component in `ks.yaml` components: `../../../../components/kopiur/backup`
- Set the PVC size in the `ks.yaml` postBuild substitute `KOPIUR_CAPACITY`, **not** in app manifests.
- Each backed-up namespace also needs `../../components/kopiur/secret` in its namespace
  kustomization. The mover reads the repo password from its OWN namespace (`envFrom` is
  namespace-local), so the Secret name is fixed and cannot be per-app.
- In the HelmRelease, the PVC is `existingClaim: <app>`.
- Mover uid: It defaults to 1000. Override it with `KOPIUR_PUID` and `KOPIUR_PGID` **only when
  something else owns the on-disk data of the app**. Read the actual ownership. Never trust the
  `fsGroup` of the pod, because it misleads: apoci reported 999 but its data was 1000, and pocket-id
  reported 65534 but its data was 1000. With `copyMethod: Snapshot`, the source clone is mounted
  read-only, so the kubelet cannot chgrp it, and a mismatched mover just gets permission denied. The
  `fsGroup` of the mover also owns the cache PVC, which the mover must be able to write. To list the
  apps that override the uid, run `grep -rn KOPIUR_PUID kubernetes/apps/`. `cortex/hermes` sets 10000. Its image only runs non-root as that uid, and its data was re-owned to match (`hermes.md`
  § Run as uid 10000).
- `kopiur-system` pulls in `components/kopiur/secret` too. The operator reads the repository
  password to connect, and maintenance movers run in that namespace. The repository child ks wires
  it, not the namespace kustomization, so that `just kube apply-ks` can still test it.
- `restore.yaml` must mirror the mover identity of the SnapshotPolicy. Otherwise a restore writes
  files as 1000 regardless of the uid of the app, and the app cannot open its own data.
- A `Restore` is one-shot and terminal by design. Upstream says: _"a Restore is one-shot — fix the
  cause and create a new Restore"_. If you edit a completed one, it sits at
  `generation != observedGeneration` forever, kstatus reports InProgress, and any `wait: true`
  Kustomization hangs for the full timeout in every cycle.
- The interface is delete-and-recreate, not edit. When the rendered spec of a Restore changes
  (`KOPIUR_PUID`/`KOPIUR_PGID`, storageclass, anything), delete the CR and let Flux recreate it. If
  you recreate a populator Restore over a **bound** PVC, nothing happens. This is documented. The
  Restore completes as `Ready=True reason=TargetAlreadyBound` with no mover run, and the live volume
  is untouched. The CR has no finalizers and no ownerReferences, so deleting one cannot cascade.
- Do not recreate a Restore to pick up a newer snapshot on a bound PVC, because it does not work. A
  populator hands a volume only to an _unbound_ claim, and the source snapshot is pinned to
  `status.resolved` at first resolution. To re-restore, delete the **PVC** (keep its
  `dataSourceRef`) and let it be re-created. To re-resolve to a newer snapshot, delete and re-create
  the `Restore`.
- `restore.yaml` carries no `kustomize.toolkit.fluxcd.io/ssa: ignore`. Do not re-add it. Flux skips
  such objects entirely, so Flux would never create a Restore. `restore.yaml` keeps
  `mover.cache.mode: Ephemeral` and the mover identity block, which is load-bearing for every app
  that overrides the uid.
- `just kube apply-ks` overwrites a hand-created `Restore` with the rendered one. For any
  cross-policy restore (a rename, or recovering the data of one app into another app), set
  `onMissingSnapshot: Fail`. Then a bad source resolution fails loudly instead of silently binding
  an empty volume. The default is `Continue`. Create both the `Restore` and the PVC by hand, and do
  not let `apply-ks` create the PVC.

### The kopia web UI is deliberately removed (2026-08-09)

`ClusterRepository/atlas` no longer sets `spec.server`, and the standalone `httproute.yaml` for
`kopiur.dcunha.io` is deleted. Do **not** re-add it as a "missing" route. The operator creates the
Service from `spec.server`, so the route exists only when the UI does.

The user asked for the removal. Almost nobody used the UI, and its pod had been restarting (25× in
12h, all clean `exit=0`). The removal was also cheap for a security reason. The server pod holds the
repository **decryption key** even in `readOnly: true` mode. That is why its Service was ClusterIP
and internal-gateway-only in the first place.

To inspect the repository without the UI, use `kopiur status -n <ns>` and `kopiur doctor -n <ns>`.

### Mover cache budgets — `contentCacheSizeMb` / `metadataCacheSizeMb` are mandatory

Set them on `ClusterRepository/atlas`. Without them, the maintenance mover fills its cache PVC, and
every run fails with `no space left on device`. This first happened on 2026-08-09, when the
full-maintenance job had been failing for about 53 min.

The own defaults of kopia are **5000 MB content + 5000 MB metadata**, so a 5Gi cache PVC cannot hold
even the content cache alone. Observed on the full 5Gi `kopiur-cache-atlas`: `cache/contents` 4.0G,
`logs/` 359M (`content-logs` 346M, which is also unbounded, and kopiur has no knob for log
retention), `cache/metadata` 295M, and `cache/index-blobs` 170M. The connect then fails when it
writes `repository.config`, and the surfaced error is misleading. `Cannot determine current user: user:
Current requires cgo or $USER set in environment` appears _above_ the real cause in the mover log.
Read past it to the `no space left on device` lines.

The budgets must leave headroom for logs on top of the two caches:

| Scope                     | mode         | capacity        | content | metadata | headroom |
| ------------------------- | ------------ | --------------- | ------- | -------- | -------- |
| `moverDefaults.cache`     | `Ephemeral`  | none (emptyDir) | 2000 MB | 1000 MB  | node     |
| `maintenance.mover.cache` | `Persistent` | 10Gi            | 3000 MB | 4000 MB  | ~3.2Gi   |

The per-app mover cache is an `emptyDir`, not a PVC (2026-09-07). An `Ephemeral` cache with no
`capacity` is a node-local `emptyDir`. `capacity` is the only thing that makes kopiur provision a
claim. So the `SnapshotPolicy` in the component has no `mover.cache` block and inherits
`moverDefaults`: mode, budgets, and no capacity. That stops one `miroir-local` volume per run across
every hourly policy. `restore.yaml` keeps only `mover.cache.mode: Ephemeral`, with no capacity.

A per-recipe `mover.cache` silently defeats the repository default, because `MoverSpec` overlays
`MoverDefaults` field by field and the recipe wins. When the team removed `capacity` from
`moverDefaults` alone, nothing changed, because the component still set `capacity: 5Gi`, and the
cache PVCs kept being created. Change both, or change the component.

`storageClassName` on a cache with no `capacity` has no effect, because there is no PVC to place.
For that reason, the component has no cache storage-class variable.

Maintenance gets its own larger override, because full maintenance compacts index blobs and is
bound by metadata. It is the only kopiur cache that survives between runs, so it is the only cache
that can fill.

An ephemeral cache is regenerable, and kopiur discards it every run anyway. The persistent
maintenance cache is equally safe to clear. Delete `kopiur-system/kopiur-cache-atlas` and let kopiur
recreate it.

### Mover placement is the scheduler's job, not kopiur's (2026-09-07)

`miroir-local` is `replicas: 1` on the `nvme` pool, and that pool exists only on the three control
planes. Nothing told the scheduler this. It would place a mover on a worker, miroir would place the
staged PVC elsewhere in the pool, and the pod could never bind, because the node affinity of a PV is
immutable. The team verified this on `matter-server-20260907054400`: both PVCs were annotated
`selected-node: talos-w-01`, with the PVs on `talos-cp-03` and `talos-cp-01`.

The fix is `storageCapacity.enabled: true` on the **miroir** chart, not a kopiur nodeSelector. When
the chart publishes `CSIStorageCapacity`, the scheduler treats a `(node, class)` pair with no
capacity as unfit. Live values show `miroir-local` at 0 on all four workers and about 173 GB on the
three storage nodes. `miroir` (replicated, remotely consumable) stays available everywhere. The fix
constrains only pods that actually claim from such a class.

The team tried `moverDefaults.nodeSelector` first and reverted it. It applies repository-wide.
`SnapshotPolicy.spec.mover` has no scheduling fields to override it per app. It would also pin a
`copyMethod: Direct` mover away from the workload that the mover has to co-locate with.

Cost: After an agent restart, a `WaitForFirstConsumer` pod waits up to `agent.poolStatsInterval`
(60s) for fresh capacity stats before it can schedule.

### `copyMethod: Direct` was evaluated and rejected

Direct mounts the live PVC, with no VolumeSnapshot and no staged PVC. Do not re-propose it.

- The churn that it removes is cheap. A `replicas: 1` miroir volume has no DRBD layer. It is a plain
  lvmthin volume, and staging already moved to `miroir-local`.
- Direct is a crash-consistent live read, so it reads a database file and its `-wal` moments apart.
  Many backed-up PVCs hold a database, and several are in WAL mode (`komga`, `hermes`, `frigate`,
  `jellyfin`, `qbittorrent`, `seerr`, `rensaio`). A connection to Postgres does not mean that the
  PVC has no secondary database.
- Scanning trap: `find -printf` is GNU-only, and busybox exits silently (which reads as clean).
  `find / -xdev` never enters a PVC. Derive the mountPath from the pod spec and scan that path.

### `IndexBlobHealth: False` is a warning about index size, not a broken repository

The repository sets `spec.health.indexBlobWarnThreshold: 4000` (the default is 1000), which keeps
`IndexBlobHealth` at `Healthy`. Suppose it flips to `False / TooManyIndexBlobs` while `Ready=True`.
Backups are not failing. Check `SnapshotPolicy.status.lastSuccessfulSnapshot`, which is the signal
that matters.

Mechanism: kopia compacts index blobs only two epochs behind the current one, and an epoch cannot
close before `spec.parameters.epoch.minDuration` (`6h` here, and the kopia default is 24h). If the
count is genuinely climbing, take these steps in order. First, confirm that the maintenance Job is
running. Then, if the Job is stuck on a stale lease owner, set `spec.maintenance.takeoverPolicy:
Force` **once**. Then lower `epoch.minDuration` further. Raising the threshold only silences the
signal.

`toggle-kopiur` pauses the controller, not everything in kopiur. It deliberately leaves two things
alone. The first is `kopiur-webhook`: its Validating/MutatingWebhookConfiguration stays registered,
and scaling the webhook to 0 would fail every kopiur CR write. The second is the `kopiur-repository`
Kustomization, which keeps reconciling `ClusterRepository/atlas` on its own 1h interval. Its
`dependsOn: [kopiur]` is for apply ordering only, so suspending the parent does not suspend the
child. It is harmless to reconcile that configuration while the controller is at 0 replicas.

```bash
just kube snapshot-pvc                     # every SnapshotPolicy in the cluster
just kube snapshot-pvc <ns>                # every policy in one namespace
just kube snapshot-pvc <ns> <policy>       # one policy
just kube browse-pvc <ns> <pvc>            # browse a PVC interactively
just kube toggle-kopiur <suspend|resume>   # suspend/resume the controller (webhook stays up)
just kube restore-pvc <ns> <app> [offset]  # in-place restore into a BOUND pvc; scales app to 0
kopiur status -n <ns>                      # repositories, policies, schedules
kopiur doctor -n <ns>                      # diagnose an installation
```
