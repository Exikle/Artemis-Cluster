# Reference: Shared Postgres + Dragonfly — home-infra

The cluster has one shared CNPG Postgres cluster and one shared Dragonfly. Both are in the `database` namespace. The base infra is
live (Phase 0 complete 2026-07-02) and in production use. This is the default data layer for new
apps. See `.agents/instructions/cluster-conventions.md` § Deployment Philosophy.

Shared Postgres cluster: every app that carries `components/postgres/app` with `APP` in
its `ks.yaml` `postBuild` is on it. This file has no roster on purpose, because the roster changes with every onboarding.
Run `grep -rln 'components/postgres' clusters/artemis/kubernetes/apps/` for the tree, and `kubectl get database -n database`
for what actually reconciled.

Shared Dragonfly: the index table further down is the authoritative list of which app
uses which index. Index 3 is free. `litellm` claimed it but never set it, and agentgateway replaced LiteLLM on 2026-10-26.

Every further app migration is its own session. This doc is what you need once you are doing one.

## What's live

- Cluster: `postgres` in `database`. It has `instances: 2` (HA, `primaryUpdateMethod: switchover`).
  `.spec.imageName` is the live image. Renovate moves it, so do not trust a version written here.
  VectorChord is loaded through `postgresql.extensions`, so vector-search apps do not need a separate
  cluster fork.
  `instances: 2` is the one structural difference from Frostlink. Frostlink runs `instances: 1` on
  one node and therefore treats every image bump as a planned outage. Here an image bump is a
  switchover, so tolerance of client-side blips is not the load-bearing concern that it is there.
- No pooler. Apps connect straight to `postgres-rw` with a password over TLS. Do not
  reintroduce a pgbouncer unless you can point at a measured connection-count problem. The old
  `poolMode: session` pooler gave no multiplexing, and its `pg_ident` map let the pooler cert
  authenticate as any role.
- Dragonfly: `dragonfly` in `database`. It has 2 replicas (master + replica, operator-managed
  failover) and runs with `--cluster_mode=emulated --lock_on_hashtags --default_lua_flags=allow-undeclared-keys`
  for broad client compatibility. It has no auth and no persistence. For consumers, see the index table below.
- Backups: barman-cloud → Cloudflare R2 (`s3://artemis-kopiur/barman/`), with a daily schedule and
  on-demand `Backup` CRs. Restore from backup is proven live (scratch cluster, deleted after).
- CA chain: `postgres-server-ca` / `postgres-client-ca` ClusterIssuers in `cert-manager`,
  distributed through trust-manager `Bundle`s (`root-ca`, `postgres-client-ca`). These are public-cert-only
  secrets, cluster-wide. Never reflect the raw CA secrets (see Gotchas).

## Onboarding an app onto shared Postgres

1. Wire the `ks.yaml` of the app to use the onboarding component:

    ```yaml
    components:
        - ../../../../components/postgres/app
    postBuild:
        substitute:
            APP: *app
    ```

    Use four `../`, not three. `../../../components/postgres/app` resolves outside the kustomize
    root and the build fails. Every live consumer uses `../../../../`, the same depth as
    `../../../../components/kopiur/backup`.

    `PG_APP` is now optional. It defaults to `${APP}`. Set it only when the database name
    genuinely differs from the app name. But every app must set `APP`, even one that does not
    use kopiur. The envsubst of Flux is strict and evaluates both halves of `${PG_APP:=${APP}}`, so an
    app that sets only `PG_APP` fails its whole post-build with
    `variable not set (strict mode): "APP"` and takes down anything that has `dependsOn` on it.

2. The namespace needs `components/postgres/tenants` in `clusters/artemis/kubernetes/apps/<ns>/kustomization.yaml`,
   exactly like `components/kopiur/secret`. It creates one `ResourceSet` per namespace. That `ResourceSet` watches
   for the input providers that the app component emits. It templates the `DatabaseRole` CR, the `Database`
   CR and the role Secret into `database`.

    The `inputsFrom` of a `ResourceSet` selects providers in its own namespace only. For that reason the
    ResourceSet lives beside the apps and writes _across_ to `database`, not the reverse.

    There are two traps. First, a namespace that carries `tenants` with no app using it yet has a ResourceSet with zero
    inputs, and `flate` then fails the _entire namespace_ with `map has no entry for key "name"`. Second,
    never name a component-generated input provider bare `${APP}`. An app can already own one
    named after itself (`cortex/memini` once did), so the postgres provider is `${APP}-postgres`.

    You cannot test the first postgres app in a namespace with `apply-ks` on the app alone.
    The `tenants` ResourceSet is a namespace-level resource, so it belongs to the root
    Kustomization (`flux-system/flux-system`, path `./kubernetes/apps`), not to the app's own
    Kustomization. `just kube apply-ks <ns> <app>` renders only the app path. The ResourceSet
    never appears, no `Database` CR is templated, no role Secret is created, and the pod of the app sits
    forever on the `k8s.ksgate.org/database-applied` scheduling gate.

    Apply the root as well: `just kube apply-ks flux-system flux-system`. It renders ~300
    objects, but they are all control-plane (Kustomization CRs, namespaces, alerts, ExternalSecrets,
    Databases, ResourceSets). It has no HelmReleases and no workloads, so nothing restarts. First make sure that your
    checkout matches `origin/main`. Otherwise the apply silently reverts untouched apps to your
    stale tree. Onboarding a second app into a namespace that already has `tenants` does not need
    this step.

3. What the component creates: a `ResourceSetInputProvider` (`<app>-postgres`) in the namespace of the app,
   a `<app>-postgres` Secret with the credentials and DSNs, and a `<app>-postgres` ConfigMap
   with the libpq SSL env. Through the namespace ResourceSet, it also creates a `DatabaseRole` CR named `<app>`, a
   `Database` CR named `<app>`, and a `<app>-postgres` role Secret, all three in `database`.

    Connect using the Secret, not the ConfigMap. The Secret and ConfigMap share the name, so a
    consumer that switches from the old cert component changes `configMapKeyRef` to `secretKeyRef` and
    keeps `key: url`.

    There are three DSN keys, because three drivers disagree. Pick by driver, not by taste:

    | Key          | For                       | Shape                                                                        |
    | ------------ | ------------------------- | ---------------------------------------------------------------------------- |
    | `url`        | libpq, pgx, node-postgres | `?sslmode=verify-full&sslrootcert=<CA path>`                                 |
    | `url_node`   | postgres-js               | `?sslmode=verify-full` only; CA via `NODE_EXTRA_CA_CERTS`                    |
    | `url_prisma` | Prisma                    | `?sslmode=verify-full&sslcert=<CA path>` — `sslcert` means the **root** cert |

    `just kube check-postgres <ns> <app>` validates the `url` key only, and that is deliberate.
    psql is libpq, so it reads `sslcert=` of Prisma as a _client_ cert and has no CA at all for the
    postgres-js shape. A psql pass on those two would give false confidence about exactly the failure
    below. All three keys carry the same credentials, host and database. The check therefore still proves
    the credential, the CA and `verify-full` for every app regardless of driver. It cannot prove
    that an app picked the right key for its driver. It is a static check, not a connectivity one.

    Getting this wrong is not a soft failure. postgres-js forwards unknown connection-string params
    to the server as startup parameters, so a libpq-shaped DSN gets
    `unrecognized configuration parameter "sslrootcert"` and the app never connects. It cost
    streamystats an outage. Prisma is the opposite: it silently drops what it does not recognise, so a
    wrong DSN there fails _open_ and connects without verifying.

    The Secret also holds discrete fields (`POSTGRES_HOST`/`PORT`/`DATABASE`/`USERNAME`/`PASSWORD`)
    for apps that take host/user/password separately and not as a URL.

    `<owner>` is `${DATABASE_OWNER}`, which defaults to `${PG_APP:=${APP}}`. Set it only when the
    role name differs from the database name.

### Roles are templated, not listed

Roles moved out of `spec.managed.roles` in `cluster.yaml` on 2026-09-02. The `postgres-tenants` ResourceSet now emits them as
per-tenant `DatabaseRole` CRs. There is nothing to edit in
`cluster.yaml` when you add or remove an app. The input provider that the component of the app emits is
the only place where a tenant is declared. The `managed` stanza is gone from the Cluster entirely.

`DatabaseRole` is a CNPG 1.30 CRD. Know three things about it before you touch one:

- It adopts, and adoption is destructive to omitted attributes. If you point a `DatabaseRole` at a
  role that already exists, it rewrites _every_ attribute to match the manifest, including the ones the
  manifest does not mention. It revokes memberships that are absent from `inRoles`, an omitted
  `connectionLimit` resets to `-1`, and an omitted `validUntil` becomes `infinity`. The template is
  deliberately minimal (`login`, `superuser`, `passwordSecret`) because every tenant role is
  minimal. If a role needs `inRoles` or a connection limit, the template must have it, or the next reconcile
  strips it.
- `databaseRoleReclaimPolicy: retain` is set explicitly and must stay that way.
  If you delete the `ks.yaml` of an app, that removes its input provider, which removes the `DatabaseRole`. Under `delete` that
  would attempt a `DROP ROLE`. Under `retain` the role and everything it owns survive. The default
  is already `retain`, but the manifest writes it out. It is the field that stands between a manifest
  deletion and data loss, and manifests here carry no comments to say so.
- It does not self-heal the way the inline stanza did. CNPG reconciles a `DatabaseRole` when
  its spec or its password Secret changes. It does not detect or revert a manual `ALTER ROLE` in the database.
  CNPG compared inline `managed.roles` against the catalog periodically. Drift that comes
  from hand-editing a role in psql now persists.

If a role name is ever declared in both places at once, the Cluster spec wins, and the
`DatabaseRole` reports `status.applied: false` with `database role is already managed by the CNPG
cluster`. That is the signal that a stale `managed.roles` entry came back.

4. The pod does not start until Postgres is ready. The component adds `ksgate`
   (`k8s.ksgate.org/*`) scheduling gates, so the pod of the app stays `SchedulingGated` until the shared
   Cluster has at least 1 ready instance, the `postgres-rw` Service exists, and the `Database` CR of the app shows
   `status.applied: true`. This is expected, not a stuck pod.

5. If the DSN of the app is set in a config file on its PVC, that wiring is not in git. Some apps
   are not configured by their HelmRelease at all. `recorder.db_url` of Home Assistant lives in
   `/config/configuration.yaml` on the PVC. Inject the DSN as an env var from the component Secret
   and reference it from the config file (HA: `db_url: !env_var RECORDER_DB_URL`), so the credential
   never lands on disk. Be aware of the consequence: if you restore that PVC from a kopiur snapshot
   taken before the migration, the app silently reverts to its old database, with no manifest
   change to indicate it. The HelmRelease still passes the DSN in, and the app quietly ignores it.
   Leave a backup of the pre-migration config beside it (`configuration.yaml.pre-postgres`), and
   re-check the config after a PVC restore on such an app.

## There are no pgbouncer sidecars

Do not add one back to solve a TLS problem. Solve it with the right DSN key from the table above.
Servarr has no `SslMode` option, but Npgsql negotiates TLS against a `hostssl` line anyway.
`pg_stat_ssl` reports `ssl=t` for the role.

Servarr logs its connection string, password included, at Info level on every startup
(`MigrationController: *** Migrating Database=...;Password=... ***`), and pod logs ship to
VictoriaLogs. The fleet currently shares one password, so that single log line is the credential for
every role. The team accepted this deliberately for a LAN homelab. Remember it before you treat log access as
low-sensitivity.

### CR-based apps get the Database CR, but not the pod patch

`components/postgres/app/patch` targets `kind: HelmRelease` only. An app deployed as a custom
resource still gets everything the ResourceSet makes: the `Database` CR, the role Secret, its own
input provider and the Secret in the namespace of the app. These are plain resources, not patches. It
does not get the ksgate scheduling gates or the server-CA volume mount.

A CR app therefore declares its own mount. `security/pocket-id` (a `PocketIDInstance`) does.
If an app misses the mount, nothing tells you: `verify-full` has no CA to check against.

## Onboarding an app onto shared Dragonfly

This is a pure config cutover. It needs no data migration and no kustomize component. Dragonfly is a cache with no auth and
nothing to provision per app. It has no scheduling gate either, deliberately. Postgres is a hard
dependency, because the `Database` CR and role password of the app must exist before it can even authenticate. A
cache is a soft dependency, and Redis-protocol clients already retry and reconnect on their own. The design follows
[mortebrume/homelab](https://github.com/mortebrume/homelab), which runs 8 apps against a shared
Dragonfly this way with no gating at all.

1. Claim the next unused index from the table below and add a row for the app. Index `0` is
   reserved and never assigned. A pod that forgot to configure an index (silently defaulting to
   `0`) is then immediately obvious, and does not collide with a real app.

    This table is an allocation registry, not a derived list. An index held for an app that
    has not configured it yet exists nowhere else and cannot be grepped. The table deliberately does not record key counts.
    `redis-cli INFO keyspace` (below) answers that live.

    | Index | App                                                               | Where the index is set                     |
    | ----- | ----------------------------------------------------------------- | ------------------------------------------ |
    | 0     | _(reserved — never assign)_                                       | —                                          |
    | 1     | paperless                                                         | `PAPERLESS_REDIS` URL suffix `/1`          |
    | 2     | immich                                                            | `REDIS_DBINDEX: "2"` (app + microservices) |
    | 3     | _(free — litellm's claim lapsed when it was removed)_             | —                                          |
    | 4     | free — was tekton-runner failover checkpoints, retired 2026-10-27 | —                                          |
    | 5     | trawl (Cloudflare bypass session cache)                           | `REDIS_URL` suffix `/5`                    |
    | 6     | silo                                                              | `REDIS_URL` suffix `/6`                    |

    Verify the index of an app the same way. The manifest can lie, but the keyspace cannot:

    ```bash
    kubectl -n database exec dragonfly-0 -c dragonfly -- redis-cli INFO keyspace
    ```

2. Point the Redis/cache env of the app directly at `redis://dragonfly.database.svc:6379/<index>`
   (or the equivalent host/port/db-index fields of the app, because not all apps take a single URL).
3. Drop the old sidecar or embedded Redis or Valkey container, its config, and any PVC it had.
   Dragonfly needs none of that.
4. Add the namespace of the app to `dragonfly-clients`
   (`clusters/artemis/kubernetes/apps/database/dragonfly/cluster/networkpolicy.yaml`). The dragonfly-operator
   generates its own `dragonfly` NetworkPolicy. The Dragonfly CR owns it, so you cannot manage it
   from git. Its 6379 ingress rule is a bare `podSelector: {}`, which means "this namespace
   only" and drops every cross-namespace client. NetworkPolicies union, so `dragonfly-clients`
   is what widens it. If you skip this step, the app fails with connect timeouts, not refusals. The
   symptom does not point at a policy.

## R2 backup sizing — why the WAL settings are what they are

The team audited this on 2026-08-05, when the `artemis-kopiur` bucket hit 45.3 GiB / 13,481 objects with barman as
its only consumer. The breakdown was lopsided:

| Prefix                     | Size     | Objects |
| -------------------------- | -------- | ------- |
| `barman/postgres` WAL      | 33.1 GiB | 11,242  |
| `immich-pg18` base backups | 8.8 GiB  | 62      | ← now an orphaned prefix, see #1889 |
| `barman/postgres` base     | 2.0 GiB  | 62      |
| orphaned pre-pg18 prefixes | 1.2 GiB  | 251     |

WAL, not base backups, was 73% of the bucket. The whole `postgres` cluster holds only ~320 MB
of actual data across all databases. It generated ~2.2 GiB of WAL per day, roughly 7× the
entire database, every day.

`pg_stat_wal` explained it. 942,903 full-page images accounted for ~90% of 7.36 GB of `wal_bytes`.
Postgres writes a full 8 KiB page image the first time a page is touched after each checkpoint, and
`checkpoint_timeout` was at the 5-minute default, with 727 of 736 checkpoints timed and not
size-driven. The system re-imaged a small, constantly-rewritten working set into WAL 288
times a day. `checkpoint_timeout: 30min` is the fix that actually reduces bytes, because it cuts how
often the system re-emits those page images. `max_wal_size: 2GB` is headroom, so checkpoints stay
timed-driven and do not flip to size-driven at the longer interval.

The team deliberately did not enable `wal_compression`. It compresses full-page images inside the WAL
record, but the ObjectStore already applies `wal: compression: zstd` to the whole segment, which
captures nearly the same ratio. The segments were already compressing ~5:1 (16 MiB → 2-4 MiB).
If the team turned it on, it would mostly move the compression earlier without shrinking what lands in R2. It is
still worth considering if local `pg_wal` volume or replication bandwidth ever becomes the concern.

WAL now lives on its own 8Gi volume (added 2026-09-01, #1916). A stalled archive fills that
volume and not the data volume, and `CNPGWalArchiveBacklog` pages before it matters.

`archive_timeout: 900s` is an object-count lever, not a byte lever. It forces a segment upload
even when the segment is not full, so the old 300s value put a hard floor of 288 uploads/day under
the bucket regardless of activity. That is why WAL objects outnumbered everything else 100:1. The
unused tail of a force-switched segment is zero-padding that compresses to almost nothing, so
raising the value saves operations far more than storage. The tradeoff is off-site RPO: R2 can now be up
to 15 minutes stale. Local durability is unaffected. `postgres` runs `instances: 2` with streaming
replication, so R2 is the both-nodes-lost copy, not the first line of recovery.

Retention on both ObjectStores is `7d`. The base backups of Immich are ~291 MiB each and near-identical
day to day, so retention is the only meaningful lever there. Its WAL is negligible (182 MiB), which
is why it gets `archive_timeout` but not the checkpoint tuning.

### Orphaned prefixes are never reclaimed by `retentionPolicy`

Barman expires only servers that it still manages. A retired cluster prefix therefore sits in R2 indefinitely with no ObjectStore, Cluster,
or repo reference pointing at it. After a major-version migration or a restore test, delete the old
prefix by hand. Nothing in the cluster does it for you.

The bucket must contain exactly one prefix, `barman/postgres/`. Verify against a live listing
before you believe any inventory in this file:

```bash
kubectl run r2ls -n database --rm -i --restart=Never --image=amazon/aws-cli:latest \
  --env=AWS_ACCESS_KEY_ID="$(kubectl get secret -n database barman-r2 -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)" \
  --env=AWS_SECRET_ACCESS_KEY="$(kubectl get secret -n database barman-r2 -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)" \
  --env=AWS_DEFAULT_REGION=auto \
  -- s3 ls s3://artemis-kopiur/barman/ --endpoint-url https://cb8e9b25dc436d997f232269a3597c61.r2.cloudflarestorage.com
```

The workstation has no `r2:` rclone remote configured, so `rclone`-based recipes for this
bucket do not work as written. Go through the `barman-r2` Secret as above.

The gate for purging is a backup, not a waiting period. The old prefix stops being the rollback
the moment the _new_ lineage holds a base backup that actually contains the app. Take an
on-demand backup and do not wait for the nightly one:

```bash
kubectl create -f - <<'MANIFEST'   # the cnpg kubectl plugin is not installed
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: postgres-post-<app>-migration, namespace: database }
spec:
  cluster: { name: postgres }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
MANIFEST
```

Confirm that it landed by size, not only by timestamp. The post-immich backup jumped from 150.6 MiB
to 604.3 MiB, which matches the 527 MB database of immich. A base backup that did not grow is a base backup
that did not pick the app up.

One caveat made the immich rollback worth less than it looked: a barman prefix is
database-only. The Immich library is NFS on atlas (`/mnt/atlas/media/photos`), so restoring an
old prefix would have desynced metadata from files already on disk. Weigh a retained prefix against
what it can actually restore before you hold it.

## Dedicated CNPG clusters — there are none

A per-app `Cluster` is not the default, and has not been since 2026-07-02. The old
`cnpg-database` skill taught "one Cluster per app, never shared" with `username`/`password`
ExternalSecrets. The shared cluster described above supersedes that policy, and the team retired the skill on 2026-08-21.

The fleet has exactly one CNPG `Cluster` (`kubectl get cluster -A`).

`kubectl get cluster -A` lists it. Read `.spec.imageName` for the live version, because Renovate moves it.
Storage is `40Gi` data + `8Gi` WAL, with the `r2-store` ObjectStore at `s3://artemis-kopiur/barman/`.

### Check the shared cluster before forking one

The shared cluster loads VectorChord through `postgresql.extensions` instead of a forked base
image, so it usually already has what an app needs. `SELECT name, default_version FROM
pg_available_extensions` on the primary settles it in one query. If you must fork, say why
in the commit, give the new cluster its own `walStorage`, and connect through `<name>-rw`. Remember that the R2 prefix is
baked in at creation. If you rename the Cluster, it orphans the whole barman server (see § Orphaned
prefixes).

### What the immich migration actually took

This list is here because the next consolidation will look the same:

- Create the extensions before the restore. `DATABASE_EXTENSIONS` in the component is
  effectively dead (see Gotchas), so this is a manual `CREATE EXTENSION` pass on the new database.
  A dump loads index definitions that reference extension types. Without the extensions, the restore fails midway.
- Use dump/restore, not logical replication. It rebuilds the vector indexes, which is what you want
  across a pgvector version change anyway.
- Verify the vector index, not only row counts. Run `EXPLAIN` on a nearest-neighbour query and confirm
  an `Index Scan`, not a `Seq Scan`. VectorChord also needs `SET vchordrq.probes` in the session. Without it,
  the query errors with `need 1 probes, but 0 probes provided`. Immich sets that session setting
  itself, so the error does not mean a broken index.
- Raise the startup budget of the app first. A database migration is another cold start, and migrations
  can outrun a short startup probe and restart-loop the pod.

### Retiring an app's own Postgres leaves its PVC behind

The migration off per-app databases deletes the StatefulSet, not the claim. `miroir` is
`reclaimPolicy: Delete`, but that fires only on PVC deletion. Nothing references an orphaned claim, but the cluster holds it
forever, it costs one copy per replica, and it looks identical to a healthy one
in `kubectl get pvc`. Delete the PVC as the last step of any migration off a per-app database.

`storage.md` § Orphaned PVCs keeps the live orphan inventory in one place only. It also
has the pod-volume diff that finds them. The team reclaimed the seven that were already missed on
2026-09-01 under [#1889](https://git.dcunha.io/Exikle/home-infra/issues/1889).

### The PVC is one of four things a retirement leaves behind

The #1889 audit found the same shape four times over: Flux prunes the declarative object, and
whatever holds the bytes is retained by design. When you retire an app from the shared cluster,
check all four, not only the PVC:

| Left behind                | Why it survives                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------ |
| The **PVC**                | `reclaimPolicy: Delete` fires on PVC deletion, not on StatefulSet deletion                       |
| The **database**           | `databaseReclaimPolicy: retain` is the CNPG default — the `Database` CR goes, the database stays |
| The **client-cert Secret** | cert-manager does not delete a Secret when its `Certificate` is pruned                           |
| The **barman R2 prefix**   | `retentionPolicy` only expires servers barman still manages (see § Orphaned prefixes)            |

`databaseReclaimPolicy: retain` as the default is the trap. Every app removed from the
shared cluster leaves its database behind unless you drop it explicitly. Confirm the primary first,
because it moves on switchover:

```bash
kubectl get pods -n database -l cnpg.io/cluster=postgres,role=primary
```

A hand-made `Backup` CR is a fifth, rarer case. The cluster owns `ScheduledBackup`-created Backups and garbage-collects them
with it, but a Backup created by hand has no owner reference and outlives the cluster.
Deleting that CR does not touch the R2 data.

Stand up a dedicated cluster only when the app genuinely cannot share. Examples are an extension that the shared
cluster does not load, a major-version pin, or a hard isolation requirement. Say why in the
commit. If you do, follow these rules:

| Rule                                    | Why                                                                                                                                                                                                       |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Always give it its own `walStorage`** | If WAL shares the data disk and archiving lags (or is not configured), WAL fills the data PVC and the pod enters CrashLoopBackOff. A separate volume turns a cluster-down into a stalled-archive warning. |
| Connect via `<name>-rw`                 | CNPG auto-creates `<name>-rw` (read-write) and `<name>-ro`. `<name>` alone is not a Service.                                                                                                              |
| Back the data PVC up with kopiur        | Add `../../../../components/kopiur/backup` and point it at the CNPG PVC (`<name>-1`).                                                                                                                     |

### Common issues — dedicated or shared

| Symptom                          | Cause                                                                   | Fix                                                                                                                                                                                       |
| -------------------------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pod stuck `Pending`              | `miroir` PVC not bound (WaitForFirstConsumer — needs a consumer)        | Check the miroir agent and CSI pods in `miroir-system`                                                                                                                                    |
| `role "<app>" does not exist`    | The `DatabaseRole` CR has not reconciled yet                            | `kubectl -n database get databaserole <app> -o yaml` — `status.applied` and `status.message`                                                                                              |
| `password authentication failed` | Stale or wrong `POSTGRES_PASSWORD` in the app's `<app>-postgres` secret | Force-sync the ExternalSecret, then `just kube check-postgres <ns> <app>` to confirm the credential — it connects with the Secret's own `url` DSN, so it tests what the app actually uses |
| WAL directory fills              | No separate `walStorage` volume                                         | Add `walStorage` and reapply                                                                                                                                                              |
| Cluster stuck `Initializing`     | CRD not installed                                                       | `kubectl get crd clusters.postgresql.cnpg.io`                                                                                                                                             |
| App can't connect                | Wrong Service name                                                      | `postgres-rw.database.svc.cluster.local` for shared; `<name>-rw` for dedicated                                                                                                            |

## Gotchas

- `DATABASE_EXTENSIONS` in the component is effectively dead. The `Database` CR template has
  `extensions: ${DATABASE_EXTENSIONS:=[]}`, but you cannot thread a YAML list through the
  parent ks → nested ks substitution chain. The envsubst of Flux is text-level, so the flow-list string
  re-parses as a real YAML list inside `postBuild.substitute` (which must be strings). Quoted and
  block-scalar forms get normalized away too. Instead, run `CREATE EXTENSION` once as superuser on the
  database of the app right after the `Database` CR applies. Extensions persist, and barman backups are
  physical, so they survive restores. (Hit with streamystats: `pg_trgm`, `uuid-ossp`, `vector`.)
- Do not strip old-DB keys from the ExternalSecret of the app in the same cutover apply. If the new
  pods fail to go ready, helm-controller rolls back to the previous release, and the pods of that release still
  use `envFrom` on the secret. With the old `DATABASE_URL`/password gone, the rollback itself crashloops
  and wedges (`pending-rollback`). Keep the old keys in the ES template until the new release has
  gone `Ready` once, then remove them in a follow-up apply. Also, patching the _secret_ directly is
  futile, because ESO reverts drift on owned secrets within seconds. If you need a temporary shim, patch the ExternalSecret spec.

- All apps share one Dragonfly memory budget (`limits.memory: 512Mi` today). There is no per-app
  quota. A DB index only prevents key collisions, not eviction interference. If the working
  set of one app fills the cache, the eviction of Dragonfly can reclaim keys from the DB index of any other app. Revisit
  `resources.limits.memory` in `clusters/artemis/kubernetes/apps/database/dragonfly/cluster/dragonfly.yaml` once more
  than one or two apps are actually onboarded.
- Never reflect a cert-manager `isCA: true` secret cluster-wide. It contains `tls.key`, the
  private signing key of the CA, alongside `ca.crt`/`tls.crt`. Distribute the public cert only, through a
  trust-manager `Bundle` that sources `tls.crt` into a `ca.crt`-only secret.
- `Cluster.spec.certificates.serverCASecret` must reference a secret in the namespace of the Cluster
  that contains just `ca.crt`. Point it at the trust-manager bundle output (`root-ca`),
  never the raw CA secret name. A wrong value gives `Warning SecretNotFound` from cloudnative-pg,
  and `Cluster.status.conditions[Ready]` flips to `False`/`ClusterIsNotReady` even though pods stay
  `Running`.
- `monitoring.enablePodMonitor` is deprecated on `Cluster`/`Pooler`. Author a `PodMonitor`
  manually (`cnpg.io/cluster: postgres` selector) instead. The
  deprecation is on the CNPG API, not a chart version: `kubectl explain
  cluster.spec.monitoring.enablePodMonitor` says "Deprecated: This feature will be removed in an
  upcoming release. If you need this functionality, you can create a PodMonitor manually." The
  operator and the `cloudnative-pg` chart have separate versions. Do not conflate them.
- The ScheduledBackup cron runs in the local timezone of the pod (k8tz), not UTC. Trigger an on-demand
  `Backup` CR to test. Do not assume a schedule is overdue.
