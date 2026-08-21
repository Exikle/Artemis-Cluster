# YAML Conventions — Artemis-Cluster

How manifests in this repo are shaped, ordered, and kept clean. Verified against the live tree
and the home-operations reference repos (onedr0p/home-ops et al.) 2026-07-11.

## Enforcement Layers — know what the tooling does for you

| Layer                                                | Trigger                                             | What it fixes                                                                 | What it does NOT fix                                            |
| ---------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------- |
| oxfmt (`.oxfmtrc.json`, printWidth 100)              | lefthook pre-commit, `stage_fixed`                  | indentation, flow-list spacing (`[1, 2]`), trailing whitespace, final newline | **key ordering, quoting, anchors — never reorders keys**        |
| `hooks/k8s_yaml_schema.py` (`.k8s-schema-hook.yaml`) | lefthook pre-commit on `kubernetes/**/*.{yml,yaml}` | inserts/updates the `# yaml-language-server: $schema=` directive per document | anything else; skips core-API (`v1`) resources and non-k8s YAML |
| `.editorconfig`                                      | editor                                              | 2-space indent, LF, final newline                                             | ordering                                                        |

**Key ordering is not enforced at commit time.** Nothing in the commit path reorders keys —
the author (you) applies the rules below. To audit or bulk-fix ks.yaml `spec` and app-template
`values` ordering: `hooks/.venv/bin/python scripts/normalize-yaml-order.py [--check]`
(comment/anchor-preserving, refuses to write if output isn't semantically identical).

## Document Shape

Every Kubernetes manifest document:

```yaml
---
# yaml-language-server: $schema=<injected by hook — leave in place, hook keeps it current>
apiVersion: ...
kind: ...
metadata: name → namespace → annotations → labels
spec: ...
```

- Always start each document with `---`, including the first in the file
- Multi-document files (e.g. `ks.yaml` with several Kustomizations) separate with bare `---`
- Schema domain is `k8s-schemas.home-operations.com`; app-template HelmReleases get the
  bjw-s schema URL — the hook resolves this from the sidecar `ocirepository.yaml`, don't hand-edit

## The One Rule

**Alphabetical at every nesting level, except where a semantic order is defined below.**
Semantic orders exist where reading order matters more than lookup order (identity first,
routing/config in the middle, mounts last).

> The home-operations upstream repos alphabetize `ks.yaml` spec too; we deliberately keep a
> semantic order there (identity → source → timing → wiring). Don't "fix" it to match upstream.

## Semantic Orders by Kind

### ks.yaml (Flux Kustomization) — `spec`

```text
targetNamespace → commonMetadata → path → prune → sourceRef
→ interval → retryInterval → timeout
→ dependsOn → components → postBuild
→ wait → healthChecks
```

`wait` goes last (before `healthChecks`). Live manifests drift on this — a minority put
`wait` before `dependsOn` or right after `sourceRef`. This list is canonical; fix placement
when touching a file, don't copy a neighbour's drift.

### HelmRelease — `spec`

```text
chartRef → interval → dependsOn → install → upgrade → values → postRenderers
```

### HelmRelease — `spec.values` (app-template)

`defaultPodOptions` always first, then **strictly alphabetical**:

```text
defaultPodOptions → configMaps → controllers → persistence → podDisruptionBudget
→ route → service → serviceAccount → serviceMonitor
```

(For non-app-template charts, follow the chart's own values structure — never reorder a
vendored/upstream values layout just to alphabetize it.)

### Controller entries (`controllers.<name>`)

```text
enabled → type → annotations → labels → <controller fields: replicas, strategy, …>
→ pod → initContainers → containers
```

### Container entries (`containers.<name>`)

`image` always first, rest alphabetical:

```text
image → args → command → env → envFrom → probes → resources → securityContext
```

- Resources: `requests` before `limits`
- Define anchors at first use (`port: &port 8000`), reference later (`port: *port`)

### Persistence entries (`persistence.<name>`)

Identity first, mounts always last:

```text
type | existingClaim → annotations → labels → <alphabetical: defaultMode, identifier, name, path, server, …>
→ globalMounts | advancedMounts
```

### Service entries (`service.<name>`)

```text
type → annotations → labels → <alphabetical: controller, externalTrafficPolicy, …> → ports
```

### Route entries (`route.<name>`)

Plain alphabetical: `annotations → hostnames → parentRefs → rules`

### OCIRepository / ExternalSecret — `spec`

Plain alphabetical. Canonical shapes:

- OCIRepository: `interval → layerSelector → ref → url`
- ExternalSecret: `dataFrom → refreshInterval → secretStoreRef → target`

### kustomization.yaml (kustomize)

```text
apiVersion → kind → namespace → components → resources → <alphabetical rest>
```

- `resources` list sorted alphabetically; in a namespace-level file, `./namespace.yaml` first
- New app: insert `- ./<app>/ks.yaml` in alphabetical position

## General Rules

- `enabled: true/false` is always the **first** field in any section that has it
- **Never sort inside string values** — config file payloads in ConfigMaps/Secrets keep their
  application's natural order
- Never reorder keys in vendored content (upstream chart values, dashboard JSON, alert rules)
- Quote env values that YAML would otherwise coerce: `"true"`, `"1"`, `"60"`
- One logical resource per file (helmrelease / ocirepository / externalsecret split); the
  exception is `ks.yaml`, which holds all of an app's Flux Kustomizations

## No Comments in Manifests

**Manifests carry configuration, not prose.** Do not add explanatory comments to anything
under `kubernetes/`, or to the repo-root `.renovaterc.json5` — no rationale, no incident
history, no "keep this ordered" warnings, no commented-out alternatives. Rationale belongs in
`.agents/references/<topic>.md`, where it is searchable, reviewable, and does not have to be
re-read on every manifest edit.

Three exceptions, all machine-oriented:

| Allowed                                          | Why                                        |
| ------------------------------------------------ | ------------------------------------------ |
| `# yaml-language-server: $schema=…`              | injected and maintained by the schema hook |
| YAML anchor markers where the anchor is subtle   | reading aid for `&name` / `*name` pairs    |
| Renovate directives (`# renovate: datasource=…`) | consumed by Renovate                       |

When a value is non-obvious enough to feel like it needs a comment, that is the signal to
write it up in the matching reference doc instead — then, if the constraint is genuinely
dangerous to violate, the doc is what gets cited in review. Example: the CoreDNS `template`
plugin ordering is load-bearing and its rationale runs ~40 lines; it lives in
`.agents/references/networking.md` § CoreDNS, and the manifest itself is bare.
