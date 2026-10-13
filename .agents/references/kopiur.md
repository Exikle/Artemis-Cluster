# Reference: kopiur — Artemis-Cluster

Backups: the kopiur operator, `ClusterRepository/atlas` on NFS, component defaults, mover uid and
cache budgets, restore behaviour, and the conditions that look broken and are not. It covers
backup and restore only — the StorageClass and VolumeSnapshotClass the movers consume are in
`storage.md`.

**Frostlink runs the same operator against a different backend, and its counterpart lives in
`frostlink/.agents/references/storage.md` § kopiur.** This file deliberately mirrors that one so
drift between the two clusters is a one-file diff. The differences below — retention, the
substitute var, `usernameExpr` — are intentional and follow from
NFS-on-a-41 TB-array here versus a metered R2 bucket there. **Do not "align" them by copying
either repo's setting onto the other**; read both files first.

## kopiur

VolSync is gone — `AGENTS.md` § "What was deliberately removed" is the home for that, and it wins.
Every backed-up app uses kopiur against `ClusterRepository/atlas` (NFS
`10.10.99.100:/mnt/atlas/Kopiur`); `grep -rln 'components/kopiur/backup' kubernetes/apps/` lists
them. The old VolSync kopia repo remains on the NAS at `atlas/VolsyncKopia` as a frozen historical
fallback — restoring from it needs a manual kopia client.

Component defaults, which no manifest states in one place (`components/kopiur/backup/`):

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

**Retention here is deeper than Frostlink's on purpose.** Frostlink keeps 3 latest / 24 hourly /
7 daily / 4 weekly / 3 monthly against a metered R2 bucket; Artemis backs up to NFS on a 41 TB
array, so it keeps 30 daily and 6 monthly. Do not "align" the two — the backends are priced
differently.

**The substitute var is `${APP}`, not `${KOPIUR_APP}`.** Frostlink's component uses `${KOPIUR_APP}`;
Artemis's uses `${APP}`, which `components/postgres/app` now also defaults to (`${PG_APP:=${APP}}`,
set `PG_APP` only when the database name differs). Copying a `postBuild.substitute` block between the two repos silently leaves a
var unsubstituted.

The kopia source identity is `<policy>@<namespace>:/pvc/<pvc>` — `identityDefaults` on
`ClusterRepository/atlas` are `usernameExpr: policyName`, `hostnameExpr: namespace`. Frostlink's
`usernameExpr` is `namespace + '-' + policyName`, so identities are **not** portable between the
two repositories. Renaming a policy starts a fresh snapshot lineage and orphans the old one with
nothing to prune it.

### Retiring an app does not purge its backups

**Deleting an app's Flux Kustomization orphans its kopia lineage — it does not delete it.** Pruning
the `SnapshotPolicy`/`SnapshotSchedule` does cascade to the child `Snapshot` CRs through
ownerReference GC, so they vanish from `kubectl get` and it looks done. It is not: the controller
runs that cascade as `plan=RetainSnapshotOnScheduleDelete` / `RetainSnapshotOnPolicyDelete`
(`mode=Retain`) and the snapshots stay in the repository with no policy left to prune them.

To actually purge, delete the `Snapshot` CRs **explicitly, before** the Kustomization:

```bash
kubectl delete snapshots.kopiur.home-operations.com -n <ns> -l kopiur.home-operations.com/config=<app>
```

That path honours `spec.deletionPolicy: Delete` and the `kopiur.home-operations.com/snapshot-cleanup`
finalizer, which is what queues the repo-side `SnapshotDeleteBatch` job. Note the `MassDeletionHeld`
breaker on `ClusterRepository/atlas` trips above 10 pending external destructive deletions, so a long
lineage needs batching.

**Order is the whole trick, and it is not recoverable.** Once the CRs are gone the snapshots cannot
be re-attached — the `Snapshot` CRD builds a new snapshot from a PVC source and has no adopt/import
field — so the only remaining route is a manual kopia client against the repository. Learned
retiring `home-automation/node-red` on 2026-09-08; its 56 snapshots were left behind deliberately
rather than purged by hand.

`status.storageStats.snapshotCount` on the ClusterRepository is **not** a check for any of this:
`status.catalog.lastRefreshAt` lags by up to `catalog.refreshInterval` (1h), so the number stays
stale for an hour. Read the `kopiur-controller` logs instead.

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
  it and a mismatched mover just gets permission denied. The mover's `fsGroup` also owns the
  cache PVC, which the mover must be able to write. Cluster-wide only xbrowsersync needs it
  (999, mongodb sidecar).
- **`kopiur-system` pulls in `components/kopiur/secret` too** — the operator reads the repository
  password to connect, and maintenance movers run in that namespace. It is wired from the
  repository child ks rather than the namespace kustomization so it stays testable with
  `just kube apply-ks`.
- **`restore.yaml` must mirror the SnapshotPolicy's mover identity** or a restore writes files as
  1000 regardless of the app's uid and the app cannot open its own data.
- **A `Restore` is one-shot and terminal by design.** Upstream: _"a Restore is one-shot — fix the
  cause and create a new Restore"_. Edit a completed one and it sits at
  `generation != observedGeneration` forever, kstatus reports InProgress, and any `wait: true`
  Kustomization hangs the full timeout every cycle.
- **The interface is delete-and-recreate, not edit.** Whenever a Restore's rendered spec changes —
  `KOPIUR_PUID`/`KOPIUR_PGID`, storageclass, anything — delete the CR and let Flux recreate it.
  Recreating a populator Restore over a **bound** PVC is a documented no-op: it completes as
  `Ready=True reason=TargetAlreadyBound` with no mover run and the live volume untouched. The CR
  has no finalizers and no ownerReferences, so deleting one cannot cascade.
- **Do not recreate a Restore to pick up a newer snapshot on a bound PVC** — it won't. A populator
  only hands a volume to an _unbound_ claim, and the source snapshot is pinned to `status.resolved`
  at first resolution. To genuinely re-restore, delete the **PVC** (keeping its `dataSourceRef`) and
  let it be re-created. To re-resolve to a newer snapshot, delete and re-create the `Restore`.
- **`restore.yaml` carries no `kustomize.toolkit.fluxcd.io/ssa: ignore` — do not re-add it.** Flux
  skips such objects entirely, so no Restore would ever be created by Flux. `restore.yaml` keeps
  `mover.cache.mode: Ephemeral` and the mover identity block, which is load-bearing for the only two
  apps that need it (`arcade/eco` at 0, `default/xbrowsersync` at 999).
- **`just kube apply-ks` overwrites a hand-created `Restore`** with the rendered one. For any
  cross-policy restore — a rename, or recovering one app's data into another — set
  `onMissingSnapshot: Fail` so a bad source resolution fails loudly instead of silently binding an
  empty volume (the default is `Continue`), and create both the `Restore` and the PVC by hand
  rather than letting `apply-ks` create the PVC.

### The kopia web UI is deliberately removed (2026-08-09)

`ClusterRepository/atlas` no longer sets `spec.server`, and the standalone `httproute.yaml` for
`kopiur.dcunha.io` is deleted. **Do not re-add it as a "missing" route** — the operator creates the
Service from `spec.server`, so the route exists only when the UI does.

Removed at the user's request; it was barely used and its pod had been restarting (25× in 12h,
all clean `exit=0`). Note the security property that made it worth removing cheaply: the server
pod holds the repository **decryption key** even in `readOnly: true` mode, which is why its
Service was ClusterIP and internal-gateway-only in the first place.

Repository inspection without the UI: `kopiur status -n <ns>` and `kopiur doctor -n <ns>`.

### Mover cache budgets — `contentCacheSizeMb` / `metadataCacheSizeMb` are mandatory

Set on `ClusterRepository/atlas`. Without them the maintenance mover fills its cache PVC and every
run fails with `no space left on device` (first hit 2026-08-09; the full-maintenance job had been
failing for ~53 min).

kopia's own defaults are **5000 MB content + 5000 MB metadata**, so a 5Gi cache PVC cannot hold even
the content cache alone. Observed on the full 5Gi `kopiur-cache-atlas`: `cache/contents` 4.0G,
`logs/` 359M (`content-logs` 346M — also unbounded, and there is no kopiur knob for log retention),
`cache/metadata` 295M, `cache/index-blobs` 170M. The connect then fails writing
`repository.config`, and the surfaced error is misleading — `Cannot determine current user: user:
Current requires cgo or $USER set in environment` appears _above_ the real cause in the mover log.
Read past it to the `no space left on device` lines.

Budgets must leave headroom for logs on top of the two caches:

| Scope                     | mode         | capacity        | content | metadata | headroom |
| ------------------------- | ------------ | --------------- | ------- | -------- | -------- |
| `moverDefaults.cache`     | `Ephemeral`  | none (emptyDir) | 2000 MB | 1000 MB  | node     |
| `maintenance.mover.cache` | `Persistent` | 10Gi            | 3000 MB | 4000 MB  | ~3.2Gi   |

**The per-app mover cache is an `emptyDir`, not a PVC (2026-09-07).** An `Ephemeral` cache with
no `capacity` is a node-local `emptyDir`; `capacity` is the only thing that makes kopiur provision
a claim. The `SnapshotPolicy` in the component therefore has no `mover.cache` block and inherits
`moverDefaults` — mode, budgets, no capacity. That stops one `miroir-local` volume per run across
every hourly policy. `restore.yaml` keeps only `mover.cache.mode: Ephemeral`, with no capacity.

**A per-recipe `mover.cache` silently defeats the repository default**, because `MoverSpec` overlays
`MoverDefaults` field-wise and the recipe wins. Removing `capacity` from `moverDefaults` alone did
nothing while the component still set `capacity: 5Gi` — the cache PVCs kept being created. Change
both, or change the component.

`storageClassName` on a cache with no `capacity` is inert (there is no PVC to place), which is why
there is no cache storage-class variable in the component.

Maintenance gets its own larger override because full maintenance compacts index blobs and is
metadata-bound. It is the only kopiur cache that survives between runs, which is why it is the
only one that can fill.

An ephemeral cache is regenerable and is discarded every run anyway; the persistent maintenance
cache is equally safe to clear — delete `kopiur-system/kopiur-cache-atlas` and let kopiur recreate
it.

### Mover placement is the scheduler's job, not kopiur's (2026-09-07)

`miroir-local` is `replicas: 1` on the `nvme` pool, and that pool exists only on the three control
planes. Nothing told the scheduler: it would place a mover on a worker, miroir would place the
staged PVC elsewhere in the pool, and the pod could never bind — a PV's node affinity is immutable.
Verified on `matter-server-20260907054400`, both PVCs annotated `selected-node: talos-w-01` with
PVs on `talos-cp-03` and `talos-cp-01`.

The fix is `storageCapacity.enabled: true` on the **miroir** chart, not a kopiur nodeSelector.
Publishing `CSIStorageCapacity` makes the scheduler treat a `(node, class)` pair with no capacity
as unfit; live values show `miroir-local` at 0 on all four workers and ~173 GB on the three storage
nodes, while `miroir` (replicated, remotely consumable) stays available everywhere. It constrains
only pods that actually claim from such a class.

`moverDefaults.nodeSelector` was tried first and reverted: it applies repository-wide,
`SnapshotPolicy.spec.mover` has no scheduling fields to override it per app, and it would pin a
`copyMethod: Direct` mover away from the workload it has to co-locate with.

Cost: after an agent restart a `WaitForFirstConsumer` pod waits up to `agent.poolStatsInterval`
(60s) for fresh capacity stats before it can schedule.

### `copyMethod: Direct` was evaluated and rejected

Direct mounts the live PVC — no VolumeSnapshot, no staged PVC. Do not re-propose it.

- The churn it removes is cheap. A `replicas: 1` miroir volume has no DRBD layer — it is a plain
  lvmthin volume — and staging already moved to `miroir-local`.
- Direct is a crash-consistent live read, so a database file and its `-wal` are read moments apart.
  Many backed-up PVCs hold a database, several in WAL mode (`komga`, `hermes`, `frigate`,
  `jellyfin`, `qbittorrent`, `seerr`, `rensaio`), and being wired to Postgres does not mean the PVC
  has no secondary database.
- Scanning trap: `find -printf` is GNU-only and busybox exits silently (reads as clean), and
  `find / -xdev` never enters a PVC. Derive the mountPath from the pod spec and scan that path.

### `IndexBlobHealth: False` is a warning about index size, not a broken repository

The repository sets `spec.health.indexBlobWarnThreshold: 4000` (the default is 1000), which is
what keeps `IndexBlobHealth` at `Healthy`. If it flips to `False / TooManyIndexBlobs` while
`Ready=True`, backups are not failing — check `SnapshotPolicy.status.lastSuccessfulSnapshot`, the
signal that matters.

Mechanism: kopia only compacts index blobs two epochs behind the current one, and an epoch cannot
close before `spec.parameters.epoch.minDuration` (`6h` here; kopia's default is 24h). If the count
is genuinely climbing: confirm the maintenance Job is running, then
`spec.maintenance.takeoverPolicy: Force` **once** if it is stuck on a stale lease owner, then lower
`epoch.minDuration` further. Raising the threshold only silences the signal.

**`toggle-kopiur` pauses the controller, not everything kopiur.** Two things are deliberately
left alone: `kopiur-webhook`, because its Validating/MutatingWebhookConfiguration stays registered
and scaling it to 0 would fail every kopiur CR write; and the `kopiur-repository` Kustomization,
which keeps reconciling `ClusterRepository/atlas` on its own 1h interval. Its `dependsOn: [kopiur]`
is apply-ordering only — suspending the parent does not suspend the child. Reconciling that config
while the controller is at 0 replicas is harmless.

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
