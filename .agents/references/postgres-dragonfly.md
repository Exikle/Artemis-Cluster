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

    **Why `PG_APP` and not `APP`**: `components/volsync` already uses `${APP}` widely (PVC name,
    `${APP}-volsync` secret, `${APP}-dst`). An app using both components would need the two vars to
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

    | Index | App                         |
    | ----- | --------------------------- |
    | 0     | _(reserved — never assign)_ |

2. **Point the app's Redis/cache env directly** at `redis://dragonfly.database.svc:6379/<index>`
   (or the app's equivalent host/port/db-index fields — not all apps take a single URL).
3. **Drop the old sidecar/embedded Redis or Valkey container**, its config, and any PVC it had —
   Dragonfly needs none of that.

## Gotchas

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
