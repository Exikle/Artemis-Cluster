# Reference: Flux Patterns — Artemis-Cluster

## Core Workflow

Test live before you commit, because `main` goes directly to production. The sequence is in
`.agents/instructions/commit-style.md` § The sequence. The steps are: suspend the root and the
target, run `apply-ks`, wait for the user, commit, wait for CI, run `sync-flux ocirepo flux-system`
until the artifact carries your commit, then resume the root and then the target. This file does
not restate them. That file wins.

These points are specific to Flux behavior:

- `suspend-ks` and `resume-ks` act only on the Kustomization that you name. The root is always a
  separate call. `apply-ks` suspends nothing at all.
- `FluxInstance/flux` generates the root (`flux-system`). A bare `flux suspend` on the root does
  not hold, because flux-operator drops `spec.suspend` on its next reconcile. `suspend-ks` on the
  root pauses the FluxInstance first (`fluxcd.controlplane.io/reconcile=disabled`). `resume-ks`
  unpauses it only after the root is resumed. While the FluxInstance is paused, flux-operator does
  nothing at all: no Flux upgrades and no drift correction. Do not leave the root suspended.
- The order is enforced on the way out, not on the way in. `resume-ks` refuses to wake a child
  while the root is still suspended. The child would reconcile its OLD spec and write stale values
  straight back. That regrew 13 PVCs, and `allowVolumeExpansion` made it one-way. Going in, the
  order does not matter, and `suspend-ks` only warns.
- `just kube diff-ks <ns> <ks>` is read-only and safe to run at any time. It renders locally and
  runs `kubectl diff --server-side`, so you see only real drift. For the root, it renders through
  `flux build` against the live root, because flate cannot see the root. Exit 0 means no
  differences. Exit 1 means differences or a failed render. Tell them apart by the last line, not
  by the code.
- Resuming is not optional. If a session ends before `resume-ks`, Flux stays suspended and nothing
  reconciles until someone notices. Read the last line of `resume-ks`. It warns about anything that
  is still suspended.

Other force-sync targets:

```bash
just kube sync-flux hr                   # all HelmReleases
just kube sync-flux ks                   # all Kustomizations
just kube sync-flux es                   # all ExternalSecrets
just kube sync-flux ocirepo flux-system  # the one source that carries the repo
```

Name the resource in `sync-flux ocirepo`. The bare form annotates **every** OCIRepository in the
cluster (`kubectl get ocirepository -A --no-headers | wc -l`). There is no `GitRepository` to sync.
The Flux source is an OCIRepository that CI builds, and `just kube sync-flux gitrepo` has no live
target.

Annotating does not make CI finish faster. If the `Push OCI Artifact` run is not green, the source
re-resolves to the same pre-commit artifact and reports success. The webhook below usually moves
the artifact on its own within seconds after the run finishes. Check the artifact before you reach
for `sync-flux`.

## The webhook that makes a merge reconcile — and the port that silently swallows it

Flux polling does not carry a push to the cluster. The `oci-push` workflow pings a
notification-controller `Receiver` after it pushes the artifact, and that ping triggers the
reconcile. Without the ping, every merge waits for the 1m poll of source-controller.

notification-controller serves two HTTP servers on two ports, and the wrong one accepts
everything.

| Service                   | Pod port | What it is                             | `GET /` | `GET /hook/<path>` |
| ------------------------- | -------- | -------------------------------------- | ------- | ------------------ |
| `notification-controller` | 9090     | event server (alerts in)               | 400     | 400                |
| `webhook-receiver`        | 9292     | **Receiver server — the one you want** | 404     | 400                |

The Receiver server is the one you want. The event server answers 400 to every GET and accepts any
POST with a 202. A route that points at the event server looks healthy, but it never triggers a
reconcile.

Keep these points in mind:

- The HTTPRoute backend must be `webhook-receiver`, not `notification-controller`.
- The gatus condition is `[STATUS] == 404`. This is the better assertion, because a 404 on `/` is
  unique to the Receiver server, while the _wrong_ server returns 400.
- A successful hook POST returns HTTP 200, not 202. The accept-list of the CI step is
  `200, 202, 429`. It was `202, 429`, which was tuned to the behavior of the event server and
  scored a working webhook as a failure.
- `flux-notify` sets `onError: continue`, so a broken ping never fails the build. This is
  deliberate, because the artifact is already pushed. But it means the step cannot alert you. Make
  sure that the webhook works by its effect, not by the step.

The only proof that the webhook works is `lastHandledReconcileAt` that moves without a manual sync:

```bash
kubectl get ocirepository -n flux-system flux-system \
  -o jsonpath='{.status.lastHandledReconcileAt}'
```

Compare the value with the timestamp of the notify step in the run log. `✔ applied revision` proves
nothing, because that message is the poll doing its job.

---

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

Kustomizations live in their target namespace (for example `observability` or `media`), NOT always
in `flux-system`.

## Key Rules

- Set `prune: false` on the `flux-instance` Kustomization. Never prune Flux itself.
- `dependsOn` must list the actual runtime dependencies, not only the chart sources.
- `interval: 1h` is the standard in `ks.yaml`. `grep -h 'interval:' kubernetes/apps/*/*/ks.yaml | sort | uniq -c`
  shows the exceptions.
- The child-defaults patch that the FluxInstance puts on the root injects `retryInterval: 1m`. An
  explicit one in a child is redundant. It is harmless, but do not add it "because it's missing".
  It is not missing.

The live source of truth is `FluxInstance/flux` in `flux-system`, which syncs `kind: OCIRepository`
from `oci://registry.dcunha.io/exikle/artemis-cluster`. To read the controller versions, run
`kubectl get deploy -n flux-system -o jsonpath='{range .items[*]}{.metadata.name} {.spec.template.spec.containers[0].image}{"\n"}{end}'`.

## Cross-Namespace Kustomization Gotchas

If a `Kustomization` lives outside `flux-system` (for example in `media` or `cortex`), both
references must be explicit:

```yaml
spec:
    sourceRef:
        kind: OCIRepository
        name: flux-system
        namespace: flux-system
    dependsOn:
        - name: miroir
          namespace: miroir-system
```

`sourceRef.namespace` is REQUIRED. If you omit it, it resolves to the namespace of the child, and
Flux does not find the source. The same applies to every cross-namespace `dependsOn` entry. If
either is missing, the reconciliation fails with a silent "not found".

| Field            | Correct         | Wrong                                                                                                                     |
| ---------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `sourceRef.kind` | `OCIRepository` | `GitRepository` — the flux source is OCI; `grep -L 'kind: OCIRepository' kubernetes/apps/*/*/ks.yaml` should list nothing |

The only live `kind: GitRepository` in the repo is
`kubernetes/components/alerts/alertmanager/alert.yaml`. There it is a notification `eventSource`
selector, which is unrelated to Kustomization sources.

## CRD Timing Race

A Kustomization can deploy both a HelmRelease (which installs CRDs) and resources that depend on
those CRDs (for example `AlertmanagerConfig` or `Probe`). Flux then applies everything in one shot,
before Helm has run.

Symptom: The HelmRelease shows healthy, but the expected CRs are missing.

Fix: After the HelmRelease is healthy, force-reconcile the affected Kustomization:

```bash
flux reconcile kustomization <name> -n <namespace>
```

## The root Kustomization overwrites every child's `spec.patches`

The FluxInstance (`kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`) patches the
root `flux-system` Kustomization, which syncs `./kubernetes/apps` directly. The patch is a
`patches:` block that targets `kustomize.toolkit.fluxcd.io/Kustomization` with `metadata.name: _`.
This means **every child `ks.yaml` in the repo**. It sets `deletionPolicy`, `retryInterval`, and a
nested `spec.patches` that applies the HelmRelease install, upgrade, and rollback defaults.

The patch sets `spec.patches` wholesale. A `patches:` block that you write into the own `ks.yaml`
of an app is silently replaced. There is no error and no warning. The patch never applies, and the
symptom shows up downstream as "my override isn't taking effect". `flate` does not evaluate the
parent patch either, so a local render looks like the override worked.

Put per-app kustomize overrides in the own `app/kustomization.yaml` of the app. The kustomize build
of the child evaluates `patches:` there, and the parent does not touch it. Do not add `spec.patches`
to a `ks.yaml`.

This cost a full afternoon during a namespace move in 2026-06, before anyone identified the
mechanism.

## kopiur CRs stall `wait: true` health checks

kopiur writes `status.observedGeneration` on a `SnapshotSchedule` at its **first** reconcile and
never again. If you edit the spec of the schedule afterwards, the object stays at
`generation != observedGeneration` permanently. kstatus reads that as `InProgress`. A Kustomization
with `wait: true` then hangs on health checks for the full timeout, in every cycle, indefinitely.
While it is stuck on a stale revision, it silently re-applies old configuration over a change.

- `healthCheckExprs` does not help. Flux evaluates the generation precondition _before_ the CEL
  expressions, so the stale field still wins.
- Fix: Drop `wait: true` and gate on the HelmRelease through explicit `spec.healthChecks`. That is
  what "the app is up" actually means.
- `SnapshotPolicy` tracks `observedGeneration` correctly. `Restore` does **not**. It is terminal,
  so an edit to a completed one stalls health checks (`kopiur.md`: delete and recreate it instead).
  `restore.yaml` does **not** carry `kustomize.toolkit.fluxcd.io/ssa: ignore`. Flux skips such
  objects entirely, so the annotation would stop Flux from creating any Restore. Do not add it back.
- Diagnostic: Run `kubectl get snapshotschedule -A -o json` and compare `.metadata.generation` with
  `.status.observedGeneration`.

## Decode a base64 1Password field per-field, not item-wide

`decodingStrategy: Base64` on a `dataFrom.extract` applies to **every** field in the item. If only
one field is stored encoded, use `| b64dec` in the target template instead. The `cosign` item of
`flux-webhook` is the live example. `cosign.pub` is base64, but `COSIGN_PASSWORD` next to it is
plaintext, and an item-wide strategy corrupts it.

## Common Anti-Patterns

- Sharing an OCIRepository: every app needs its own. Never reuse one.
- HTTPRoute as a standalone file: it goes in the helmrelease values, unless it is a non-app-template resource.
- **SOPS**, **VolSync**: removed. `AGENTS.md` § "What was deliberately removed" wins.
- External hostnames for cluster traffic: always use `svc.cluster.local`.
- PVC size in the helmrelease: it belongs in `KOPIUR_CAPACITY` in `ks.yaml`.
- `spec.patches` in an app `ks.yaml`: the root Kustomization overwrites it. See above.
