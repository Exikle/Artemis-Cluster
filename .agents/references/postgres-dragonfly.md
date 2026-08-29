# Reference: Shared Postgres + Dragonfly — Artemis-Cluster

Shared CNPG Postgres cluster + shared Dragonfly, both in the `database` namespace. Base infra is
live (Phase 0 complete 2026-07-02) and **in production use**. This is the default data layer for new
apps — see `.agents/instructions/cluster-conventions.md` § Deployment Philosophy.

**On the shared Postgres cluster** (6 apps, each with `PG_APP` in its `ks.yaml` `postBuild`):
`memini` (cortex), `apoci` (fediverse), `paperless` / `streamystats` / `bookboss` (media),
`pocket-id` (security). Immich deliberately keeps its own Postgres.

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
- **Pooler**: `pooler-rw` — pgbouncer, session pooling, cert-based auth only (`auth_type: cert`).
  Apps always connect through the pooler, never `postgres-rw` directly.
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
        - ../../../../components/postgres/cert
    postBuild:
        substitute:
            APP: *app
            PG_APP: <app>
    ```

    **Four `../`, not three.** `../../../components/postgres/cert` resolves outside the kustomize
    root and the build fails. Every live consumer uses `../../../../`, the same depth as
    `../../../../components/kopiur/backup`.

    Use `postgres/cert` (not `postgres/base` directly) for any app with a HelmRelease — it pulls in
    `base` automatically and also patches in the ksgate scheduling gates + cert/CA volume mounts.
    `postgres/base` alone is only useful for exercising the `Database` CR in isolation (e.g. a
    scratch test).

    **Why `PG_APP` and not `APP`**: `components/kopiur/backup` already uses `${APP}` widely (PVC name,
    `${APP}` PVC, Restore and SnapshotPolicy names). An app using both components would need the two vars to
    carry _different_ values in real cases (confirmed on Frostlink: `APP: apoci` + a differently-named
    backup var for the same app were genuinely different strings, not a redundant duplicate) — so the
    postgres component deliberately uses its own `${PG_APP}` var instead of reusing `${APP}`.

3. **What the component creates**: a `Database` CR (via a nested Kustomization-that-creates-a-
   Kustomization — CNPG's `Database` resource, name `postgres-<app>`), a per-app client `Certificate`
   (`postgres-<app>-cert`, issued from `postgres-client-ca`), and a `<app>-postgres` ConfigMap with
   the connection URL.

4. **Connect using the DSN ConfigMap**, not manual host/port/user env vars. Key `url`:

    ```
    postgresql://<owner>@pooler-rw.database.svc:5432/<app>?sslmode=verify-full&sslcert=/var/run/secrets/postgresql/tls.crt&sslkey=/var/run/secrets/postgresql/tls.key&sslrootcert=/var/run/secrets/postgres-server-ca/ca.crt
    ```

    No password — auth is entirely cert-based (`clientcert=verify-full`). The component mounts the
    client cert at `/var/run/secrets/postgresql` and the server CA at
    `/var/run/secrets/postgres-server-ca` automatically via `persistence` in the HelmRelease patch.
    `<owner>` is `${DATABASE_OWNER}`, which defaults to `${PG_APP}` — set it only when the role
    name differs from the database name.

    **The CA secret is `postgres-server-ca` here, `root-ca` on Frostlink.** Both are
    trust-manager `Bundle` outputs holding `ca.crt` only, and both mount at a path named after the
    secret, so the DSNs differ in two places at once:

    |                                | Artemis                                      | Frostlink                         |
    | ------------------------------ | -------------------------------------------- | --------------------------------- |
    | trust-manager bundle / secret  | `postgres-server-ca`                         | `root-ca`                         |
    | `sslrootcert` path             | `/var/run/secrets/postgres-server-ca/ca.crt` | `/var/run/secrets/root-ca/ca.crt` |
    | substitute var for the DB name | `${PG_APP}`                                  | `${APP}`                          |

    An earlier revision of this doc carried Frostlink's `root-ca` path. Copying a DSN across repos
    fails at the TLS handshake with `root certificate file "…/root-ca/ca.crt" does not exist` —
    late, at connect time, not at apply time.

5. **Pod won't start until Postgres is ready** — the component adds `ksgate`
   (`k8s.ksgate.org/*`) scheduling gates so the app's pod stays `SchedulingGated` until the shared
   Cluster has ≥1 ready instance, the `pooler-rw` Service exists, and the app's `Database` CR shows
   `status.applied: true`. This is expected, not a stuck pod.

## Cert-incapable apps (postgres-js): pgbouncer sidecar

Not every client can do cert auth. Check the app's driver **before** cutover:

- **libpq / pgx / node-postgres (`pg`)** — read `sslcert`/`sslkey`/`sslrootcert` from the DSN; the
  standard component DSN works as-is (apoci).
- **postgres-js (porsager)** — cannot present a client cert at all: ignores those DSN params, no
  env knob. `NODE_EXTRA_CA_CERTS` only fixes _server_ trust (error changes from
  `UNABLE_TO_VERIFY_LEAF_SIGNATURE` to `certificate required`); nothing fixes the client side.

For postgres-js apps, add a **pgbouncer sidecar** that owns the client cert and speaks plaintext on
loopback (streamystats is the reference implementation — `media/streamystats/app/resources/`):

- Image `ghcr.io/cloudnative-pg/pgbouncer` (same as the pooler), `command: ["pgbouncer",
"/etc/pgbouncer/pgbouncer.ini"]`, config + userlist from a `configMapGenerator` with
  `substitute: disabled`.
- ini essentials: `listen_addr = 127.0.0.1` (never wider — auth is `trust`), `unix_socket_dir =`
  (empty, keeps rootfs read-only), `auth_type = trust`, `pool_mode = session`,
  `server_tls_sslmode = verify-full` + the three `server_tls_*_file` paths from the component's
  mounts. The `[databases]` entry pins `host=pooler-rw.database.svc user=<app>`.
- App's `DATABASE_URL` becomes `postgresql://<app>@localhost:5432/<app>` (plain env, not the
  component ConfigMap). The component still does everything else (Database CR, cert, gates).
- Readiness probe must be `exec: pg_isready -h 127.0.0.1 -p 5432 -d <app> -U <app>` — a
  `tcpSocket` probe dials the **pod IP**, which a loopback-only listener never answers.

### CR-based apps: the component now patches them too, but check the client first

`components/postgres/base/patch` originally patched only `kind: HelmRelease`, injecting
app-template values (`defaultPodOptions`, `schedulingGates`, `persistence`). An app deployed as a
**custom resource** therefore received only the `Database` CR — no cert mounts, no gates, no
error, and Flux green throughout.

Fixed 2026-08-29: the component carries a second patch target for `LiteLLMProxy`, which supports
`volumes`, `volumeMounts` and `podAnnotations`. Kustomize tolerates a target that matches nothing,
so the same `postgres/cert` component now works for both HelmRelease and CR apps. Adding another
CR kind means adding another target block, not a new component.

**One thing the CR path cannot deliver:** `LiteLLMProxy` has no `schedulingGates` field, so the
three ksgate gates are HelmRelease-only. That is startup ordering, not correctness — a CR app
retries until Postgres is up.

**Check the client's TLS support before assuming the cert is usable.** The component's DSN is
libpq-shaped (`sslcert` + `sslkey` + `sslrootcert`). Not every driver reads it:

| Driver                      | Client certs     | Notes                                                                                                                                                                                                                                                                       |
| --------------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| libpq / pgx / node-postgres | yes              | the component DSN works as-is                                                                                                                                                                                                                                               |
| postgres-js (porsager)      | no               | needs the pgbouncer sidecar above                                                                                                                                                                                                                                           |
| **Prisma** (litellm)        | **not this way** | supports `sslcert` (meaning the _root_ cert) and `sslidentity` (a **PKCS#12** bundle). There is no `sslkey` and no `sslrootcert`, and unknown params are silently dropped — the engine logs `Discarding connection string param`. Verified against the query-engine binary. |

So `cortex/litellm` runs the pgbouncer sidecar because **Prisma cannot consume a PEM client key**,
not because the component failed to reach it. It opts out explicitly with
`postgres.dcunha.io/skip-cert-patch: "prisma-has-no-sslkey"` on its `LiteLLMProxy`, which is the
same escape hatch the HelmRelease patch has always honoured.

If someone wants to delete that detour later, the route is cert-manager's
`spec.keystores.pkcs12` to emit a `keystore.p12` alongside the PEMs, then
`sslidentity=/var/run/secrets/postgresql/keystore.p12` plus `sslpassword`. Not attempted — it
changes the DB path of the app the whole MCP layer depends on.

## Onboarding an app onto shared Dragonfly

Pure config cutover, no data migration, no kustomize component — it's a cache with no auth and
nothing to provision per app. No scheduling gate either — deliberately: unlike Postgres (a hard
dependency — the app's `Database` CR and client cert must exist before it can even authenticate), a
cache is a soft dependency that Redis-protocol clients already retry/reconnect on their own. Modeled
on [mortebrume/homelab](https://github.com/mortebrume/homelab), which runs 8 apps against a shared
Dragonfly this way with no gating at all.

1. **Claim the next unused index** from the table below and add a row for the app. Index `0` is
   reserved and never assigned, so a pod that forgot to configure an index (silently defaulting to
   `0`) is immediately obvious rather than colliding with a real app.

    | Index | App                                                        | Where the index is set                     | Live keys (2026-08-21) |
    | ----- | ---------------------------------------------------------- | ------------------------------------------ | ---------------------- |
    | 0     | _(reserved — never assign)_                                | —                                          | 0                      |
    | 1     | paperless                                                  | `PAPERLESS_REDIS` URL suffix `/1`          | 15                     |
    | 2     | immich                                                     | `REDIS_DBINDEX: "2"` (app + microservices) | 67                     |
    | 3     | litellm — **claimed, not configured**                      | nothing sets it — see below                | absent                 |
    | 4     | tekton-runner (forgejo-tekton-runner failover checkpoints) | `RUNNER_REDIS_URL` suffix `/4`             | 71                     |
    | 5     | trawl (Cloudflare bypass session cache)                    | `REDIS_URL` suffix `/5`                    | 2                      |

    **`LiteLLMProxy` sets `REDIS_HOST`/`REDIS_PORT` only — there is no index env var**, so litellm
    resolves to db **0**, the index this table reserves as the forgot-to-configure tripwire. `db3`
    does not exist in `INFO keyspace` and `db0` holds 0 keys, so litellm is not caching at all
    today; nothing is corrupted and nothing collides. Read the row above as an allocation held for
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
ExternalSecrets; that policy is superseded by the shared cluster + `pooler-rw` + cert auth
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

The migration off per-app databases deletes the StatefulSet, not the claim. Three orphans remain on
`ceph-block` with no consumer, verified 2026-08-21: `media/data-streamystats-vectorchord-0` (10Gi),
`media/data-rreading-glasses-postgres-0` (5Gi), `tekton-system/postgredb-tekton-results-postgres-0`
(1Gi). `ceph-block` is `reclaimPolicy: Delete`, but that only fires on PVC deletion — an
unreferenced claim is held forever, at 3× replication on a ~238 GiB usable cluster. **Delete the
PVC as the last step of any migration off a per-app database**, and see
`storage.md` § Orphaned PVCs for how to find the ones already missed.

Stand up a dedicated cluster only when the app genuinely cannot share — an extension the shared
cluster does not load, a major-version pin, or a hard isolation requirement — and say why in the
commit. If you do:

| Rule                                    | Why                                                                                                                                                                                                       |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Always give it its own `walStorage`** | If WAL shares the data disk and archiving lags (or is not configured), WAL fills the data PVC and the pod enters CrashLoopBackOff. A separate volume turns a cluster-down into a stalled-archive warning. |
| Connect via `<name>-rw`                 | CNPG auto-creates `<name>-rw` (read-write) and `<name>-ro`. `<name>` alone is not a Service.                                                                                                              |
| Back the data PVC up with kopiur        | Add `../../../../components/kopiur/backup` and point it at the CNPG PVC (`<name>-1`).                                                                                                                     |

### Common issues — dedicated or shared

| Symptom                          | Cause                                          | Fix                                                                            |
| -------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------ |
| Pod stuck `Pending`              | `ceph-block` PVC not bound                     | Check RBD CSI pods in `rook-ceph` — use the `rbd-csi-recovery` skill           |
| `role "<app>" does not exist`    | Role not added to `spec.managed.roles`         | Step 1 of onboarding; apply and confirm the role before the `Database` CR      |
| `password authentication failed` | App is using password auth against `pooler-rw` | The pooler is `auth_type: cert` — there is no password. Use the cert component |
| WAL directory fills              | No separate `walStorage` volume                | Add `walStorage` and reapply                                                   |
| Cluster stuck `Initializing`     | CRD not installed                              | `kubectl get crd clusters.postgresql.cnpg.io`                                  |
| App can't connect                | Wrong Service name                             | `pooler-rw.database.svc.cluster.local` for shared; `<name>-rw` for dedicated   |

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
  manually (`cnpg.io/cluster: postgres` / `cnpg.io/poolerName: pooler-rw` selectors) instead. The
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
- **pgbouncer caches backend auth failures** — after fixing a role/cert issue, restart the pooler
  pods (`pooler-rw-*`), don't just wait.
