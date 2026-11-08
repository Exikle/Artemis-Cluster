---
paths:
    - "kubernetes/**/*.yaml"
    - "kubernetes/**/*.yml"
---

# YAML Conventions — Artemis-Cluster

How manifests in this repo are shaped, ordered, and kept clean. Checked against the live tree
and the home-operations reference repos (onedr0p/home-ops et al.) on 2026-07-11.

## What the tooling does for you

| Fixes automatically at commit                                                                         | Does NOT fix                                              |
| ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| oxfmt: indentation, flow-list spacing, trailing whitespace, final newline                             | quoting, anchors                                          |
| `hooks/k8s_yaml_schema.py`: the `# yaml-language-server: $schema=` modeline                           | non-k8s YAML, core-API (`v1`) kinds                       |
| `scripts/normalize-yaml-order.py`: every order in § Semantic Orders by Kind, and the `resources` list | which fields exist. It reorders, it never adds or deletes |

oxfmt reformats YAML inside markdown fences to 4-space, which is its own style. Manifests use
2-space. That is not drift, and you cannot fix it in the doc, because the hook rewrites it back.
Copy structure out of a template, never indentation.

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
- Multi-document files (for example `ks.yaml` with several Kustomizations) separate documents with a bare `---`
- The schema domain is `k8s-schemas.home-operations.com`. app-template HelmReleases get the
  bjw-s schema URL. The hook resolves this from the sidecar `ocirepository.yaml`. Do not hand-edit it

## The One Rule

Order keys alphabetically at every nesting level, except where a semantic order is defined below.
Semantic orders exist where reading order matters more than lookup order (identity first,
routing and configuration in the middle, mounts last).

Two qualifiers apply to "every nesting level":

- Siblings under a map of named items are not ordered relative to each other. Within
  `persistence`, `service`, `route`, `configMaps`, `controllers` and similar maps, the named
  entries (`persistence.config`, `persistence.media`, …) can appear in any order. Only the keys
  _inside_ each named entry follow the rules below. Do not reshuffle named entries to alphabetize
  them.
- A YAML anchor must appear before any alias that references it. Where alphabetical order would
  put `&name` after its first `*name`, the anchor wins and moves to the top of its section. Treat
  it exactly like `enabled`. Define anchors at first natural use (`port: &port 8000`).

> The home-operations upstream repos alphabetize the `ks.yaml` spec too. This repo deliberately
> keeps a semantic order there (identity → source → timing → wiring). Do not "fix" it to match
> upstream.

## Semantic Orders by Kind

### ks.yaml (Flux Kustomization) — `spec`

```text
targetNamespace → commonMetadata → path → prune → sourceRef
→ interval → retryInterval → timeout
→ dependsOn → components → postBuild
→ wait → healthChecks
```

`wait` goes last (before `healthChecks`), and every Kustomization document declares it. See
§ No Restating Defaults for the reason that the redundant `wait: false` stays. The normalizer
enforces the placement, so this list is canonical, not aspirational.

### HelmRelease — `spec`

```text
chartRef → interval → dependsOn → install → upgrade → values → postRenderers
```

### HelmRelease — `spec.values` (app-template)

`defaultPodOptions` always first, then strictly alphabetical:

```text
defaultPodOptions → configMaps → controllers → persistence → podDisruptionBudget
→ route → service → serviceAccount → serviceMonitor
```

(For non-app-template charts, follow the values structure of the chart. Never reorder a
vendored or upstream values layout just to alphabetize it.)

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

Same shape as `containers.<name>`: `image` first, rest alphabetical. `initContainers` is
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

- Sort the `resources` list alphabetically. In a namespace-level file, `./namespace.yaml` is first
- New app: insert `- ./<app>/ks.yaml` in alphabetical position

## General Rules

- `enabled: true/false` is always the first field in any section that has it
- Never sort inside string values. Configuration file payloads in ConfigMaps and Secrets keep the
  natural order of their application
- Never reorder keys in vendored content (upstream chart values, dashboard JSON, alert rules)
- Never sort YAML that is embedded inside a string value. A configuration file payload under
  `configMap.data.*` keeps the key order of its own application. Sort only the surrounding YAML
  structure
- Quote env values that YAML would otherwise coerce: `"true"`, `"1"`, `"60"`
- One logical resource per file (helmrelease / ocirepository split). There are two exceptions:
  `ks.yaml`, which holds all of the Flux Kustomizations of an app, and the inline
  `externalSecrets` of app-template, which live in `helmrelease.yaml`

## No Restating Defaults

A manifest states what it changes. If the value of a field is already the default of the chart,
the Kubernetes API, or the CRD, the field does not belong in the manifest. It is noise that reads
like a decision. A cleanup removed these fields repo-wide on 2026-09-07 (59 fields across 54
files).

Prove the default before you delete it, and cite where. Cite the `values.yaml` of the chart, the
`+kubebuilder:default` of the CRD, or the API reference, never memory. A survey from memory in that
cleanup got `replicas` backwards, and the field was nearly deleted on a false premise.

### Deliberate exceptions — do not strip these

| Field                          | Why it stays                                                                                                                                         |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wait` on a Flux Kustomization | Gates `dependsOn` ordering, so a reader needs the answer without knowing Flux's default. Every Kustomization document declares it. Keep it that way. |
| `enabled: true`                | Mandated as the first field of any section that has one. See § General Rules.                                                                        |

### Proven NOT default — leave them alone

These look strippable, but they are not. Each was checked against source. The note is here so that
no one re-derives it and gets it wrong a second time.

| Field                                      | Actual default                                                                                                                                                                                                        |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prune` (Flux Kustomization)               | `+required` in the CRD. No default exists at all                                                                                                                                                                      |
| `install`/`upgrade.remediation.retries: 3` | Flux's default is `0`                                                                                                                                                                                                 |
| `upgrade.cleanupOnFail: true`              | Flux's default is `false`                                                                                                                                                                                             |
| `strategy: RollingUpdate` (app-template)   | The chart default is **`Recreate`**, so `RollingUpdate` is the override and `Recreate` is the redundant one                                                                                                           |
| `replicas: 1` (app-template)               | Chart default is `null`, not `1`. With `null` the field is omitted so an HPA can own it and Flux will not fight a manual scale. An explicit `1` makes Flux enforce `1`. Different behaviour, not a redundant default. |
| `layerSelector` (OCIRepository)            | Unverified. A Helm OCI artifact may carry more than one layer, so "first layer found" is not provably equivalent. Do not delete without testing.                                                                      |

A resource templated inside a Flux `ResourceSet` is invisible to any script that iterates over
top-level documents. That is exactly why a script missed `components/postgres/tenants/resourceset.yaml`,
and someone had to fix it by hand. Check ResourceSet bodies when you sweep for a field.

## Where the rules live

This file is the single authority for ordering. A second copy under `.agents/skills/modules/`
(since deleted) drifted, and it was merged back here on 2026-08-21. Cite this file. Do not
restate it. `.agents/skills/modules/checklists/yaml-sorting.md` is the review-time checklist
form. It checks the rules. It does not define them.

## No Comments in Manifests

Manifests carry configuration, not prose. Do not add explanatory comments to anything under
`kubernetes/`, or to the repo-root `.renovaterc.json5`. That means no rationale, no incident
history, no "keep this ordered" warnings, and no commented-out alternatives. Rationale belongs in
`.agents/references/<topic>.md`. There it is searchable and reviewable, and no one must re-read it
on every manifest edit.

There are three exceptions, all machine-oriented:

| Allowed                                          | Why                                        |
| ------------------------------------------------ | ------------------------------------------ |
| `# yaml-language-server: $schema=…`              | injected and maintained by the schema hook |
| YAML anchor markers where the anchor is subtle   | reading aid for `&name` / `*name` pairs    |
| Renovate directives (`# renovate: datasource=…`) | consumed by Renovate                       |

### Shell scripts embedded in a manifest are code, not manifest

A `script:` or `command:` block scalar (init containers, CronJob scripts) is a program, and a
program can carry code comments. The rule that applies there is one terse line, not a paragraph.
Say what the next few lines do, and put the reasoning in the reference doc. A multi-line
rationale essay inside an init script is the same violation as one in the manifest body. A
cleanup removed such essays from `hermes`, `buildx-bake` and `bake-options` on 2026-09-07 and
replaced them with one-liners that point at `hermes.md` and the CI reference (now `ci.md`).

If a value is non-obvious enough that it seems to need a comment, write it up in the matching
reference doc instead. Then, if the constraint is genuinely dangerous to violate, reviewers cite
the doc. Example: the ordering of the CoreDNS `template` plugin is load-bearing, and its
rationale runs about 40 lines. It lives in `.agents/references/networking.md` § CoreDNS, and the
manifest itself is bare.
