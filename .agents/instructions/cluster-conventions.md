# Cluster Conventions — Artemis-Cluster

## App Directory Structure (canonical)

Every app is one directory under `kubernetes/apps/<namespace>/`, holding exactly one
`ks.yaml`. That `ks.yaml` may contain several Flux Kustomization documents — one per
sub-directory — but there is never more than one `ks.yaml` per app directory, and never a
grouping directory between a namespace and its apps.

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` `resources`, in
alphabetical position. A namespace directory contains only `namespace.yaml`,
`kustomization.yaml`, and app directories.

### Single-component app (the common case)

```text
kubernetes/apps/<namespace>/<app>/
├── ks.yaml                  # one Flux Kustomization, name: <app>, path: .../<app>/app
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml   # standalone OCIRepository — every app gets its own
    ├── helmrelease.yaml     # HTTPRoutes defined in values here, not separate files
    └── externalsecret.yaml  # only if secrets needed
```

### Multi-component app

One `ks.yaml` at the app root with N Kustomization documents, one per sibling sub-directory.
The primary component keeps the name `app/`; the rest are named for what they are
(`database/`, `microservices/`, `machine-learning/`, `cluster/`, `instance/`, `operator/`).

```text
kubernetes/apps/default/immich/
├── ks.yaml                  # 5 Kustomizations: immich-database-backup-target,
│                            # immich-database-cluster, immich-app, immich-microservices,
│                            # immich-machine-learning
├── app/
├── database/{backup-target,cluster}/
├── machine-learning/
└── microservices/
```

- Kustomization names are `<app>-<component>`; `dependsOn` between them uses those names.
- `commonMetadata.labels.app.kubernetes.io/name` is the **app**, not the component, when the
  components are one product (all five immich Kustomizations label `immich`). Where the
  components are genuinely separate deployables, label the component
  (`rook-ceph-operator` vs `rook-ceph-cluster`).

### Operator and operand

**If the operator serves the whole cluster, it gets its own namespace** — `cnpg-system`,
`dragonfly-system`, `kopiur-system`, `external-secrets`, `tekton-system`. Operands then live
in the consuming namespace and `dependsOn` it cross-namespace.

**If the operator's operand lives in the same namespace, the operator is a sub-directory of
the operand's app directory** — never a sibling top-level app directory.

```text
kubernetes/apps/security/pocket-id/
├── ks.yaml                  # pocket-id-operator, pocket-id, pocket-id-groups,
│                            # pocket-id-extclients
├── operator/
├── instance/
├── groups/
└── external-clients/
```

Same shape: `rook-ceph/rook-ceph/{app,cluster,csi-drivers}`,
`observability/victoria/{operator,app,agent,alert,logs}`,
`observability/grafana/{app,instance}`, `cortex/llmkube/{app,models}`,
`cert-manager/trust-manager/{app,config}`.

### CR collections

A directory of many CRs of the same kind, reconciled by one Kustomization, is a
sub-directory of the app that owns the controller: `tuppr/upgrades/`,
`silence-operator/silences/`, `multus/networks/`, `renovate-operator/jobs/`,
`pocket-id/groups/`, `llmkube/models/`, `tekton-runner/library/`.

### Fleets

Many similar workloads that are operationally one thing are **one app directory, one
Kustomization**, with members as kustomize sub-directories wired by `resources:` in the
parent `kustomization.yaml`. Each member keeps its own `kustomization.yaml`, so a member can
carry its own `configMapGenerator` or extra resources.

```text
kubernetes/apps/external-endpoints/services/
├── ks.yaml                  # ONE Kustomization, name: external-endpoints
└── app/
    ├── kustomization.yaml   # resources: ./forgejo ./pve ./templates ./truenas ./unifi
    ├── forgejo/{kustomization,anubis-policy,inputs}.yaml
    ├── pve/
    ├── templates/
    ├── truenas/
    └── unifi/
```

The tradeoff is deliberate: one Kustomization means one failure domain, so a build error in
one member stalls them all. Validate with `just kube render-local-ks <ns> <ks>` before
committing. Prefer a fleet over N near-identical `ks.yaml` files once N is more than about
three and the members share a lifecycle and a single controller.

**Do not template a fleet into a component or a ResourceSet unless the members are genuinely
uniform.** A component or ResourceSet earns its place when the resource skeleton is identical
and only a handful of scalars vary — `components/kopiur/backup` (`${APP}`,
`${KOPIUR_CAPACITY}`), `components/postgres/*` (`${APP}`), or the
`LiteLLMVirtualKey` ResourceSet in `cortex/litellm/proxy/`. When members differ structurally
(different auth mechanisms, some with a workload and some without, per-member volumes or
RBAC), templating hides the differences, breaks schema validation and editor completion, and
takes the pinned `image:` lines out of Renovate's reach. Keep those as readable per-member
manifests.

### Non-standard resource types

One resource per file, filename = lowercased kind, flat in the leaf directory alongside
`helmrelease.yaml`, listed alphabetically in that directory's `kustomization.yaml`. There is
no `rbac/`, `monitoring/`, or `network/` sub-directory. Examples: `grafanadashboard.yaml`,
`servicemonitor.yaml`, `networkpolicy.yaml`, `securitypolicy.yaml`, `oidcclient.yaml`,
`resourceset.yaml`. ClusterRole + Binding + ServiceAccount go together in a single
`rbac.yaml`.

`HTTPRoute` is inline under `route.app:` in app-template values. The only exception is a
non-app-template deployment with no `values.route` to write into, which gets a standalone
`httproute.yaml` (`flux-system/flux-webhook`, `network/echo`,
`tekton-system/tekton-operator`, `cortex/litellm`).

Non-YAML config payloads go in a `resources/` (or `config/`) sub-directory of the leaf
directory and are mounted via `configMapGenerator` with `disableNameSuffixHash: true` and the
`kustomize.toolkit.fluxcd.io/substitute: disabled` annotation.

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

| Pattern                           | Correct                                                         | Wrong                                   |
| --------------------------------- | --------------------------------------------------------------- | --------------------------------------- |
| Secret store name                 | `onepassword-connect`                                           | `onepassword`, `1password-connect`      |
| Gateway (internal)                | `internal-gateway`                                              | `internal`, `envoy-internal`            |
| Gateway (external)                | `external-gateway`                                              | `external`, `envoy-external`            |
| Gateway (edge, `*.frostlink.dev`) | `edge-gateway`                                                  | `external-gateway`, `edge`, `towonel`   |
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
| Storage class (no CephFS exists)  | `ceph-block`, `miroir`, `miroir-local`                          | `ceph-filesystem`, `cephfs`, `ceph-fs`  |
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
