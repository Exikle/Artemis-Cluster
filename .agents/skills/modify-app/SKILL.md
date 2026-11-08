---
name: modify-app
description: Change an app that is already deployed — bump or repin an image, edit HelmRelease values, resize or move storage, add or remove a component, change a route, rewire a secret, adjust resources or probes. Then diff it against the live cluster and test-apply before committing. Use for "change X", "update X's config", "bump X", "add persistence to X", "move X behind tinyauth", "give X more memory", "add a backup to X", "edit X's HelmRelease", or "X needs a different port". For a brand-new app use `deploy-app`. For a pure convention lint use `review-app`. Scoped to the Artemis cluster.
---

# Skill: Modify App

Change one app that is already running, without breaking it.

`deploy-app` scaffolds a new app and `review-app` lints the files. This skill is the middle case. The
app exists and works, and you change it while it serves traffic.

Before you edit, read these files:

- `.agents/instructions/cluster-conventions.md` and `.agents/instructions/yaml-conventions.md`
- `.agents/skills/modules/templates/helmrelease.md` and `templates/ks.md`, the same spec
  that `deploy-app` writes against. Read them in full, because a partial read gives a partial spec.
- Whichever of these files the change touches: `references/storage.md` and `references/kopiur.md`
  (persistence), `references/networking.md` (routes), `references/postgres-dragonfly.md`
  (database or cache), `references/gpu.md` (GPU), `references/media-stack.md` (media namespace)

Goal: land one change and prove that it is the change you meant.

Success means that `just kube diff-ks` shows only your intended difference, the app is applied
live, and the user has confirmed that it still works.

Stop when you applied the change and requested confirmation. Never commit before the user confirms.
`main` reconciles straight to production and there is no staging cluster.

> This skill does not cover these cases: a Renovate image bump (use `triage-renovate`), a stuck reconcile
> (`fix-flux`), a PVC that you must reprovision onto new StorageClass parameters
> (`recreate-pvc`), or data recovery (`kopiur-restore`).

---

## Step 1: Locate what you are changing

The app directory is `kubernetes/apps/<namespace>/<app>/`. Two things routinely waste time here:

```bash
# The Kustomization name is metadata.name in ks.yaml — it is NOT always <app>,
# and one ks.yaml may hold several documents (one per sub-directory).
grep -n "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml

# What files exist for this app
find kubernetes/apps/<namespace>/<app> -type f | sort
```

Each kind of change lives in a specific file:

| Changing            | File                                                                          |
| ------------------- | ----------------------------------------------------------------------------- |
| Image tag or digest | `app/helmrelease.yaml` → `controllers.<name>.containers.app.image`            |
| Route / hostname    | `app/helmrelease.yaml` → inline under `route.app` — **never** a separate file |
| Resources, probes   | `app/helmrelease.yaml`                                                        |
| PVC size            | `ks.yaml` → `postBuild.substitute.KOPIUR_CAPACITY`, or the app's own PVC      |
| Adding a component  | `ks.yaml` → `components:` **and** the matching `postBuild.substitute` keys    |
| Secret fields       | `app/helmrelease.yaml` → `externalSecrets.<id>`                               |
| Chart version       | `app/ocirepository.yaml` → `ref.tag` (bare version, no SHA)                   |

## Step 2: Capture the live baseline first

`deploy-app` does not have this step. It is the main reason that modifying is safer than
creating: there is a running object to compare against.

```bash
just kube diff-ks <namespace> <ks-name>
```

Exit 0 means that the tree already matches the cluster. That is a clean starting point. Exit 1 means that the tree
already differs before you touched anything, and you must understand why first. Someone
applied uncommitted work, or a reconcile is in progress. Do not layer a change on top of an
unexplained diff.

## Step 3: Make sure that the field is not immutable

Some changes cannot be applied in place. If you edit them, you get a HelmRelease that never goes
Ready, or a Kustomization that reports success while the live object keeps its old value.

| Field                                            | Reality                                                             |
| ------------------------------------------------ | ------------------------------------------------------------------- |
| PVC `storageClassName`                           | Immutable. Use `recreate-pvc`, never an in-place edit               |
| PVC size **downward**                            | Not supported; growing is fine                                      |
| `ResourceClaimTemplate` (GPU)                    | Immutable. You must replace it; see `references/gpu.md`             |
| Service `clusterIP`                              | Immutable                                                           |
| StatefulSet selectors and `volumeClaimTemplates` | Immutable. You must recreate the StatefulSet                        |
| `existingClaim` pointed at a new name            | Silently orphans the old PVC and its data, and the app starts empty |

## Step 4: Make the edit, then render offline

```bash
just kube render-ks <namespace> <ks-name>
```

This needs no cluster. It is `flate build ks`, so it catches schema errors, missing substitution
variables and malformed YAML before anything touches production. Fix every error here.

If the change added a component, make sure that its substitutions are present too. A component pulled
in without its `postBuild.substitute` keys renders with an empty value and does not fail.

## Step 5: Diff against live, and read it

```bash
just kube diff-ks <namespace> <ks-name>
```

Read every line of the output. The diff must contain your change and nothing else. Anything
extra is either drift you did not know about or a side effect you did not intend. Resolve it
before you apply. This is the whole point of the step: an unexplained line here is the cheapest
bug you will ever catch.

## Step 6: Test and commit

Read `.agents/skills/modules/test-and-commit.md` and follow it. Edit in a worktree: run
`just wt new <type>/<slug>` before the first edit of Step 1 (`AGENTS.md` rule 7).

If anything fails, read `.agents/skills/modules/common-issues.md`.

---

## Gotchas

- The ks name is not always the app name. `apply-ks` against the wrong name applies a
  different app's manifests. Always grep `ks.yaml` first (Step 1).
- Never add `spec.patches` to an app's `ks.yaml`. The root Kustomization sets `spec.patches`
  wholesale, so it overwrites the own block of a child. `flate` still renders as though it worked
  and every offline check passes. No validation catches this change. Per-app kustomize
  overrides go in `app/kustomization.yaml` instead. See `references/flux-patterns.md` § The root
  Kustomization overwrites every child's `spec.patches`.
- ExternalSecret template keys must match the 1Password field names exactly. A mismatch
  produces an empty secret with no error, and the app fails later with a confusing message.
- Removing a component does not delete what it created. If you drop `components/kopiur/backup`, the `SnapshotPolicy`, `SnapshotSchedule` and PVC stay
  behind unless `prune: true` collects them. Make sure that you know what
  went away.
- Changing the gateway of a route changes its visibility. Use exactly one of `internal-gateway`
  (LAN-only) or `edge-gateway` (public). If you attach to both, you publish the app. `external-gateway`
  is legacy and takes no new routes. If you move a `*.dcunha.io` route to `edge-gateway`, you must also
  change any `sectionName: https` to `https-dcunha` (`towonel-agent.md` § Which gateway to
  attach a route to).
- `✔ applied revision` proves nothing about your field. Make sure that the live object carries the
  value you set. A stale artifact or a reconcile in progress can report success on the old tree.

## Not covered by this skill

A clean pass here means that the change renders, diffs as intended, and applies. It does **not** mean
that the app is correct. This skill does not check component preconditions against the real pod,
database auth viability, whether your resource numbers match observed usage, or the blast radius
of an auth gate on machine-to-machine callers. For that, spawn the `audit-app` subagent.
