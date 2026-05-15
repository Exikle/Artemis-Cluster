# YAML Conventions — Artemis-Cluster

All Kubernetes manifests follow these field ordering rules. Default is alphabetical at every level unless overridden below.

## Top-Level Kubernetes Resources

```
apiVersion → kind → metadata → spec
```

## metadata

```
name → namespace → annotations → labels
```

## HelmRelease (app-template)

`spec` level:

```
chartRef → interval → dependsOn → install → upgrade → values
```

`spec.values` level:

```
defaultPodOptions   ← always first
controllers         ← alphabetical after defaultPodOptions
persistence
route
service
serviceAccount
```

## Controllers

```
type → annotations → labels → <controller-specific fields> → pod → initContainers → containers
```

`enabled` field is always first within any section that has it.

## Containers

```
image               ← always first
<rest alphabetical>
```

Resources: `requests` before `limits`.

## Services

```
type → annotations → labels → <alphabetical> → ports → globalMounts/advancedMounts
```

## Persistence

```
type → annotations → labels → <alphabetical> → globalMounts/advancedMounts   ← always last
```

## ks.yaml (Flux Kustomization)

```
apiVersion → kind → metadata → spec:
  targetNamespace → commonMetadata → path → prune → sourceRef → interval → retryInterval → timeout → dependsOn → components → postBuild
```

## General Rules

- Never sort YAML within string values (e.g. config file contents inside ConfigMaps)
- `enabled: true/false` is always the first field in any section
- Alphabetical applies recursively at every nesting level unless a specific order is defined above
