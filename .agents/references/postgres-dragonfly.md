# Reference: Shared Postgres + Dragonfly — Artemis-Cluster

Shared CNPG Postgres cluster + shared Dragonfly, both in the `database` namespace. Base infra is
live (Phase 0 complete 2026-07-02) — no apps have been cut over yet. Every app migration is its own
session; this doc is what you need once you're doing one.

## What's live

- **Cluster**: `postgres` in `database` — `instances: 2` (HA, `primaryUpdateMethod: switchover`),
  `ghcr.io/cloudnative-pg/postgresql:18.4-standard-trixie`, VectorChord loaded via
  `postgresql.extensions` (so vector-search apps don't need a separate cluster fork).
- **Pooler**: `pooler-rw` — pgbouncer, session pooling, cert-based auth only (`auth_type: cert`).
  Apps always connect through the pooler, never `postgres-rw` directly.
- **Dragonfly**: `dragonfly` in `database` — 2 replicas (master + replica, operator-managed
  failover), `--cluster_mode=emulated --lock_on_hashtags --default_lua_flags=allow-undeclared-keys`
  for broad client compatibility. No auth, no persistence. Empty, no consumers yet.
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
        - ../../../components/postgres/cert
    postBuild:
        substitute:
            PG_APP: <app>
    ```

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
    postgresql://<owner>@pooler-rw.database.svc:5432/<app>?sslmode=verify-full&sslcert=/var/run/secrets/postgresql/tls.crt&sslkey=/var/run/secrets/postgresql/tls.key&sslrootcert=/var/run/secrets/root-ca/ca.crt
    ```

    No password — auth is entirely cert-based (`clientcert=verify-full`). The component mounts the
    client cert at `/var/run/secrets/postgresql` and the root CA at `/var/run/secrets/root-ca`
    automatically via `persistence` in the HelmRelease patch.

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

    | Index | App                                                              |
    | ----- | ---------------------------------------------------------------- |
    | 0     | _(reserved — never assign)_                                      |
    | 1     | paperless                                                        |
    | 2     | immich                                                           |
    | 3     | litellm (shared by all 3 `LiteLLMProxy` tiers — one logical app) |
    | 4     | tekton-runner (forgejo-tekton-runner failover checkpoints)       |
    | 5     | trawl (Cloudflare bypass session cache)                          |

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
  manually (`cnpg.io/cluster: postgres` / `cnpg.io/poolerName: pooler-rw` selectors) instead.
- **`just kube sync ocirepo` does not sync the `flux-system` git-source OCIRepository** — only
  app/chart OCIRepositories. After pushing, if a Kustomization needs the new revision immediately
  (e.g. testing a nested-Kustomization pattern), force it directly:
  `kubectl -n flux-system annotate ocirepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`.
- **ScheduledBackup cron runs in the pod's local timezone** (k8tz), not UTC — trigger an on-demand
  `Backup` CR to test rather than assuming a schedule is overdue.
- **pgbouncer caches backend auth failures** — after fixing a role/cert issue, restart the pooler
  pods (`pooler-rw-*`), don't just wait.
