# Cluster Conventions — Artemis-Cluster

## App Directory Structure (canonical)

```text
kubernetes/apps/<namespace>/<app>/
├── ks.yaml                  # Flux Kustomization — dependsOn, kopiur component, PVC size
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml   # standalone OCIRepository — every app gets its own
    ├── helmrelease.yaml     # HTTPRoutes defined in values here, not separate files
    └── externalsecret.yaml  # only if secrets needed
```

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources.

## Helm / app-template v5

- Chart: `oci://ghcr.io/bjw-s-labs/helm/app-template` tag `5.0.1` (note: `-labs`, not `-bjw-s`)
- Every app gets its own standalone `OCIRepository` — never share or reuse one
- `chartRef` in HelmRelease: `kind: OCIRepository, name: <app>`
- OCIRepository API version: `source.toolkit.fluxcd.io/v1` (not `v1beta2`)
- Reloader: `reloader.stakater.com/auto: "true"` annotation on controller
- Default security context: `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch`
- Container security: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: {drop: ["ALL"]}`
- Routes: defined inline under `route.app:` in helmrelease values — NOT as standalone HTTPRoute files
- PVC: `existingClaim: <app>` when using the kopiur component
- NFS media: `server: 10.10.99.100, path: /mnt/atlas/media` → `/media`

## Secrets

- SOPS is fully removed — never suggest age encryption or `sops --encrypt`
- All secrets: 1Password ExternalSecret with `ClusterSecretStore: onepassword-connect`
- ExternalSecret API version: `external-secrets.io/v1`
- `dataFrom.extract.key: <1password-item-name>` pulls all fields from item
- Template field names must exactly match 1Password field names — mismatch = empty secret, no error

## Deployment Philosophy

**Shared data layer first.** Superseded the earlier silo-first policy on 2026-07-02 — the shared
CNPG cluster and shared Dragonfly in the `database` namespace are the default for new apps.

| Need                  | Preferred approach                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------ |
| Relational DB         | Shared CNPG cluster via `pooler-rw` (add the `postgres` component + `PG_APP` substitution) |
| Redis / queue / cache | Shared Dragonfly at `dragonfly.database.svc.cluster.local:6379` — no auth, no persistence  |
| Multi-component apps  | Split into separate kustomizations (e.g. Immich: database / app / microservices / ml)      |

Onboarding steps, DSN format, and the cert-auth gotchas: `.agents/references/postgres-dragonfly.md`.

**Dedicated instances remain the exception, not the rule** — justified only when an app cannot share
(Immich runs its own Postgres for extension and version reasons). Do not stand up a per-app CNPG
cluster or a sidecar Redis without a specific reason to.

An app that supports SQLite may still use it — that avoids a dependency entirely. The change from
the old policy is what happens when a real database _is_ needed: share, don't silo.

## Common Mistakes — Quick Reference

| Pattern                           | Correct                                                         | Wrong                                   |
| --------------------------------- | --------------------------------------------------------------- | --------------------------------------- |
| Secret store name                 | `onepassword-connect`                                           | `onepassword`, `1password-connect`      |
| Gateway (internal)                | `internal-gateway`                                              | `internal`, `envoy-internal`            |
| Gateway (external)                | `external-gateway`                                              | `external`, `envoy-external`            |
| Gateway namespace                 | `network`                                                       | `default`, `networking`                 |
| OCIRepository API                 | `source.toolkit.fluxcd.io/v1`                                   | `v1beta2`                               |
| ExternalSecret API                | `external-secrets.io/v1`                                        | `v1beta1`                               |
| Flux Kustomization API            | `kustomize.toolkit.fluxcd.io/v1`                                | `v1beta2`                               |
| Container image tag               | `v1.0.0@sha256:abc...`                                          | `latest`, bare `v1.0.0`                 |
| OCIRepository chart tag           | bare version `2.5.0` (no SHA)                                   | SHA-pinned — not used for Helm charts   |
| Timezone                          | never set `TZ` — k8tz handles it                                | `TZ: America/Toronto`                   |
| HTTPRoute location                | inline in helmrelease values                                    | standalone HTTPRoute file               |
| Cluster traffic                   | `<app>.<ns>.svc.cluster.local`                                  | external hostname                       |
| OCIRepository scope               | one per app                                                     | shared across apps                      |
| Block storage class               | `ceph-block`                                                    | `rook-ceph-block`, `ceph-block-storage` |
| Filesystem storage class          | `ceph-filesystem`                                               | `cephfs`, `ceph-fs`                     |
| Sonarr/Radarr/Prowlarr probe path | `/ping` (each has its own path — check the app before assuming) | `/`, `/health`                          |

## Cluster Inspection — prefer MCP tools over `kubectl` via Bash

For read-only inspection (get, describe, logs, exec, rollout status, scale) use the k8s
tools from the `-ops` MCP server rather than shelling out to `kubectl`. They are
pre-authenticated and return structured data, with no shell-quoting to get wrong.

Tool names carry the MCP server prefix, which changes when the server is rewired — list
the available tools rather than trusting a hardcoded name here.

**Never apply cluster changes through MCP.** No `kubectl apply`, no MCP apply equivalent.
All changes go through `just kube apply-ks <ns> <ks>` so Flux stays the source of truth.

## Topic References

For deeper patterns, read from `.agents/references/`. The catalog lives in `AGENTS.md`
§ Agent Instructions — it is not duplicated here, because this copy drifted two entries out of
date before being removed.
