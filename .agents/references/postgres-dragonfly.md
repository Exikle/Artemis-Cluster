# Reference: Shared Postgres + Dragonfly — Artemis-Cluster

Shared CNPG Postgres cluster + shared Dragonfly, both in the `database` namespace. Base infra is
live (Phase 0 complete 2026-07-02) and **in production use**. This is the default data layer for new
apps — see `.agents/instructions/cluster-conventions.md` § Deployment Philosophy.

**On the shared Postgres cluster** — every app carrying `components/postgres/app` with `APP` in
its `ks.yaml` `postBuild`. There is no roster here on purpose; it changes with every onboarding:
`grep -rln 'components/postgres' kubernetes/apps/` for the tree, `kubectl get database -n database`
for what actually reconciled. Immich deliberately keeps its own Postgres.

**On the shared Dragonfly** (4 apps actually configured): `paperless` (media, index 1), `immich`
(default, 2), `tekton-runner` (forgejo, 4), `trawl` (media, 5). Index 3 is _allocated_ to `litellm`
but nothing sets it — the proxy has no index env var and falls through to index 0. The index table
further down is the authoritative list — this line is a summary and drifts first.

Every further app migration is its own session; this doc is what you need once you're doing one.

## What's live

- **Cluster**: `postgres` in `database` — `instances: 2` (HA, `primaryUpdateMethod: switchover`),
  `ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie` (Renovate moves this — read
  `.spec.imageName`, do not trust a version written here), VectorChord loaded via
  `postgresql.extensions` (so vector-search apps don't need a separate cluster fork).
  **`instances: 2` is the one structural difference from Frostlink**, which runs `instances: 1` on
  one node and therefore treats every image bump as a planned outage. Here an image bump is a
  switchover, so client-side blip tolerance is not the load-bearing concern it is there.
- **No pooler.** Apps connect straight to `postgres-rw` with a password over TLS. A `pooler-rw`
  pgbouncer sat in front of every app until 2026-09-01; it ran `poolMode: session`, so it gave no
  connection multiplexing, capped the fleet at `max_db_connections: 20` x2 against
  `max_connections: 200`, and its `pg_ident` map let the pooler cert authenticate as **any** role —
  terminating per-app cert isolation at pgbouncer. Removed; do not reintroduce one without a
  measured connection-count problem to point at.
- **Dragonfly**: `dragonfly` in `database` — 2 replicas (master + replica, operator-managed
  failover), `--cluster_mode=emulated --lock_on_hashtags --default_lua_flags=allow-undeclared-keys`
  for broad client compatibility. No auth, no persistence. Consumers: see the index table below.
- **Backups**: barman-cloud → Cloudflare R2 (`s3://artemis-kopiur/barman/`), daily schedule +
  on-demand `Backup` CRs. Restore-from-backup proven live (scratch cluster, deleted after).
- **CA chain**: `postgres-server-ca` / `postgres-client-ca` ClusterIssuers in `cert-manager`,
  distributed via **trust-manager** `Bundle`s (`root-ca`, `postgres-client-ca`) — public-cert-only
  secrets, cluster-wide. Never reflect the raw CA secrets (see Gotchas).

## Onboarding an app onto shared Postgres

1. **Add the app's role to the Cluster.** CNPG has no standalone `Role` CRD — edit
   `kubernetes/apps/database/postgres/cluster/cluster.yaml`'s `spec.managed.roles` and add:

    ```yaml
    - disablePassword: true
      ensure: present
      login: true
      name: <app>
      superuser: false
    ```

    Apply live, confirm the role exists, before the app's own `Database` CR can succeed — otherwise
    database creation fails with `role "<app>" does not exist (SQLSTATE 42704)`.

2. **Wire the app's `ks.yaml`** to use the onboarding component:

    ```yaml
    components:
        - ../../../../components/postgres/app
    postBuild:
        substitute:
            APP: *app
    ```

    **Four `../`, not three.** `../../../components/postgres/app` resolves outside the kustomize
    root and the build fails. Every live consumer uses `../../../../`, the same depth as
    `../../../../components/kopiur/backup`.

    **`PG_APP` is now optional** — it defaults to `${APP}`. Set it only when the database name
    genuinely differs from the app name. But **every app must set `APP`**, even one that does not
    use kopiur: Flux's envsubst is strict and evaluates both halves of `${PG_APP:=${APP}}`, so an
    app setting only `PG_APP` fails its whole post-build with
    `variable not set (strict mode): "APP"` and takes anything that `dependsOn` it down with it.

3. **The namespace needs `components/postgres/tenants`** in `kubernetes/apps/<ns>/kustomization.yaml`,
   exactly like `components/kopiur/secret`. It creates one `ResourceSet` per namespace, which watches
   for the input providers the app component emits and templates the `Database` CR and role Secret
   into `database`.

    A `ResourceSet`'s `inputsFrom` selects providers **in its own namespace only** — that is why the
    ResourceSet lives beside the apps and writes _across_ to `database`, rather than the reverse.

    Two traps: a namespace carrying `tenants` with **no app using it yet** has a ResourceSet with zero
    inputs, and `flate` then fails the _entire namespace_ with `map has no entry for key "name"`. And
    never name a component-generated input provider bare `${APP}` — `cortex/memini` already owns one
    called `memini` for its litellm virtual key, so the postgres provider is `${APP}-postgres`.

4. **What the component creates**: a `ResourceSetInputProvider` (`<app>-postgres`) in the app's
   namespace, a `<app>-postgres` Secret with the credentials and DSNs, a `<app>-postgres` ConfigMap
   with the libpq SSL env, and — via the namespace ResourceSet — a `Database` CR named `<app>` plus a
   `<app>-postgres` role Secret in `database`.

    **Connect using the Secret, not the ConfigMap.** The Secret and ConfigMap share the name, so a
    consumer switching from the old cert component changes `configMapKeyRef` to `secretKeyRef` and
    keeps `key: url`.

    **There are three DSN keys, because three drivers disagree.** Pick by driver, not by taste:

    | Key          | For                       | Shape                                                                        |
    | ------------ | ------------------------- | ---------------------------------------------------------------------------- |
    | `url`        | libpq, pgx, node-postgres | `?sslmode=verify-full&sslrootcert=<CA path>`                                 |
    | `url_node`   | postgres-js               | `?sslmode=verify-full` only; CA via `NODE_EXTRA_CA_CERTS`                    |
    | `url_prisma` | Prisma                    | `?sslmode=verify-full&sslcert=<CA path>` — `sslcert` means the **root** cert |

    Getting this wrong is not a soft failure. **postgres-js forwards unknown connection-string params
    to the server as startup parameters**, so a libpq-shaped DSN gets
    `unrecognized configuration parameter "sslrootcert"` and the app never connects — it cost
    streamystats an outage. Prisma is the opposite: it silently drops what it does not recognise, so a
    wrong DSN there fails _open_, connecting without verifying.

    Discrete fields are also on the Secret (`POSTGRES_HOST`/`PORT`/`DATABASE`/`USERNAME`/`PASSWORD`)
    for apps that take host/user/password separately rather than a URL.

    `<owner>` is `${DATABASE_OWNER}`, which defaults to `${PG_APP:=${APP}}` — set it only when the
    role name differs from the database name.

5. **Pod won't start until Postgres is ready** — the component adds `ksgate`
   (`k8s.ksgate.org/*`) scheduling gates so the app's pod stays `SchedulingGated` until the shared
   Cluster has ≥1 ready instance, the `postgres-rw` Service exists, and the app's `Database` CR shows
   `status.applied: true`. This is expected, not a stuck pod.

## There are no pgbouncer sidecars any more

Five apps once ran a pgbouncer sidecar — litellm, streamystats, sonarr, radarr, prowlarr — purely
because their drivers could not present a PEM **client cert**. Password auth removed the reason and
all five sidecars are gone (2026-09-01). Do not add one back to solve a TLS problem; solve it with
the right DSN key from the table above.

The belief that Servarr needed a sidecar for TLS was wrong and worth recording. `strings
Sonarr.Core.dll` shows only `PostgresHost/Port/User/Password/MainDb` — there is genuinely no
`SslMode` option — but **Npgsql negotiates TLS against a `hostssl` line anyway**. The proof is that a
failing connection reaches `Npgsql.Internal.NpgsqlConnector.AuthenticateSASL`, which only happens
after a successful handshake, and `pg_stat_ssl` then reports `ssl=t` for the role.

**Servarr logs its connection string, password included, at Info level on every startup**
(`MigrationController: *** Migrating Database=...;Password=... ***`), and pod logs ship to
VictoriaLogs. The fleet currently shares one password, so that single log line is the credential for
every role. Accepted deliberately for a LAN homelab; worth remembering before treating log access as
low-sensitivity.

### CR-based apps get the Database CR, but not the pod patch

`components/postgres/app/patch` targets `kind: HelmRelease` only. An app deployed as a **custom
resource** still gets everything the ResourceSet makes — the `Database` CR, the role Secret, its own
input provider and app-namespace Secret — because those are plain resources, not patches. What it
does **not** get is the ksgate scheduling gates and the server-CA volume mount.

So a CR app declares its own mount. `security/pocket-id` (a `PocketIDInstance`) and `cortex/litellm`
(a `LiteLLMProxy`) both do. Missing it is a silent failure: `verify-full` has no CA to check against.

`cortex/litellm` is the case worth reading. It carried `skip-cert-patch` under the old component, so
it had **no CA mounted at all** — it leaned entirely on its pgbouncer sidecar for TLS. Removing the
sidecar meant declaring `spec.volumes` and `spec.volumeMounts` on the CR itself. Its annotation is
now `postgres.dcunha.io/skip-patch`, and it uses the `url_prisma` DSN key.

The old escape route for Prisma — cert-manager's `spec.keystores.pkcs12` plus
`sslidentity=…/keystore.p12` — is no longer needed and was never attempted. Password auth made it
moot.

## Onboarding an app onto shared Dragonfly

Pure config cutover, no data migration, no kustomize component — it's a cache with no auth and
nothing to provision per app. No scheduling gate either — deliberately: unlike Postgres (a hard
dependency — the app's `Database` CR and role password must exist before it can even authenticate), a
cache is a soft dependency that Redis-protocol clients already retry/reconnect on their own. Modeled
on [mortebrume/homelab](https://github.com/mortebrume/homelab), which runs 8 apps against a shared
Dragonfly this way with no gating at all.

1. **Claim the next unused index** from the table below and add a row for the app. Index `0` is
   reserved and never assigned, so a pod that forgot to configure an index (silently defaulting to
   `0`) is immediately obvious rather than colliding with a real app.

    This table is an **allocation registry**, not a derived list — an index held for an app that
    has not configured it yet exists nowhere else and cannot be grepped. Key counts are
    deliberately not recorded; `redis-cli INFO keyspace` (below) answers that live.

    | Index | App                                                        | Where the index is set                     |
    | ----- | ---------------------------------------------------------- | ------------------------------------------ |
    | 0     | _(reserved — never assign)_                                | —                                          |
    | 1     | paperless                                                  | `PAPERLESS_REDIS` URL suffix `/1`          |
    | 2     | immich                                                     | `REDIS_DBINDEX: "2"` (app + microservices) |
    | 3     | litellm — **claimed, not configured**                      | nothing sets it — see below                |
    | 4     | tekton-runner (forgejo-tekton-runner failover checkpoints) | `RUNNER_REDIS_URL` suffix `/4`             |
    | 5     | trawl (Cloudflare bypass session cache)                    | `REDIS_URL` suffix `/5`                    |

    **`LiteLLMProxy` sets `REDIS_HOST`/`REDIS_PORT` only — there is no index env var**, so litellm
    resolves to db **0**, the index this table reserves as the forgot-to-configure tripwire. `db3`
    did not exist in `INFO keyspace` when this was last checked and `db0` was empty, so litellm was
    not caching at all; nothing is corrupted and nothing collides. Read the row above as an allocation held for
    litellm, not a fact about the running proxy. Before claiming index 3 for anything else, check
    whether a `REDIS_DB`-equivalent has been added to the `LiteLLMProxy` CRD.

    Verify an app's index the same way — the manifest can lie, the keyspace cannot:

    ```bash
    kubectl -n database exec dragonfly-0 -c dragonfly -- redis-cli INFO keyspace
    ```

2. **Point the app's Redis/cache env directly** at `redis://dragonfly.database.svc:6379/<index>`
   (or the app's equivalent host/port/db-index fields — not all apps take a single URL).
3. **Drop the old sidecar/embedded Redis or Valkey container**, its config, and any PVC it had —
   Dragonfly needs none of that.

## R2 backup sizing — why the WAL settings are what they are

Audited 2026-08-05, when the `artemis-kopiur` bucket hit 45.3 GiB / 13,481 objects with barman as
its only consumer. The breakdown was lopsided:

| Prefix                     | Size     | Objects |
| -------------------------- | -------- | ------- |
| `barman/postgres` WAL      | 33.1 GiB | 11,242  |
| `immich-pg18` base backups | 8.8 GiB  | 62      |
| `barman/postgres` base     | 2.0 GiB  | 62      |
| orphaned pre-pg18 prefixes | 1.2 GiB  | 251     |

**WAL, not base backups, was 73% of the bucket** — and the whole `postgres` cluster is only ~320 MB
of actual data across all databases. It was generating ~2.2 GiB of WAL per day, roughly 7× the
entire database, every day.

`pg_stat_wal` explained it: 942,903 full-page images accounting for ~90% of 7.36 GB of `wal_bytes`.
Postgres writes a full 8 KiB page image the first time a page is touched after each checkpoint, and
`checkpoint_timeout` was at the 5-minute default with 727 of 736 checkpoints timed rather than
size-driven. A small, constantly-rewritten working set was therefore being re-imaged into WAL 288
times a day. **`checkpoint_timeout: 30min` is the fix that actually reduces bytes** — it cuts how
often those page images are re-emitted. `max_wal_size: 2GB` is headroom so checkpoints stay
timed-driven rather than flipping to size-driven at the longer interval.

**`wal_compression` was deliberately not enabled.** It compresses full-page images inside the WAL
record, but the ObjectStore already applies `wal: compression: zstd` to the whole segment, which
captures nearly the same ratio — the segments were already compressing ~5:1 (16 MiB → 2-4 MiB).
Turning it on would mostly move the compression earlier without shrinking what lands in R2. It is
still worth considering if local `pg_wal` volume or replication bandwidth ever becomes the concern.

**`archive_timeout: 900s` is an object-count lever, not a byte lever.** It forces a segment upload
even when the segment isn't full, so the old 300s value put a hard floor of 288 uploads/day under
the bucket regardless of activity — the reason WAL objects outnumbered everything else 100:1. The
unused tail of a force-switched segment is zero-padding that compresses to almost nothing, so
raising it saves operations far more than storage. The tradeoff is off-site RPO: R2 can now be up
to 15 minutes stale. Local durability is unaffected — `postgres` runs `instances: 2` with streaming
replication, so R2 is the both-nodes-lost copy, not the first line of recovery.

Retention on both ObjectStores is `7d`. Immich's base backups are ~291 MiB each and near-identical
day to day, so retention is the only meaningful lever there; its WAL is negligible (182 MiB), which
is why it gets `archive_timeout` but not the checkpoint tuning.

**Orphaned prefixes are never reclaimed by `retentionPolicy`.** Barman only expires servers it
still manages, so `barman/immich-pg`, `barman/immich-pg17`, and `barman/postgres-restore-test` —
left behind by the pg16→17→18 migrations and the restore test — sat there indefinitely with no
ObjectStore, Cluster, or repo reference pointing at them. After a major-version migration or a
restore test, delete the old prefix out of R2 by hand; nothing in the cluster will do it for you.

## Dedicated CNPG clusters — the exception

**A per-app `Cluster` is not the default and has not been since 2026-07-02.** The old
`cnpg-database` skill taught "one Cluster per app — never shared" with `username`/`password`
ExternalSecrets; that policy is superseded by the shared cluster + direct cert auth
described above, and the skill was retired on 2026-08-21. Only `immich` still runs a dedicated
cluster, for extension and Postgres-version reasons.

Confirmed live 2026-08-21 — exactly two CNPG `Cluster`s exist:

| Cluster       | Namespace  | Instances | Image                                                      | ObjectStore                                                        |
| ------------- | ---------- | --------- | ---------------------------------------------------------- | ------------------------------------------------------------------ |
| `postgres`    | `database` | 2         | `ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie`   | `r2-store` → `s3://artemis-kopiur/barman/`                         |
| `immich-pg18` | `default`  | 1         | `docker.io/tensorchord/cloudnative-vectorchord:18.4-1.1.1` | `immich-pg18-r2-store` → `s3://artemis-kopiur/barman/immich-pg18/` |

Note the exception is named **`immich-pg18` and lives in `default`**, not `immich` in a namespace
of its own — the `-pg18` suffix is a migration artifact and is baked into its R2 prefix, so
renaming the Cluster orphans the whole barman server (see § Orphaned prefixes).

### Retiring an app's own Postgres leaves its PVC behind

The migration off per-app databases deletes the StatefulSet, not the claim. `ceph-block` is
`reclaimPolicy: Delete`, but that only fires on PVC deletion — an unreferenced claim is held
forever, at 3× replication on a ~238 GiB usable cluster, and it looks identical to a healthy one
in `kubectl get pvc`. **Delete the PVC as the last step of any migration off a per-app database.**

The live orphan inventory is kept in one place only — `storage.md` § Orphaned PVCs — which also
has the pod-volume diff that finds them. The ones already missed are tracked in
[#1889](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/1889).

Stand up a dedicated cluster only when the app genuinely cannot share — an extension the shared
cluster does not load, a major-version pin, or a hard isolation requirement — and say why in the
commit. If you do:

| Rule                                    | Why                                                                                                                                                                                                       |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Always give it its own `walStorage`** | If WAL shares the data disk and archiving lags (or is not configured), WAL fills the data PVC and the pod enters CrashLoopBackOff. A separate volume turns a cluster-down into a stalled-archive warning. |
| Connect via `<name>-rw`                 | CNPG auto-creates `<name>-rw` (read-write) and `<name>-ro`. `<name>` alone is not a Service.                                                                                                              |
| Back the data PVC up with kopiur        | Add `../../../../components/kopiur/backup` and point it at the CNPG PVC (`<name>-1`).                                                                                                                     |

### Common issues — dedicated or shared

| Symptom                          | Cause                                            | Fix                                                                                      |
| -------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Pod stuck `Pending`              | `ceph-block` PVC not bound                       | Check RBD CSI pods in `rook-ceph` — use the `rbd-csi-recovery` skill                     |
| `role "<app>" does not exist`    | Role not added to `spec.managed.roles`           | Step 1 of onboarding; apply and confirm the role before the `Database` CR                |
| `password authentication failed` | App is using password auth against `postgres-rw` | `pg_hba` is `cert clientcert=verify-full` — there is no password. Use the cert component |
| WAL directory fills              | No separate `walStorage` volume                  | Add `walStorage` and reapply                                                             |
| Cluster stuck `Initializing`     | CRD not installed                                | `kubectl get crd clusters.postgresql.cnpg.io`                                            |
| App can't connect                | Wrong Service name                               | `postgres-rw.database.svc.cluster.local` for shared; `<name>-rw` for dedicated           |

## Gotchas

- **`DATABASE_EXTENSIONS` in the component is effectively dead.** The `Database` CR template has
  `extensions: ${DATABASE_EXTENSIONS:=[]}`, but there's no way to thread a YAML list through the
  parent ks → nested ks substitution chain: Flux's envsubst is text-level, so the flow-list string
  re-parses as a real YAML list inside `postBuild.substitute` (which must be strings) — quoted and
  block-scalar forms get normalized away too. Instead, `CREATE EXTENSION` once as superuser on the
  app's database right after the `Database` CR applies. Extensions persist, and barman backups are
  physical, so they survive restores. (Hit with streamystats: `pg_trgm`, `uuid-ossp`, `vector`.)
- **Don't strip old-DB keys from the app's ExternalSecret in the same cutover apply.** If the new
  pods fail to go ready, helm-controller rolls back to the previous release — whose pods still
  `envFrom` the secret. With the old `DATABASE_URL`/password gone, the rollback itself crashloops
  and wedges (`pending-rollback`). Keep the old keys in the ES template until the new release has
  gone `Ready` once, then remove them in a follow-up apply. Also: patching the _secret_ directly is
  futile — ESO reverts drift on owned secrets within seconds; patch the ExternalSecret spec if a
  temporary shim is needed.

- **All apps share one Dragonfly memory budget** (`limits.memory: 512Mi` today). There's no per-app
  quota — a DB index only prevents key collisions, not eviction interference. If one app's working
  set fills the cache, Dragonfly's eviction can reclaim keys from any other app's DB index. Revisit
  `resources.limits.memory` in `kubernetes/apps/database/dragonfly/cluster/dragonfly.yaml` once more
  than one or two apps are actually onboarded.
- **Never reflect a cert-manager `isCA: true` secret cluster-wide.** It contains `tls.key` — the
  CA's private signing key — alongside `ca.crt`/`tls.crt`. Distribute the public cert only, via a
  trust-manager `Bundle` sourcing `tls.crt` into a `ca.crt`-only secret.
- **`Cluster.spec.certificates.serverCASecret` must reference a secret in the Cluster's own
  namespace** containing just `ca.crt` — point it at the trust-manager bundle output (`root-ca`),
  never the raw CA secret name. Wrong value → `Warning SecretNotFound` from cloudnative-pg,
  `Cluster.status.conditions[Ready]` flips to `False`/`ClusterIsNotReady` even though pods stay
  `Running`.
- **`monitoring.enablePodMonitor` is deprecated on `Cluster`/`Pooler`** — author a `PodMonitor`
  manually (`cnpg.io/cluster: postgres` selector) instead. The
  deprecation is on the **CNPG API**, not a chart version: `kubectl explain
cluster.spec.monitoring.enablePodMonitor` says "Deprecated: This feature will be removed in an
  upcoming release. If you need this functionality, you can create a PodMonitor manually." Both
  clusters run operator **1.30.0** from `cloudnative-pg` chart **0.29.0** — do not conflate the
  two numbers, they version different things.
- **`just kube sync ocirepo` does not sync the `flux-system` git-source OCIRepository** — only
  app/chart OCIRepositories. After pushing, if a Kustomization needs the new revision immediately
  (e.g. testing a nested-Kustomization pattern), force it directly:
  `kubectl -n flux-system annotate ocirepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`.
- **ScheduledBackup cron runs in the pod's local timezone** (k8tz), not UTC — trigger an on-demand
  `Backup` CR to test rather than assuming a schedule is overdue.
- **pgbouncer caches backend auth failures** — after fixing a role/cert issue, restart the app's
  pgbouncer sidecar, don't just wait. (This used to mean the shared `pooler-rw` pods; since its
  removal the only pgbouncers left are the per-app sidecars.)
