# App Directory Structure — Artemis-Cluster

Canonical shapes for an app directory. `cluster-conventions.md` carries the one-paragraph rule;
this file carries the five shapes and their tradeoffs. Read it when creating an app, splitting a
multi-component app, or deciding whether something is a fleet.

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
