---
name: modify-app
description: Change an app that is already deployed — bump or repin an image, edit HelmRelease values, resize or move storage, add or remove a component, change a route, rewire a secret, adjust resources or probes — then diff it against the live cluster and test-apply before committing. Use for "change X", "update X's config", "bump X", "add persistence to X", "move X behind tinyauth", "give X more memory", "add a backup to X", "edit X's HelmRelease", or "X needs a different port". For a brand-new app use `deploy-app`; for a pure convention lint use `review-app`. Scoped to the Artemis cluster.
---

# Skill: Modify App

Change one app that is **already running**, without breaking it.

`deploy-app` scaffolds a new app and `review-app` lints the files. This skill is the middle: the
app exists, it works, and you are about to change it while it serves traffic.

**Before editing, read:**

- `.agents/instructions/cluster-conventions.md` and `.agents/instructions/yaml-conventions.md`
- `.agents/skills/modules/templates/helmrelease.md` and `templates/ks.md` — the same spec
  `deploy-app` writes against. Read in full; a partial read gives a partial spec.
- Whichever of these the change touches: `references/storage.md` and `references/kopiur.md`
  (persistence), `references/networking.md` (routes), `references/postgres-dragonfly.md`
  (database or cache), `references/gpu.md` (GPU), `references/media-stack.md` (media namespace)

**Goal:** land one change and prove it is the change you meant.

**Success means:** `just kube diff-ks` shows only your intended difference, the app is applied
live, and the user has confirmed it still works.

**Stop when:** applied and confirmation requested. **Never commit before the user confirms** —
`main` reconciles straight to production and there is no staging cluster.

> **Not this skill:** a Renovate image bump (use `triage-renovate`), a stuck reconcile
> (`fix-flux`), a PVC that must be reprovisioned onto new StorageClass parameters
> (`recreate-pvc`), or data recovery (`kopiur-restore`).

---

## Step 1 — Locate what you are actually changing

The app directory is `kubernetes/apps/<namespace>/<app>/`. Two things routinely waste time here:

```bash
# The Kustomization name is metadata.name in ks.yaml — it is NOT always <app>,
# and one ks.yaml may hold several documents (one per sub-directory).
grep -n "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml

# What files exist for this app
find kubernetes/apps/<namespace>/<app> -type f | sort
```

Where each kind of change lives:

| Changing            | File                                                                          |
| ------------------- | ----------------------------------------------------------------------------- |
| Image tag or digest | `app/helmrelease.yaml` → `controllers.<name>.containers.app.image`            |
| Route / hostname    | `app/helmrelease.yaml` → inline under `route.app` — **never** a separate file |
| Resources, probes   | `app/helmrelease.yaml`                                                        |
| PVC size            | `ks.yaml` → `postBuild.substitute.KOPIUR_CAPACITY`, or the app's own PVC      |
| Adding a component  | `ks.yaml` → `components:` **and** the matching `postBuild.substitute` keys    |
| Secret fields       | `app/externalsecret.yaml`                                                     |
| Chart version       | `app/ocirepository.yaml` → `ref.tag` (bare version, no SHA)                   |

## Step 2 — Capture the live baseline first

This is the step `deploy-app` does not have, and the main reason modifying is safer than
creating: there is a running object to compare against.

```bash
just kube diff-ks <namespace> <ks-name>
```

Exit 0 means the tree already matches the cluster — a clean starting point. **Exit 1 means it
already differs before you have touched anything**, and you must understand why first. Someone
applied uncommitted work, or a reconcile is mid-flight. Do not layer a change on top of an
unexplained diff.

## Step 3 — Check the field is not immutable

Some changes cannot be applied in place. Editing them produces a HelmRelease that never goes
Ready, or a Kustomization that reports success while the live object keeps its old value.

| Field                                            | Reality                                                          |
| ------------------------------------------------ | ---------------------------------------------------------------- |
| PVC `storageClassName`                           | Immutable — use `recreate-pvc`, never an in-place edit           |
| PVC size **downward**                            | Not supported; growing is fine                                   |
| `ResourceClaimTemplate` (GPU)                    | Immutable — must be replaced; see `references/gpu.md`            |
| Service `clusterIP`                              | Immutable                                                        |
| StatefulSet selectors and `volumeClaimTemplates` | Immutable — the StatefulSet must be recreated                    |
| `existingClaim` pointed at a new name            | Silently orphans the old PVC and its data — the app starts empty |

## Step 4 — Make the edit, then render offline

```bash
just kube render-ks <namespace> <ks-name>
```

Needs no cluster — it is `flate build ks`, so it catches schema errors, missing substitution
variables and malformed YAML before anything touches production. Fix every error here.

If the change added a component, confirm its substitutions are present too — a component pulled
in without its `postBuild.substitute` keys renders with an empty value rather than failing.

## Step 5 — Diff against live, and read it

```bash
just kube diff-ks <namespace> <ks-name>
```

Read every line of the output. **The diff should contain your change and nothing else.** Anything
extra is either drift you did not know about or a side effect you did not intend; resolve it
before applying. This is the whole point of the step — an unexplained line here is the cheapest
bug you will ever catch.

## Step 6 — Test and commit

Read `.agents/skills/modules/test-and-commit.md` and follow it. Suspend the root **and** the
target before applying — `apply-ks` suspends nothing, and a child reconciling mid-session
silently reverts your uncommitted edits with no error.

If anything fails, read `.agents/skills/modules/common-issues.md`.

---

## Gotchas

- **The ks name is not always the app name.** `apply-ks` against the wrong name applies a
  different app's manifests. Always grep `ks.yaml` first (Step 1).
- **Never add `spec.patches` to an app's `ks.yaml`.** The root Kustomization sets `spec.patches`
  wholesale, so a child's own block is overwritten — while `flate` renders as though it worked
  and every offline check passes. This is the one change no validation catches. Per-app kustomize
  overrides go in `app/kustomization.yaml` instead; see `references/flux-patterns.md` § The root
  Kustomization overwrites every child's `spec.patches`.
- **ExternalSecret template keys must match the 1Password field names exactly.** A mismatch
  produces an empty secret with no error, and the app fails later with a confusing message.
- **Removing a component does not delete what it created.** Dropping `components/kopiur/backup`
  leaves the `Snapshot`/`SnapshotPolicy` behind unless `prune: true` collects them; confirm what
  actually went away.
- **Changing a route's gateway is a visibility change.** Exactly one of `internal-gateway`,
  `external-gateway` or `edge-gateway` — attaching to both publishes the app.
- **`✔ applied revision` proves nothing about your field.** Confirm the live object carries the
  value you set; a stale artifact or a mid-flight reconcile can report success on the old tree.
- **Never resume Flux before the `Push Artifact` run for your commit is green** — the resume
  applies the pre-commit revision and reverts you. Root first, then the target.

## Not covered by this skill

A clean pass here means the change renders, diffs as intended, and applies. It does **not** mean
the app is correct. This skill does not check component preconditions against the real pod,
database auth viability, whether your resource numbers match observed usage, or the blast radius
of an auth gate on machine-to-machine callers. For that, spawn the `audit-app` subagent.
