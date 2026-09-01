---
name: review-app
description: Lint an app's manifests against this repo's structural conventions — directory shape, field ordering, image pinning, security context, probes, routes, secrets wiring — and report or optionally fix what deviates. Fast and file-only; it does not read the cluster. Use for "lint X app", "check X against conventions", "review X's manifests", "does X follow the conventions", or a pre-commit pass on an app directory. For a deep correctness audit that reads the live cluster — component wiring vs the real pod, database auth viability, resource sizing, auth blast radius — spawn the `audit-app` subagent instead. Scoped to the Artemis cluster.
---

# Skill: Review App Manifests (lint)

Mechanical convention check of one app's manifests. **File-only — this skill does not read the
cluster.** It answers "is this written the way this repo writes things", not "is this correct".

> **If the question is whether the app actually _works_** — whether its components match its pod,
> whether its database auth path is viable, whether its resources match reality, whether adding an
> auth gate would break a machine caller — **this is the wrong tool.** Spawn the `audit-app`
> subagent (`.agents/agents/audit-app.md`).
>
> This skill will report PASS on an app whose kopiur mover runs as the wrong uid, whose memory
> limit is twenty times its working set, and whose tinyauth gate has no ACL keys in the tinyauth
> HelmRelease. Those are `audit-app`'s job by design, not gaps to paper over here.

**Before reviewing, read:**

- `.agents/instructions/cluster-conventions.md`
- `.agents/instructions/yaml-conventions.md`
- `.agents/references/flux-patterns.md`
- `.agents/references/networking.md` (if the app has a route)
- `.agents/references/storage.md` (if it has persistence) and `.agents/references/kopiur.md`
  (if it is backed up)

---

## Step 1 — Identify the App

Confirm before proceeding:

- **App name** (e.g. `sonarr`)
- **Namespace** (e.g. `media`)
- **Fix mode**: report-only or apply fixes in place?

Derive the root path: `kubernetes/apps/<namespace>/<app>/`

---

## Step 2 — Read All Manifests

```bash
find kubernetes/apps/<namespace>/<app> -type f | sort
cat kubernetes/apps/<namespace>/kustomization.yaml
cat kubernetes/apps/<namespace>/<app>/ks.yaml
cat kubernetes/apps/<namespace>/<app>/app/kustomization.yaml
cat kubernetes/apps/<namespace>/<app>/app/ocirepository.yaml
cat kubernetes/apps/<namespace>/<app>/app/helmrelease.yaml
```

Read the files before evaluating — do not guess at their contents.

**Read every file `find` listed, not only the five named above.** Non-standard kinds live flat in
`app/` — an `externalsecret.yaml`, a `securitypolicy.yaml`, an `oidcclient.yaml`, a
`resourceclaimtemplate.yaml`, a `resources/` directory of config files. If `find` shows one the
list does not name, read it and say so in the report; an unread file is an unchecked file.

---

## Step 3 — Run the Checklists

Read each checklist module and work through every item. Mark each **PASS**, **FAIL**, or **N/A**.

| Checklist                              | Module                                                |
| -------------------------------------- | ----------------------------------------------------- |
| Directory structure                    | `.agents/skills/modules/checklists/directory.md`      |
| `ks.yaml`                              | `.agents/skills/modules/checklists/ks.md`             |
| `app/ocirepository.yaml`               | `.agents/skills/modules/checklists/ocirepository.md`  |
| `app/helmrelease.yaml`                 | `.agents/skills/modules/checklists/helmrelease.md`    |
| `app/externalsecret.yaml` (if present) | `.agents/skills/modules/checklists/externalsecret.md` |
| YAML sorting (all files)               | `.agents/skills/modules/checklists/yaml-sorting.md`   |
| Advisory (optimizations)               | `.agents/skills/modules/checklists/advisory.md`       |

Sorting rules reference: `.agents/instructions/yaml-conventions.md` (always-loaded — the single
authority on ordering)

Two checks read a second file inside the repo and are worth doing properly rather than skimming,
because they are the only cross-file checks a lint can afford:

- **K16** — compare `postBuild.substitute.KOPIUR_PUID` against the HelmRelease's `runAsUser`. Both
  numbers are in files you have already read.
- **K14** — `pooler-rw` is cert-auth only. An app wired to `postgres/cert` whose driver takes only
  host/port/user/password needs a pgbouncer sidecar as well, and the sidecar is visible in the
  HelmRelease you have already read.

---

## Step 4 — Render Check

A lint that never builds can pass a file kustomize rejects. Render before reporting:

```bash
just kube render-local-ks <namespace> <ks-name>
```

`<ks-name>` is `metadata.name` from `ks.yaml`, not the directory name. A non-zero exit is a
**FAIL** with the build error quoted — most often a component path with three `../` instead of
four (K15), or a substitution the component requires that `postBuild` does not supply.

This is a local build, not a cluster call. It touches nothing.

---

## Step 5 — Report Findings

Output a summary grouped by severity using this format — blank lines between every item, bold
check IDs, code-formatted values:

```markdown
## Lint: <app> (<namespace>)

---

### FAIL — must fix _(auto-fixable)_

**[H8]** `defaultPodOptions.securityContext.runAsNonRoot` is missing.

**[K12]** `dependsOn` entry for `rook-ceph-cluster` is missing the `namespace: rook-ceph` field.

---

### WARN — convention drift, fix preferred _(auto-fixable)_

**[Y3]** `enabled` is not the first field in `probes.liveness`.

**[H27a]** emptyDir `tmp` uses `globalMounts` instead of `advancedMounts` with `subPath`.

---

### ADVISORY — recommendations _(requires human review — never auto-fix)_

**[A2]** App has a PVC but no kopiur component — data is not backed up.

**[A10]** App is on `external-gateway` with no SecurityPolicy OIDC — confirm this is intentional.

---

### PASS

- Directory structure is correct.
- OCIRepository is standalone and correctly named.
- Security context is complete.
- All sorting checks pass.
- `just kube render-local-ks` builds clean.

---

### Not checked by this skill

This was a file-only lint. It did **not** check:

- component substitutions against the pod's real uid, controller kind, or ACL keys in another
  namespace
- whether the app's database driver can actually authenticate against `pooler-rw`
- resource requests and limits against observed usage
- what a tinyauth or OIDC gate would break among machine-to-machine callers
- live Service ports, HTTPRoute parents, HPA targets, or backup freshness
- whether the repo's own docs still describe this app correctly

Spawn the `audit-app` subagent for any of those.
```

The **Not checked** block is mandatory, including on a completely clean run. A lint that reports
only PASS reads as a clearance it did not give.

If nothing fails or is advisable: confirm the manifests are convention-compliant and no changes
are needed, still using the full headed format including **Not checked**.

---

## Step 6 — Fix Issues (if fix mode enabled)

For each FAIL or WARN, edit the file in place using (do NOT auto-fix ADVISORY items — those
require user confirmation):

- `.agents/instructions/yaml-conventions.md` for all ordering rules
- `.agents/skills/modules/templates/ks.md` as the reference for `ks.yaml` corrections
- `.agents/skills/modules/templates/helmrelease.md` as the reference for HelmRelease corrections

Apply all fixes before showing a diff. Do not change values or behavior — only fix ordering,
missing boilerplate, and convention violations.

Re-run Step 4 after fixing, then re-read the edited files and confirm no issues remain.

---

## Step 7 — Test and Commit (if fixes were applied)

Read `.agents/skills/modules/test-and-commit.md` (fixes section) and follow it.

If anything fails during apply, read `.agents/skills/modules/common-issues.md` for diagnostics.
