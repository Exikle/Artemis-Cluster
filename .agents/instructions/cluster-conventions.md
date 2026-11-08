---
paths:
    - "kubernetes/**"
---

# Cluster Conventions — Artemis-Cluster

## App Directory Structure

Every app is one directory under `kubernetes/apps/<namespace>/`. The directory holds exactly one
`ks.yaml`. That file can contain several Flux Kustomization documents, one per sub-directory.
There is never more than one `ks.yaml` per app directory. There is never a grouping directory
between a namespace and its apps. Add `- ./<app>/ks.yaml` to the namespace `kustomization.yaml`
in alphabetical position.

Kustomization names are `<app>-<component>`. When the components are one product,
`commonMetadata.labels.app.kubernetes.io/name` is the app, not the component. Label the component
only where the components are genuinely separate deployables (`victoria-operator` vs
`victoria-app`).

An operator that serves the whole cluster gets its own `*-system` namespace. An operator whose
operand lives in the same namespace is a sub-directory of the app directory of the operand, never
a sibling top-level app.

Non-standard resource types: one resource per file, filename = lowercased kind, flat in the leaf
directory, listed alphabetically. There is no `rbac/`, `monitoring/` or `network/` sub-directory.
`HTTPRoute` is inline under `route.app:` in app-template values.

The five canonical shapes are single, multi-component, operator/operand, CR collection, and fleet.
Their directory trees and tradeoffs are in `.agents/references/app-structure.md`.

## Helm / app-template v5

- Chart: `oci://ghcr.io/bjw-s-labs/helm/app-template` (note: `-labs`, not `-bjw-s`). Renovate
  bumps the tag fleet-wide. Recover it with the command in `AGENTS.md` § Make a version fact a command
- Every app gets its own standalone `OCIRepository`. Never share or reuse one
- `chartRef` in HelmRelease: `kind: OCIRepository, name: <app>`
- OCIRepository API version: `source.toolkit.fluxcd.io/v1` (not `v1beta2`)
- Reloader: `reloader.stakater.com/auto: "true"` annotation on controller
- Default security context: `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch`
- Container security: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: {drop: ["ALL"]}`
- Routes: defined inline under `route.app:` in helmrelease values, NOT as standalone HTTPRoute files
- PVC: `existingClaim: <app>` when using the kopiur component
- NFS media mount: server, path and mount point are in `.agents/references/storage.md`

## Secrets

- All secrets: 1Password ExternalSecret with `ClusterSecretStore: onepassword-connect`
  (`AGENTS.md` rule 3 wins on SOPS and the store name)
- ExternalSecret API version: `external-secrets.io/v1`
- app-template apps define their ExternalSecret inline, under `values.externalSecrets.<id>`
  in `helmrelease.yaml`. A standalone `externalsecret.yaml` is only for a non-app-template chart,
  or for a Secret that something reads before the HelmRelease exists (for example
  `postBuild.substituteFrom`)
- `dataFrom.extract.key: <1password-item-name>` pulls all fields from item
- Template field names must exactly match 1Password field names. A mismatch gives an empty secret with no error

## Deployment Philosophy

Use the shared data layer first. The shared CNPG cluster and the shared Dragonfly in the
`database` namespace are the default for new apps.

| Need                  | Preferred approach                                                                            |
| --------------------- | --------------------------------------------------------------------------------------------- |
| Relational DB         | Shared CNPG cluster via `postgres-rw` (add `components/postgres/app` + an `APP` substitution) |
| Redis / queue / cache | Shared Dragonfly at `dragonfly.database.svc.cluster.local:6379`, no auth, no persistence      |
| Multi-component apps  | Split into separate kustomizations (e.g. Immich: app / microservices / machine-learning)      |

Onboarding steps, the three DSN keys, and the per-driver gotchas: `.agents/references/postgres-dragonfly.md`.

No dedicated instances are left (`AGENTS.md` § What was deliberately removed). Before you assume
that an app needs its own, check what the shared cluster already offers:
`SELECT name, default_version FROM pg_available_extensions`. Do not stand up a per-app CNPG
cluster or a sidecar Redis without a specific reason, and say the reason in the commit.

An app that supports SQLite can still use it, because that avoids a dependency entirely. The
change from the old policy applies when an app needs a real database: share it, do not silo it.

## Common Mistakes — Quick Reference

| Pattern                           | Correct                                                          | Wrong                                     |
| --------------------------------- | ---------------------------------------------------------------- | ----------------------------------------- |
| Secret store name                 | `onepassword-connect`                                            | `onepassword`, `1password-connect`        |
| Gateway (internal)                | `internal-gateway`                                               | `internal`, `envoy-internal`              |
| Gateway (public, either domain)   | `edge-gateway`                                                   | `external-gateway`, `edge`, `towonel`     |
| Gateway namespace                 | `network`                                                        | `default`, `networking`                   |
| OCIRepository API                 | `source.toolkit.fluxcd.io/v1`                                    | `v1beta2`                                 |
| ExternalSecret API                | `external-secrets.io/v1`                                         | `v1beta1`                                 |
| Flux Kustomization API            | `kustomize.toolkit.fluxcd.io/v1`                                 | `v1beta2`                                 |
| Container image tag               | `v1.0.0@sha256:abc...`                                           | `latest`, bare `v1.0.0`                   |
| OCIRepository chart tag           | bare version `2.5.0` (no SHA)                                    | SHA-pinned (not used for Helm charts)     |
| Timezone                          | never set `TZ`, k8tz handles it                                  | `TZ: America/Toronto`                     |
| HTTPRoute location                | inline in helmrelease values                                     | standalone HTTPRoute file                 |
| Route gateway attachment          | exactly one of internal/edge                                     | one route on two gateways                 |
| OCIRepository scope               | one per app                                                      | shared across apps                        |
| Storage class                     | `miroir` (default) or `miroir-local`, nothing else exists        | `ceph-block`, `cephfs`, `ceph-filesystem` |
| Sonarr/Radarr/Prowlarr probe path | `/ping` (each has its own path, check the app before you assume) | `/`, `/health`                            |

## GPU Workloads

There are two allocation mechanisms, split by card, never by app. DRA claims serve the Arc A380.
`generic-device-plugin` serves the iGPU of ymir, for cross-namespace sharing (a `ResourceClaim`
is namespace-scoped and cannot span namespaces). Affinity keys on
`node.kubernetes.io/gpu-tier`, never `extensions.talos.dev/i915`. The details, the CEL selector
rules and the `ResourceClaimTemplate` immutability trap are in `.agents/references/gpu.md`.

## Cluster Inspection

For read-only inspection, use the `-ops` MCP k8s tools, not `kubectl`. They are pre-authenticated
and structured, and they have no shell quoting to get wrong. Writes never go through MCP
(`AGENTS.md` rule 2). Tool names change per client, so list the tools and do not hardcode one.

## Topic References

For deeper patterns, read from `.agents/references/`. The catalog is in `AGENTS.md`
§ Where everything else is. This file does not duplicate it.
