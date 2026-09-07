---
paths:
    - "kubernetes/**/*.yaml"
    - "kubernetes/**/*.yml"
---

# YAML Conventions — Artemis-Cluster

How manifests in this repo are shaped, ordered, and kept clean. Verified against the live tree
and the home-operations reference repos (onedr0p/home-ops et al.) 2026-07-11.

## What the tooling does for you

| Fixes automatically at commit                                                                             | Does NOT fix                                               |
| --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| oxfmt: indentation, flow-list spacing, trailing whitespace, final newline                                 | quoting, anchors                                           |
| `hooks/k8s_yaml_schema.py`: the `# yaml-language-server: $schema=` modeline                               | non-k8s YAML, core-API (`v1`) kinds                        |
| `scripts/normalize-yaml-order.py`: **every order in § Semantic Orders by Kind**, and the `resources` list | which fields exist — it reorders, it never adds or deletes |

**oxfmt reformats YAML inside markdown fences to 4-space**, its own style, while manifests are
2-space. That is not drift and cannot be fixed in the doc — the hook rewrites it back. **Copy
structure out of a template, never indentation.**

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

- Top-level key order is always `apiVersion → kind → metadata → spec`
- `metadata` order is always `name → namespace → annotations → labels`
- Always start each document with `---`, including the first in the file
- Multi-document files (e.g. `ks.yaml` with several Kustomizations) separate with bare `---`
- Schema domain is `k8s-schemas.home-operations.com`; app-template HelmReleases get the
  bjw-s schema URL — the hook resolves this from the sidecar `ocirepository.yaml`, don't hand-edit

## The One Rule

**Alphabetical at every nesting level, except where a semantic order is defined below.**
Semantic orders exist where reading order matters more than lookup order (identity first,
routing/config in the middle, mounts last).

Two qualifiers on "every nesting level":

- **Siblings under a map of named items are not ordered relative to each other.** Within
  `persistence`, `service`, `route`, `configMaps`, `controllers` and friends, the named entries
  (`persistence.config`, `persistence.media`, …) may appear in any order — only the keys _inside_
  each named entry follow the rules below. Do not reshuffle named entries to alphabetize them.
- **A YAML anchor must appear before any alias that references it.** Where alphabetical order
  would put `&name` after its first `*name`, the anchor wins and moves to the top of its section
  — treat it exactly like `enabled`. Define anchors at first natural use (`port: &port 8000`).

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

`wait` goes last (before `healthChecks`), and **every** Kustomization document declares it — see
§ No Restating Defaults for why the redundant `wait: false` is kept rather than stripped. Placement
is enforced by the normalizer, so this list is canonical rather than aspirational.

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

### Init containers (`initContainers.<name>`)

Same shape as `containers.<name>`: `image` first, rest alphabetical. `initContainers` sits
second-to-last in a controller entry, immediately before `containers`.

### Persistence entries (`persistence.<name>`)

Identity first, mounts always last:

```text
type | existingClaim → annotations → labels → <alphabetical: defaultMode, identifier, name, path, server, …>
→ globalMounts | advancedMounts
```

`globalMounts` is second-to-last and `advancedMounts` last when both are present.

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
- Never sort YAML that is embedded inside a string value — a config-file payload under
  `configMap.data.*` keeps its application's own key order; only the surrounding YAML structure
  is sorted
- Quote env values that YAML would otherwise coerce: `"true"`, `"1"`, `"60"`
- One logical resource per file (helmrelease / ocirepository / externalsecret split); the
  exception is `ks.yaml`, which holds all of an app's Flux Kustomizations

## No Restating Defaults

**A manifest states what it changes.** If a field's value is already the default of the chart, the
Kubernetes API, or the CRD, it does not belong in the manifest — it is noise that reads like a
decision. Cleaned out repo-wide on 2026-09-07 (59 fields across 54 files).

**Prove the default before deleting it, and cite where.** The chart's own `values.yaml`, the CRD's
`+kubebuilder:default`, or the API reference — never memory. A survey done from memory in that
cleanup got `replicas` backwards, and the field was nearly deleted on a false premise.

### Deliberate exceptions — do not strip these

| Field                          | Why it stays                                                                                                                                           |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `wait` on a Flux Kustomization | Gates `dependsOn` ordering, so a reader needs the answer without knowing Flux's default. All 134 Kustomization documents declare it; keep it that way. |
| `enabled: true`                | Mandated as the first field of any section that has one — see § General Rules.                                                                         |

### Proven NOT default — leave them alone

These look strippable and are not. Each was checked against source; the note is here so nobody
re-derives it and gets it wrong a second time.

| Field                                      | Actual default                                                                                                                                                                                                        |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prune` (Flux Kustomization)               | `+required` in the CRD — no default exists at all                                                                                                                                                                     |
| `install`/`upgrade.remediation.retries: 3` | Flux's default is `0`                                                                                                                                                                                                 |
| `upgrade.cleanupOnFail: true`              | Flux's default is `false`                                                                                                                                                                                             |
| `strategy: RollingUpdate` (app-template)   | The chart default is **`Recreate`**, so `RollingUpdate` is the override and `Recreate` is the redundant one                                                                                                           |
| `replicas: 1` (app-template)               | Chart default is `null`, not `1`. With `null` the field is omitted so an HPA can own it and Flux will not fight a manual scale; an explicit `1` makes Flux enforce `1`. Different behaviour, not a redundant default. |
| `layerSelector` (OCIRepository)            | Unverified — a Helm OCI artifact may carry more than one layer, so "first layer found" is not provably equivalent. Do not delete without testing.                                                                     |

A resource templated **inside** a Flux `ResourceSet` is invisible to any script that iterates
top-level documents. `components/postgres/tenants/resourceset.yaml` was missed by exactly that and
had to be fixed by hand — check ResourceSet bodies when sweeping for a field.

## Where the rules live

This file is the single authority for ordering. A second copy under `.agents/skills/modules/` (since deleted) drifted and was merged back here on
2026-08-21 — cite this
file, do not restate it. `.agents/skills/modules/checklists/yaml-sorting.md` is the review-time
checklist form: it checks, it does not define.

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

### Shell scripts embedded in a manifest are code, not manifest

A `script:`/`command:` block scalar (Tekton StepActions, init containers) is a program, and a
program may carry code comments. The rule that applies there is **one terse line, not a
paragraph**: say what the next few lines do, and put the reasoning in the reference doc. A
multi-line rationale essay inside an init script is the same violation as one in the manifest
body — it was cleaned out of `hermes`, `buildx-bake` and `bake-options` on 2026-09-07 and
replaced with one-liners pointing at `hermes.md` and `tekton-ci.md`.

When a value is non-obvious enough to feel like it needs a comment, that is the signal to
write it up in the matching reference doc instead — then, if the constraint is genuinely
dangerous to violate, the doc is what gets cited in review. Example: the CoreDNS `template`
plugin ordering is load-bearing and its rationale runs ~40 lines; it lives in
`.agents/references/networking.md` § CoreDNS, and the manifest itself is bare.
