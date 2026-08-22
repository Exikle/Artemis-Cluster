# Reference: Flux Patterns — Artemis-Cluster

## Core Workflow

Test live before committing — `main` goes directly to production:

```bash
just kube apply-ks <ns> <ks-name>   # apply live (suspends root + child); wait for user confirmation
# ...commit and push, then wait for `Push Artifact` to go green...
just kube sync ocirepo              # force-sync all OCIRepositories — repeat until the digest moves
just kube resume-ks                 # REQUIRED — resumes everything apply-ks suspended
```

**`just kube resume-ks` is not optional.** `apply-ks` suspends the root `artemis-cluster`
Kustomization and the target child; a session that ends after `sync ocirepo` leaves Flux
suspended cluster-wide. Never resume before CI has rebuilt the artifact — resuming early applies
the pre-commit revision and silently reverts the change. Full sequence and rationale:
`.agents/instructions/commit-style.md` steps 0 and 5.

Other force-sync targets:

```bash
just kube sync hr                   # all HelmReleases
just kube sync ks                   # all Kustomizations
just kube sync es                   # all ExternalSecrets
```

There is **no `GitRepository` to sync.** The Flux source is an OCIRepository built by CI —
`kubectl get gitrepository -A` returns nothing, so `just kube sync gitrepo` has no live target.

`just kube sync ocirepo` **does** cover `flux-system` itself. The recipe is a plain
`kubectl get ocirepo --no-headers -A` loop, and `flux-system/flux-system` is in that list like
any other source (110 OCIRepositories on this cluster; the four in `flux-system` are
`flux-system`, `flux-instance`, `flux-operator`, `konflate`). To poke that one source alone
without touching the other 109:

```bash
kubectl -n flux-system annotate ocirepository flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

Repeat `sync ocirepo` until the `flux-system` digest actually moves. Annotating does not make CI
finish faster — if `Push Artifact` has not gone green, the source re-resolves to the same
pre-commit digest and reports success.

## Stuck HelmRelease

```bash
flux suspend helmrelease <app> -n <ns>
kubectl delete secret -n <ns> -l name=<app>,owner=helm
flux resume helmrelease <app> -n <ns>
```

## Force Reconcile

```bash
flux reconcile kustomization <name> -n <namespace>
```

Kustomizations live in their **target namespace** (e.g. `observability`, `media`), NOT always `flux-system`.

## Key Rules

- `prune: false` on `flux-instance` Kustomization — never prune Flux itself
- `dependsOn` must list actual runtime dependencies, not just chart sources
- `interval: 1h` is standard — 132 of 147 `ks.yaml` use it, 14 use `30m`, one uses `15m`
- **`retryInterval: 1m` is injected by the root Kustomization's patch block**, so an explicit
  one in a child is redundant. Only 37 of 147 set it by hand, and 6 override it to `2m`; the
  other 104 get `1m` from the parent whether or not the file says so. Setting it explicitly is
  harmless, but do not add it "because it's missing" — it isn't.

Live source of truth (verified 2026-08-21): `FluxInstance/flux` in `flux-system`, distribution
`2.x`, syncing `kind: OCIRepository` from `oci://registry.dcunha.io/exikle/artemis-cluster` at
`interval: 1m`. Controllers: source `v1.9.4`, kustomize `v1.9.4`, helm `v1.6.3`, notification
`v1.9.3`. Kustomization API is `kustomize.toolkit.fluxcd.io/v1`, HelmRelease
`helm.toolkit.fluxcd.io/v2`, OCIRepository `source.toolkit.fluxcd.io/v1`.

## Cross-Namespace Kustomization Gotchas

When a `Kustomization` lives outside `flux-system` (e.g. in `media` or `cortex`), both references must be explicit:

```yaml
spec:
    sourceRef:
        kind: OCIRepository
        name: flux-system
        namespace: flux-system
    dependsOn:
        - name: rook-ceph-cluster
          namespace: rook-ceph
```

`sourceRef.namespace` is REQUIRED — omitting it resolves to the child's own namespace and the
source is not found. Same for every cross-namespace `dependsOn` entry. Missing either causes a
silent "not found" reconciliation failure.

| Field            | Correct         | Wrong                                                                       |
| ---------------- | --------------- | --------------------------------------------------------------------------- |
| `sourceRef.kind` | `OCIRepository` | `GitRepository` — the flux source is OCI; 147/147 ks.yaml use OCIRepository |

The only live `kind: GitRepository` in the repo is
`kubernetes/components/alerts/alertmanager/alert.yaml`, where it is a notification `eventSource`
selector — unrelated to Kustomization sources.

## CRD Timing Race

When a Kustomization deploys both a HelmRelease (which installs CRDs) and resources that depend on those CRDs (e.g. `AlertmanagerConfig`, `Probe`), Flux applies everything in one shot — before Helm has run.

**Symptom**: HelmRelease shows healthy but expected CRs are missing.

**Fix**: Force-reconcile the affected Kustomization after the HelmRelease is healthy:

```bash
flux reconcile kustomization <name> -n <namespace>
```

## The root Kustomization overwrites every child's `spec.patches`

`kubernetes/flux/sync/cluster.yaml` (the `artemis-cluster` root Kustomization) carries a
`patches:` block targeting `kustomize.toolkit.fluxcd.io/Kustomization` with `metadata.name: _`
— i.e. **every child `ks.yaml` in the repo**. It sets `deletionPolicy`, `retryInterval`, and a
nested `spec.patches` that applies HelmRelease install/upgrade/rollback defaults.

Because it sets `spec.patches` wholesale, **a `patches:` block written into an app's own
`ks.yaml` is silently replaced.** No error, no warning — the patch just never applies, and the
symptom shows up as "my override isn't taking effect" somewhere downstream. `flate` does not
evaluate the parent patch either, so a local render looks like the override worked.

Put per-app kustomize overrides in the app's own `app/kustomization.yaml` (`patches:` there is
evaluated by the child's own kustomize build and is not touched by the parent). Do not add
`spec.patches` to a `ks.yaml`.

This cost a full afternoon during a namespace move in 2026-06 before the mechanism was
identified.

## kopiur CRs stall `wait: true` health checks

kopiur writes `status.observedGeneration` on a `SnapshotSchedule` at its **first** reconcile and
never again. Edit the schedule spec afterwards and the object sits at
`generation != observedGeneration` permanently. kstatus reads that as `InProgress`, so a
Kustomization with `wait: true` hangs on health checks for the full timeout — every cycle,
indefinitely. While stuck on a stale revision it silently re-applies old config over a change.

- **`healthCheckExprs` does not help.** The generation precondition is evaluated _before_ the CEL
  expressions, so the stale field still wins.
- **Fix: drop `wait: true` and gate on the HelmRelease** via explicit `spec.healthChecks` — that
  is what "the app is up" actually means.
- `SnapshotPolicy` tracks `observedGeneration` correctly. `Restore` does **not**, which is why
  `kubernetes/components/kopiur/backup/restore.yaml` carries
  `kustomize.toolkit.fluxcd.io/ssa: ignore` — Flux then reports it `skipped` and excludes it from
  health checks. That annotation was missing here and stalled `arcade/eco` for 24 days. **Keep
  it.** Frostlink hit the identical fault on `fediverse/apoci` (58128 `DependencyNotReady` flaps
  over 12 days) — same mechanism, both clusters.
- Diagnostic: `kubectl get snapshotschedule -A -o json` and compare `.metadata.generation`
  against `.status.observedGeneration`.

## Common Anti-Patterns

- **Sharing OCIRepository**: every app needs its own — never reuse
- **HTTPRoute as standalone file**: goes in helmrelease values unless it's a non-app-template resource
- **SOPS**: fully removed — do not introduce
- **External hostnames for cluster traffic**: always `svc.cluster.local`
- **PVC size in helmrelease**: belongs in `ks.yaml` `KOPIUR_CAPACITY`
- **`git add .` / `git add -A`**: always stage specific files by name
- **`spec.patches` in an app `ks.yaml`**: overwritten by the root Kustomization — see above
- **VolSync `ReplicationSource`/`ReplicationDestination`**: removed 2026-08-01, the CRDs are
  gone. Backups are kopiur `Snapshot` / `SnapshotPolicy` / `SnapshotSchedule` / `Restore`
