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

VolSync was fully removed 2026-08-01, **CRDs included** — a `ReplicationSource` or
`ReplicationDestination` in any manifest or doc is dead reference, not a fallback. All 30 apps back
up via kopiur to `ClusterRepository/atlas` (NFS `10.10.99.100:/mnt/atlas/Kopiur`). The old VolSync
kopia repo remains on the NAS at `atlas/VolsyncKopia` as a frozen historical fallback — restoring
from it needs a manual kopia client.

Component defaults, which no manifest states in one place (`components/kopiur/backup/`):

| Setting           | Default                           | Override var                                              |
| ----------------- | --------------------------------- | --------------------------------------------------------- |
| Schedule          | `H * * * *` (hourly)              | none — edit the component or the app's `SnapshotSchedule` |
| Retention         | 30 daily / 8 weekly / 6 monthly   | none — no `keepLatest`, no `keepHourly`                   |
| `copyMethod`      | `Snapshot` (VolumeSnapshot clone) | —                                                         |
| Compression       | `zstd`                            | —                                                         |
| PVC capacity      | `5Gi`                             | `KOPIUR_CAPACITY`                                         |
| StorageClass      | `miroir`                          | `KOPIUR_STORAGECLASS` (app PVC only)                      |
| Staging class     | `miroir-local`                    | `KOPIUR_STAGING_STORAGECLASS`                             |
| Mover cache       | `5Gi`, **mode `Ephemeral`**       | `KOPIUR_CACHE_CAPACITY` / `KOPIUR_CACHE_MODE`             |
| Mover cache class | `miroir-local`                    | `KOPIUR_CACHE_STORAGECLASS`                               |
| Mover uid/gid     | `1000` / `1000`                   | `KOPIUR_PUID` / `KOPIUR_PGID`                             |
| Access modes      | `ReadWriteOnce`                   | `KOPIUR_ACCESSMODES`                                      |

**Retention here is coarser than Frostlink's on purpose.** Frostlink keeps 3 latest / 24 hourly /
7 daily / 4 weekly / 3 monthly against a metered R2 bucket; Artemis backs up to NFS on a 41 TB
array, so it keeps 30 daily instead of paying for hourly granularity. Do not "align" the two — the
backends are priced differently.

**The substitute var is `${APP}`, not `${KOPIUR_APP}`.** Frostlink's component uses `${KOPIUR_APP}`;
Artemis's uses `${APP}`, which `components/postgres/app` now also defaults to (`${PG_APP:=${APP}}`,
set `PG_APP` only when the database name differs). Copying a `postBuild.substitute` block between the two repos silently leaves a
var unsubstituted.

The kopia source identity is `<policy>@<namespace>:/pvc/<pvc>` — `identityDefaults` on
`ClusterRepository/atlas` are `usernameExpr: policyName`, `hostnameExpr: namespace`. Frostlink's
`usernameExpr` is `namespace + '-' + policyName`, so identities are **not** portable between the
two repositories. Renaming a policy starts a fresh snapshot lineage and orphans the old one with
nothing to prune it.

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
- **A `Restore` is one-shot and terminal by design — editing a completed one is not a supported
  operation.** Upstream is explicit: _"a Restore is one-shot — fix the cause and create a new
  Restore"_ (`docs/restores.md`). So a completed Restore's `observedGeneration` freezing is a
  property of a terminal object, **not a bug** — an earlier revision of this file called it one and
  suggested filing it upstream. That was wrong. The consequence is real but the cause is ours: edit
  the spec of a completed Restore and it sits at `generation != observedGeneration` forever, kstatus
  reports InProgress, and any `wait: true` Kustomization hangs the full 60m timeout every cycle.
  This is what stalled `arcade/eco` for 24 days.
- **The interface is delete-and-recreate, not edit.** Whenever a Restore's rendered spec changes —
  `KOPIUR_PUID`/`KOPIUR_PGID`, storageclass, anything — delete the CR and let Flux recreate it.
  Recreating a populator Restore over a **bound** PVC is a documented no-op: it completes as
  `Ready=True reason=TargetAlreadyBound` with no mover run and the live volume untouched (verified
  across 9 apps on 2026-08-22 — every one reported exactly that, and no prime PVCs leaked). The CR
  has no finalizers and no ownerReferences, and the PVC is not owned by it, so deleting one cannot
  cascade.
- **Do not recreate a Restore to pick up a newer snapshot on a bound PVC** — it won't. A populator
  only hands a volume to an _unbound_ claim, and the source snapshot is pinned to `status.resolved`
  at first resolution. To genuinely re-restore, delete the **PVC** (keeping its `dataSourceRef`) and
  let it be re-created. To re-resolve to a newer snapshot, delete and re-create the `Restore`.
- **Watch for leaked `prime-<uid>` PVCs if ever running kopiur ≤ 0.7.x**: that era ran a full
  restore into a prime PVC that could never be adopted, leaking a Bound second copy of the data per
  re-created Restore. 0.8.0+ reaps them (`OrphanedPrimePvcReaped`). Audit with
  `kubectl get pvc -A -l kopiur.home-operations.com/op=restore-populate` — clean here as of
  2026-08-22.
- **`kustomize.toolkit.fluxcd.io/ssa: ignore` and the `mover.cache` block were both removed from
  `restore.yaml` on 2026-08-22**, bringing the component in line with onedr0p/home-ops, which
  carries neither. The cache block was the more harmful of the two: it was the only field where the
  rendered spec diverged from the 29 live Restores, making it the sole thing that would have
  stalled the fleet the moment Flux began enforcing them. Restores now inherit cache settings from
  `ClusterRepository/atlas`, which is how they had effectively been running all along. What stays
  is the mover identity block — load-bearing for the only two apps that need it (`arcade/eco` at 0,
  `default/xbrowsersync` at 999). onedr0p defines the same `KOPIUR_PUID`/`KOPIUR_PGID` vars but
  never sets them anywhere, because every app he runs is uid 1000.
- **Flux does NOT create objects annotated `ssa: ignore` — it skips them entirely.** Verified
  2026-08-22 by deleting `media/thelounge`'s Restore and force-reconciling with the annotation
  still on `main`: it was never recreated. An earlier revision of this file claimed "Flux still
  creates it but reports it `skipped`" — **that was wrong**, and the frostlink note was right.
  Consequence while the annotation was in place: every Restore CR in this cluster was created by
  `just kube apply-ks`, never by Flux.
- **`just kube apply-ks` cannot honour `ssa: ignore`.** It is a plain server-side apply that
  passes `--field-manager=kustomize-controller` (identical to onedr0p's recipe; ours only adds the
  suspend wrapper). The annotation is interpreted by Flux's kustomize-controller alone — borrowing
  the field-manager name does not borrow the behaviour. This bit the kaizoku→rensaio migration on
  2026-08-22: a hand-created `Restore` pointing at the old policy was silently overwritten with the
  rendered one, which pointed at a policy holding zero snapshots and would have populated an
  **empty** PVC under the default `onMissingSnapshot: Continue`.
- **On any cross-policy restore — a rename, or recovering one app's data into another — set
  `onMissingSnapshot: Fail`** so a bad source resolution fails loudly instead of silently binding an
  empty volume, and create both the `Restore` and the PVC by hand rather than letting `apply-ks`
  create the PVC.

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
a claim. The component's `mover.cache` block is therefore gone entirely and each policy inherits
`moverDefaults` — mode, budgets, no capacity. That stops one `miroir-local` volume per run across
28 hourly policies.

**A per-recipe `mover.cache` silently defeats the repository default**, because `MoverSpec` overlays
`MoverDefaults` field-wise and the recipe wins. Removing `capacity` from `moverDefaults` alone did
nothing while the component still set `capacity: 5Gi` — the cache PVCs kept being created. Change
both, or change the component.

`storageClassName` on a cache with no `capacity` is inert (there is no PVC to place), which is why
`KOPIUR_CACHE_STORAGECLASS` is gone from the component too.

Historical, for the 5Gi-PVC era: the cost was **concurrent**, N overlapping movers each holding a
5Gi claim — not 30 standing ones. An earlier revision claimed 54 persistent per-app cache PVCs
reserving 270 GiB; that was the cluster's total PVC count and the reservation never existed.
`concurrency.maxConcurrentJobs: 3` now bounds the overlap regardless.

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

### `copyMethod: Direct` was evaluated and rejected (2026-09-07)

Direct mounts the live PVC — no VolumeSnapshot, no staged PVC, no volume per run. It was built as
a `backup-direct` component and reverted, for two reasons.

The churn it removes is not expensive. A `replicas: 1` miroir volume has **no DRBD layer at all**
(`spec.drbd.port` is unset) — it is a plain lvmthin volume. The promote/demote cycle behind
miroir#390 was ~58 _replicated_ volumes an hour, and `53ed37665` already ended that by moving
staging to `miroir-local`. What remains is cheap lvmthin create/CoW-clone/delete.

The risk it adds is real. Direct is a crash-consistent live read, so a database file and its `-wal`
are read moments apart. A scan of all 28 backed-up PVCs found **15 with databases, 10 clean, 3
unverifiable**. Seven are in WAL mode with an open log: `komga` (353 MB `database.sqlite` + `-wal`

- `-shm`), `hermes`, `frigate`, `jellyfin`, `qbittorrent`, `seerr`, `rensaio`. The others with a
  database are `komf`, `mosquitto`, `zigbee`, `paperless`, `sabnzbd`, `shelfmark`, `thelounge` and
  `lldap` (`users.db` — the auth directory).

Clean, and only these: `sonarr`, `radarr`, `bazarr`, `esphome`, `home-assistant`, `homebridge`,
`matter-server`, `minecraft`, `xbrowsersync`, `node-red`. Unverifiable at the time: `eco` and
`apoci` (not running), `pocket-id` (its container is not named `app`). The Postgres migration
helped less than expected — being wired to Postgres does not mean the PVC is free of a secondary
database, and `paperless` and `seerr` are both counterexamples.

Scanning trap, since two attempts got it wrong: `find -printf` is GNU-only and busybox exits
silently (reads as clean), and `find / -xdev` never enters a PVC because every mount is a separate
filesystem. Derive the mountPath from the pod spec and scan that path.

### `IndexBlobHealth: False` is the normal steady state here — it is not a broken repository

`ClusterRepository/atlas` reports `IndexBlobHealth=False / TooManyIndexBlobs` (2295 content-index
blobs against the default threshold of 1000, live 2026-08-21) while `Ready=True` and every policy
is snapshotting on schedule. Mechanism: kopia only compacts index blobs two epochs behind the
current one, and an epoch cannot close before `spec.parameters.epoch.minDuration`. That is set to
**`6h`** here (kopia's own default is 24h) precisely to let compaction keep up on a busy
repository; it has not fully caught up.

Do not read this condition as "backups are failing" — check
`SnapshotPolicy.status.lastSuccessfulSnapshot` instead, which is the signal that matters. If the
count is genuinely climbing, the escalation order is: confirm the maintenance Job is running, then
`spec.maintenance.takeoverPolicy: Force` **once** if it is stuck on a stale lease owner, then lower
`epoch.minDuration` further. Raising `spec.health.indexBlobWarnThreshold` only silences the signal.
Frostlink leaves `indexBlobWarnThreshold: 1000` at the default and reports `Healthy` — its
repository is five policies, not thirty.

```bash
just kube snapshot               # snapshot every kopiur SnapshotPolicy now
just kube browse-pvc <ns> <pvc>  # browse a PVC interactively
just kube kopiur <state>         # suspend or resume kopiur (suspend/resume)
just kube restore <ns> <app> [offset]  # restore a PVC in place (0 = latest)
kopiur status -n <ns>            # repositories, policies, schedules
kopiur doctor -n <ns>            # diagnose an installation
```
