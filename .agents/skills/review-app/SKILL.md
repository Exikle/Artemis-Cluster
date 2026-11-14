---
name: review-app
description: Lint an app's manifests against this repo's structural conventions (directory shape, field ordering, image pinning, security context, probes, routes, secrets wiring) and report or optionally fix what deviates. Fast and file-only. It does not read the cluster. Use for "lint X app", "check X against conventions", "review X's manifests", "does X follow the conventions", or a pre-commit pass on an app directory. For a deep correctness audit that reads the live cluster (component wiring vs the real pod, database auth viability, resource sizing, auth blast radius), spawn the `audit-app` subagent instead. Scoped to the Artemis cluster.
---

# Skill: Review App Manifests (lint)

This skill is a mechanical convention check of the manifests of one app. It is file-only and does not read the
cluster. It answers "is this written the way this repo writes things", not "is this correct".

> If the question is whether the app actually _works_ (whether its components match its pod,
> whether its database auth path is viable, whether its resources match reality, whether adding an
> auth gate would break a machine caller), this is the wrong tool. Spawn the `audit-app`
> subagent (`.agents/agents/audit-app.md`).
>
> This skill reports PASS on an app whose kopiur mover runs as the wrong uid, whose memory
> limit is twenty times its working set, and whose tinyauth gate has no ACL keys in the tinyauth
> HelmRelease. Those faults belong to `audit-app` by design. Do not try to cover them here.

Before you review, read these files:

- `.agents/instructions/cluster-conventions.md`
- `.agents/instructions/yaml-conventions.md`
- `.agents/references/flux-patterns.md`
- `.agents/references/networking.md` (if the app has a route)
- `.agents/references/storage.md` (if it has persistence) and `.agents/references/kopiur.md`
  (if it is backed up)

---

> Read these module files in full. `deploy-app` and `review-app` share them deliberately. One skill writes the files, the other checks them against the same spec, and a duplicate would let the two drift apart. `templates/ks.md` and `templates/helmrelease.md` are about 135 lines. A partial read gives a partial spec.

## Step 1: Identify the App

Make sure that you have these before you proceed:

- App name (for example `sonarr`)
- Namespace (for example `media`)
- Fix mode: report-only, or apply fixes in place

Derive the root path: `clusters/artemis/kubernetes/apps/<namespace>/<app>/`

---

## Step 2: Read All Manifests

```bash
find clusters/artemis/kubernetes/apps/<namespace>/<app> -type f | sort
cat clusters/artemis/kubernetes/apps/<namespace>/kustomization.yaml
cat clusters/artemis/kubernetes/apps/<namespace>/<app>/ks.yaml
cat clusters/artemis/kubernetes/apps/<namespace>/<app>/app/kustomization.yaml
cat clusters/artemis/kubernetes/apps/<namespace>/<app>/app/ocirepository.yaml
cat clusters/artemis/kubernetes/apps/<namespace>/<app>/app/helmrelease.yaml
```

Read the files before you evaluate them. Do not guess at their contents.

Read every file that `find` listed, not only the five named above. Non-standard kinds live flat in
`app/`: an `externalsecret.yaml`, a `securitypolicy.yaml`, an `oidcclient.yaml`, a
`resourceclaimtemplate.yaml`, a `resources/` directory of config files. If `find` shows a file that the
list does not name, read it and say so in the report. A file that you did not read is a file that you did not check.

---

## Step 3: Run the Checklists

Read each checklist module and work through every item. Mark each one **PASS**, **FAIL**, or **N/A**.

| Checklist                             | Module                                                |
| ------------------------------------- | ----------------------------------------------------- |
| Directory structure                   | `.agents/skills/modules/checklists/directory.md`      |
| `ks.yaml`                             | `.agents/skills/modules/checklists/ks.md`             |
| `app/ocirepository.yaml`              | `.agents/skills/modules/checklists/ocirepository.md`  |
| `app/helmrelease.yaml`                | `.agents/skills/modules/checklists/helmrelease.md`    |
| ExternalSecret (inline or standalone) | `.agents/skills/modules/checklists/externalsecret.md` |
| YAML sorting (all files)              | `.agents/skills/modules/checklists/yaml-sorting.md`   |
| Advisory (optimizations)              | `.agents/skills/modules/checklists/advisory.md`       |

The sorting rules reference is `.agents/instructions/yaml-conventions.md` (always loaded, and the single
authority on ordering).

Two checks read a second file inside the repo. Do them properly and do not skim them,
because they are the only cross-file checks that a lint can afford:

- K16: compare `postBuild.substitute.KOPIUR_PUID` against the HelmRelease's `runAsUser`. Both
  numbers are in files you already read.
- K14: the shared cluster uses password auth over TLS. An app wired to `postgres/app` must use the
  DSN key that matches its driver (`url` libpq, `url_node` postgres-js, `url_prisma` Prisma). You can see a mismatch in the
  HelmRelease that you already read.

---

## Step 4: Render Check

A lint that never builds can pass a file that kustomize rejects. Render before you report:

```bash
just kube render-ks <namespace> <ks-name>
```

`<ks-name>` is `metadata.name` from `ks.yaml`, not the directory name. A non-zero exit is a
**FAIL**, and you must quote the build error. The usual cause is a component path with three `../` instead of
four (K15), or a substitution that the component requires and `postBuild` does not supply.

This is a local build, not a cluster call. It touches nothing.

---

## Step 5: Report Findings

Output a summary grouped by severity in this format. Put blank lines between every item, bold
the check IDs, and code-format the values:

```markdown
## Lint: <app> (<namespace>)

---

### FAIL — must fix _(auto-fixable)_

**[H8]** `defaultPodOptions.securityContext.runAsNonRoot` is missing.

---

### WARN — convention drift, fix preferred _(auto-fixable)_

**[Y3]** `enabled` is not the first field in `probes.liveness`.

**[H27a]** emptyDir `tmp` uses `globalMounts` instead of `advancedMounts` with `subPath`.

---

### ADVISORY — recommendations _(requires human review — never auto-fix)_

**[A2]** App has a PVC but no kopiur component — data is not backed up.

**[A10]** App is on `edge-gateway` (public) with no SecurityPolicy OIDC — confirm this is intentional.

---

### PASS

- Directory structure is correct.
- OCIRepository is standalone and correctly named.
- Security context is complete.
- All sorting checks pass.
- `just kube render-ks` builds clean.

---

### Not checked by this skill

This was a file-only lint. It did **not** check:

- component substitutions against the pod's real uid, controller kind, or ACL keys in another
  namespace
- whether the app's database driver can actually authenticate against `postgres-rw`
- resource requests and limits against observed usage
- what a tinyauth or OIDC gate would break among machine-to-machine callers
- live Service ports, HTTPRoute parents, HPA targets, or backup freshness
- whether the repo's own docs still describe this app correctly

Spawn the `audit-app` subagent for any of those.
```

The **Not checked** block is mandatory, including on a completely clean run. A lint that reports
only PASS reads as a clearance that it did not give.

If nothing fails and nothing is advisable, confirm that the manifests follow the conventions and that no changes
are needed. Still use the full headed format, including **Not checked**.

---

## Step 6: Fix Issues (if fix mode is enabled)

Work in a worktree: run `just wt new fix/<slug>` first (`AGENTS.md` rule 7). For each FAIL or WARN, edit the file in place. Do NOT auto-fix ADVISORY items, because those
require user confirmation. Use these files:

- `.agents/instructions/yaml-conventions.md` for all ordering rules
- `.agents/skills/modules/templates/ks.md` as the reference for `ks.yaml` corrections
- `.agents/skills/modules/templates/helmrelease.md` as the reference for HelmRelease corrections

Apply all fixes before you show a diff. Do not change values or behavior. Fix only ordering,
missing boilerplate, and convention violations.

After the fixes, run Step 4 again, then read the edited files again and make sure that no issues remain.

---

## Step 7: Test and Commit (if you applied fixes)

Read `.agents/skills/modules/test-and-commit.md` and follow it.

If anything fails during apply, read `.agents/skills/modules/common-issues.md` for diagnostics.
