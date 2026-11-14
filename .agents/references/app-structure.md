# App Directory Structure — home-infra

These are the canonical shapes for an app directory. `cluster-conventions.md` § App Directory
Structure carries the rules (one `ks.yaml` per app, no grouping directory, alphabetical
`resources` in the `kustomization.yaml` of each namespace), and it wins. This file carries the
five shapes and their tradeoffs. Read it when you create an app, split a multi-component app, or
decide whether something is a fleet.

### Single-component app (the common case)

```text
clusters/artemis/kubernetes/apps/<namespace>/<app>/
├── ks.yaml                  # one Flux Kustomization, name: <app>, path: .../<app>/app
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml   # standalone OCIRepository — every app gets its own
    └── helmrelease.yaml     # HTTPRoutes and ExternalSecrets defined in values here, not separate files
```

### Multi-component app

The app root has one `ks.yaml` with N Kustomization documents, one per sibling sub-directory.
The primary component keeps the name `app/`. The other components are named for what they are
(`microservices/`, `machine-learning/`, `cluster/`, `instance/`, `operator/`).

```text
clusters/artemis/kubernetes/apps/media/immich/
├── ks.yaml                  # 3 Kustomizations: immich-app, immich-microservices,
│                            # immich-machine-learning
├── app/
├── machine-learning/
└── microservices/
```

- Kustomization names are `<app>-<component>`. `dependsOn` between them uses those names.
- When the components are one product, `commonMetadata.labels.app.kubernetes.io/name` is the app,
  not the component (all the immich Kustomizations label `immich`). Where the components are
  genuinely separate deployables, label the component (`victoria-operator` vs `victoria-app`).

### Operator and operand

If the operator serves the whole cluster, it gets its own namespace: `cnpg-system`,
`dragonfly-system`, `kopiur-system`, `external-secrets`. Operands then live in the consuming
namespace and use `dependsOn` across namespaces.

If the operand of the operator lives in the same namespace, the operator is a sub-directory of
the app directory of the operand. It is never a sibling top-level app directory.

```text
clusters/artemis/kubernetes/apps/security/pocket-id/
├── ks.yaml                  # pocket-id-operator, pocket-id, pocket-id-groups,
│                            # pocket-id-extclients
├── operator/
├── instance/
├── groups/
└── external-clients/
```

Same shape:
`observability/victoria/{operator,app,agent,alert,logs}`,
`observability/grafana/{app,instance}`, `cortex/llmkube/{app,models}`,
`cert-manager/trust-manager/{app,config}`.

### CR collections

A directory of many CRs of the same kind, reconciled by one Kustomization, is a sub-directory of
the app that owns the controller: `tuppr/upgrades/`, `silence-operator/silences/`,
`multus/networks/`, `renovate-operator/jobs/`, `pocket-id/groups/`, `llmkube/models/`.

### Fleets

Many similar workloads that are operationally one thing are one app directory with one
Kustomization. The members are kustomize sub-directories, wired by `resources:` in the parent
`kustomization.yaml`. Each member keeps its own `kustomization.yaml`, so a member can carry its
own `configMapGenerator` or extra resources.

```text
clusters/artemis/kubernetes/apps/external-endpoints/services/
├── ks.yaml                  # ONE Kustomization, name: external-endpoints
└── app/
    ├── kustomization.yaml   # resources: ./forgejo ./pve ./templates ./truenas ./unifi
    ├── forgejo/{kustomization,envoyextensionpolicy,inputs}.yaml
    ├── pve/
    ├── templates/
    ├── truenas/
    └── unifi/
```

The tradeoff is deliberate. One Kustomization means one failure domain, so a build error in one
member stalls them all. Validate with `just kube render-ks <ns> <ks>` before you commit. Prefer a
fleet over N near-identical `ks.yaml` files once N is more than about three and the members share
a lifecycle and a single controller.

Do not template a fleet into a component or a ResourceSet unless the members are genuinely
uniform. A component or ResourceSet earns its place when the resource skeleton is identical and
only a handful of scalars vary. Examples are `components/kopiur/backup` (`${APP}`,
`${KOPIUR_CAPACITY}`), `components/postgres/*` (`${APP}`), and the `agentgateway-opencode-go`
ResourceSet in `cortex/agentgateway/models/`. Members can differ structurally: different auth
mechanisms, some with a workload and some without, per-member volumes or RBAC. In that case,
templating hides the differences, breaks schema validation and editor completion, and takes the
pinned `image:` lines out of reach of Renovate. Keep those as readable per-member manifests.
`cortex/mcp` is that case. It has ten MCP servers in one `mcp-servers` Kustomization, each with
its own HelmRelease, because their RBAC, generated ConfigMaps and secrets all differ.

### Non-standard resource types

One resource per file, filename = lowercased kind, flat in the leaf directory alongside
`helmrelease.yaml`, listed alphabetically in the `kustomization.yaml` of that directory. There is
no `rbac/`, `monitoring/`, or `network/` sub-directory. Examples: `grafanadashboard.yaml`,
`servicemonitor.yaml`, `networkpolicy.yaml`, `securitypolicy.yaml`, `oidcclient.yaml`,
`resourceset.yaml`. ClusterRole + Binding + ServiceAccount go together in a single
`rbac.yaml`.

`HTTPRoute` is inline under `route.app:` in app-template values. The only exception is a
non-app-template deployment with no `values.route` to write into. It gets a standalone
`httproute.yaml` (`flux-system/flux-webhook`, `network/echo`, `cortex/agentgateway`).

Non-YAML configuration payloads go in a `resources/` (or `config/`) sub-directory of the leaf
directory. They are mounted via `configMapGenerator` with `disableNameSuffixHash: true` and the
`kustomize.toolkit.fluxcd.io/substitute: disabled` annotation.
