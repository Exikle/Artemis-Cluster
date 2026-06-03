# Skill: Review App Deployment

Audit an existing app's manifests against Artemis-Cluster conventions and report (then optionally fix) any violations.

**Before reviewing, read:**

- `.agents/instructions/cluster-conventions.md`
- `.agents/instructions/yaml-conventions.md`
- `.agents/references/flux-patterns.md`
- `.agents/references/networking.md` (if app has a route)
- `.agents/references/storage.md` (if app has persistence)

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
# if present:
cat kubernetes/apps/<namespace>/<app>/app/externalsecret.yaml
```

Read the files before evaluating — do not guess at their contents.

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

Sorting rules reference: `.agents/skills/modules/sorting.md`

---

## Step 4 — Report Findings

Output a summary grouped by severity using this format — blank lines between every item, bold check IDs, code-formatted values:

```markdown
## Review: <app> (<namespace>)

---

### FAIL — must fix

**[H8]** `defaultPodOptions.securityContext.runAsNonRoot` is missing.

**[K12]** `dependsOn` entry for `rook-ceph-cluster` is missing the `namespace: rook-ceph` field.

---

### WARN — convention drift, fix preferred

**[Y3]** `enabled` is not the first field in `probes.liveness`.

**[H27a]** emptyDir `tmp` uses `globalMounts` instead of `advancedMounts` with `subPath`.

---

### ADVISORY — recommendations

**[A2]** App has a PVC but no VolSync component — data is not backed up.

**[A10]** App is on `external-gateway` with no SecurityPolicy OIDC — confirm this is intentional.

---

### PASS

- Directory structure is correct.
- OCIRepository is standalone and correctly named.
- Security context is complete.
- All sorting checks pass.
```

If nothing fails or is advisable: confirm the deployment is convention-compliant and no changes are needed, still using the full headed format.

---

## Step 5 — Fix Issues (if fix mode enabled)

For each FAIL or WARN, edit the file in place using (do NOT auto-fix ADVISORY items — those require user confirmation):

- `.agents/skills/modules/sorting.md` for all ordering rules
- `.agents/skills/modules/templates/ks.md` as the reference for ks.yaml corrections
- `.agents/skills/modules/templates/helmrelease.md` as the reference for HelmRelease corrections

Apply all fixes before showing a diff. Do not change values or behavior — only fix ordering, missing boilerplate, and convention violations.

After fixing, re-read the edited files and confirm no issues remain.

---

## Step 6 — Test and Commit (if fixes were applied)

Read `.agents/skills/modules/test-and-commit.md` (fixes section) and follow it.

If anything fails during apply, read `.agents/skills/modules/common-issues.md` for diagnostics.
