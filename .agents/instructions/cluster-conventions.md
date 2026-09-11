# Cluster Conventions — Artemis-Cluster

## App Directory Structure

Every app is one directory under `kubernetes/apps/<namespace>/`, holding exactly one `ks.yaml`.
That file may contain several Flux Kustomization documents — one per sub-directory — but there is
never more than one `ks.yaml` per app directory, and never a grouping directory between a
namespace and its apps. Add `- ./<app>/ks.yaml` to the namespace `kustomization.yaml` in
alphabetical position.

Kustomization names are `<app>-<component>`; `commonMetadata.labels.app.kubernetes.io/name` is the
**app**, not the component, when the components are one product — label the component only where
they are genuinely separate deployables (`victoria-operator` vs `victoria-app`).

**An operator that serves the whole cluster gets its own `*-system` namespace.** An operator whose
operand lives in the same namespace is a sub-directory of the operand's app directory, never a
sibling top-level app.

Non-standard resource types: one resource per file, filename = lowercased kind, flat in the leaf
directory, listed alphabetically. There is no `rbac/`, `monitoring/` or `network/` sub-directory.
`HTTPRoute` is inline under `route.app:` in app-template values.

The five canonical shapes — single, multi-component, operator/operand, CR collection, fleet — with
directory trees and the tradeoffs of each: **`.agents/references/app-structure.md`**.

## Helm / app-template v5

- Chart: `oci://ghcr.io/bjw-s-labs/helm/app-template` tag `5.1.0` (note: `-labs`, not `-bjw-s`)
  — Renovate bumps this fleet-wide; if a doc says `5.0.1` it is stale, confirm against the tree
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

| Need                  | Preferred approach                                                                            |
| --------------------- | --------------------------------------------------------------------------------------------- |
| Relational DB         | Shared CNPG cluster via `postgres-rw` (add `components/postgres/app` + an `APP` substitution) |
| Redis / queue / cache | Shared Dragonfly at `dragonfly.database.svc.cluster.local:6379` — no auth, no persistence     |
| Multi-component apps  | Split into separate kustomizations (e.g. Immich: database / app / microservices / ml)         |

Onboarding steps, the three DSN keys, and the per-driver gotchas: `.agents/references/postgres-dragonfly.md`.

**There are no dedicated instances left.** Immich was the last one and was consolidated into the
shared cluster on 2026-09-01, once that cluster began loading VectorChord via
`postgresql.extensions` rather than a forked base image. Before assuming an app needs its own,
check what the shared cluster already offers:
`SELECT name, default_version FROM pg_available_extensions`. Do not stand up a per-app CNPG cluster
or a sidecar Redis without a specific reason, and say why in the commit.

An app that supports SQLite may still use it — that avoids a dependency entirely. The change from
the old policy is what happens when a real database _is_ needed: share, don't silo.

## Common Mistakes — Quick Reference

| Pattern                           | Correct                                                         | Wrong                                     |
| --------------------------------- | --------------------------------------------------------------- | ----------------------------------------- |
| Secret store name                 | `onepassword-connect`                                           | `onepassword`, `1password-connect`        |
| Gateway (internal)                | `internal-gateway`                                              | `internal`, `envoy-internal`              |
| Gateway (external)                | `external-gateway`                                              | `external`, `envoy-external`              |
| Gateway (edge, `*.frostlink.dev`) | `edge-gateway`                                                  | `external-gateway`, `edge`, `towonel`     |
| Gateway namespace                 | `network`                                                       | `default`, `networking`                   |
| OCIRepository API                 | `source.toolkit.fluxcd.io/v1`                                   | `v1beta2`                                 |
| ExternalSecret API                | `external-secrets.io/v1`                                        | `v1beta1`                                 |
| Flux Kustomization API            | `kustomize.toolkit.fluxcd.io/v1`                                | `v1beta2`                                 |
| Container image tag               | `v1.0.0@sha256:abc...`                                          | `latest`, bare `v1.0.0`                   |
| OCIRepository chart tag           | bare version `2.5.0` (no SHA)                                   | SHA-pinned — not used for Helm charts     |
| Timezone                          | never set `TZ` — k8tz handles it                                | `TZ: America/Toronto`                     |
| HTTPRoute location                | inline in helmrelease values                                    | standalone HTTPRoute file                 |
| Route gateway attachment          | exactly one of internal/external/edge                           | both internal **and** external gateways   |
| Cluster traffic                   | `<app>.<ns>.svc.cluster.local`                                  | external hostname                         |
| OCIRepository scope               | one per app                                                     | shared across apps                        |
| Block storage class               | `miroir` (default) or `miroir-local`                            | `ceph-block`, `rook-ceph-block`           |
| Storage class (Rook-Ceph removed) | `miroir`, `miroir-local` — nothing else exists                  | `ceph-block`, `cephfs`, `ceph-filesystem` |
| Sonarr/Radarr/Prowlarr probe path | `/ping` (each has its own path — check the app before assuming) | `/`, `/health`                            |

## GPU Workloads

Two allocation mechanisms, split by card, never by app: DRA claims on the Arc A380,
`generic-device-plugin` on ymir's iGPU for cross-namespace sharing (a `ResourceClaim` is
namespace-scoped and cannot span namespaces). Affinity keys on `node.kubernetes.io/gpu-tier`,
never `extensions.talos.dev/i915`. Details, CEL selector rules and the
`ResourceClaimTemplate` immutability trap: `.agents/references/gpu.md`.

## Cluster Inspection

Use the `-ops` MCP k8s tools for read-only inspection rather than shelling out to `kubectl` —
pre-authenticated, structured, no shell quoting to get wrong. **Never apply cluster changes
through MCP.** Tool names carry a server prefix that changes when the gateway is rewired, so list
the tools rather than trusting a hardcoded name.

## Topic References

For deeper patterns, read from `.agents/references/`. The catalog lives in `AGENTS.md`
§ Agent Instructions — it is not duplicated here, because this copy drifted two entries out of
date before being removed.
