# Module: YAML Sorting Rules

Authoritative sorting reference for all Kubernetes manifests in Artemis-Cluster.
Supersedes `.agents/instructions/sorting-instructions.md` (kept for backwards compatibility).

---

## Default rule

All fields are sorted alphabetically at every nesting level unless a specific override below applies.

---

## YAML anchors

A YAML anchor (`&foo`) must appear in the document before any alias (`*foo`) that references it.
When alphabetical order would place the anchor after its first alias, move the anchor to the top of its section — treat it like `enabled` (always first).

---

## All Kubernetes files — top-level

```
apiVersion → kind → metadata → spec
```

## metadata (all files)

```
name → namespace → annotations → labels
```

## `enabled` field

`enabled: true/false` is always the **first** field in any section that contains it, regardless of other rules.

---

## Flux Kustomization (`ks.yaml`) — `spec`

```
targetNamespace → commonMetadata → path → prune → sourceRef → interval → retryInterval → timeout → dependsOn → components → postBuild → wait
```

Fields not listed here (`healthChecks`, `healthCheckExprs`, etc.) go alphabetically after `postBuild`.

---

## HelmRelease `spec`

```
chartRef → interval → dependsOn → install → upgrade → values
```

## HelmRelease `spec.values` (app-template)

```
defaultPodOptions   ← always first (if present)
<all other keys>    ← alphabetical (controllers, persistence, route, service, serviceAccount, …)
```

> Siblings within `persistence`, `service`, `route`, `configMaps`, etc. are **not** required to be sorted relative to each other. Only the keys within each named item must be sorted.

---

## `controllers.*` items

```
type              ← first (if present)
annotations       ← second (if present)
labels            ← third (if present)
<controller-specific fields e.g. cronjob, statefulset>
pod
<other fields alphabetical>
initContainers    ← second-to-last
containers        ← last
```

## `containers.*` and `initContainers.*` items

```
image             ← always first
<all other fields alphabetical>
```

## `resources`

```
requests → limits
```

## `service.*` items

```
type              ← first (if present)
annotations       ← second (if present)
labels            ← third (if present)
<all other fields alphabetical>
```

## `persistence.*` items

```
type              ← first (if present)
annotations       ← second (if present)
labels            ← third (if present)
<all other fields alphabetical>
globalMounts      ← second-to-last (if present)
advancedMounts    ← last (if present)
```

---

## String values — do NOT sort

Never sort YAML embedded inside string values (e.g. `configMap.data.*` keys containing YAML config).
Only sort the YAML structure itself.
