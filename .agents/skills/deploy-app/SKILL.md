# Skill: Deploy App

Deploy a new application to Artemis-Cluster following the canonical GitOps workflow.

**Before writing any files, read:**

- `.agents/instructions/cluster-conventions.md`
- `.agents/instructions/yaml-conventions.md`
- `.agents/references/flux-patterns.md`
- `.agents/references/networking.md` (if the app needs a route)
- `.agents/references/storage.md` (if the app needs persistence)

---

## Step 1 — Gather Requirements

Confirm before proceeding:

- **App name** (e.g. `myapp`)
- **Namespace** — must exist or user confirms creating it
- **Chart**: default is app-template v5. Ask if different.
- **Route**: internal (`internal-gateway`) or external (`external-gateway`), or none
- **Hostname**: e.g. `myapp.dcunha.io`
- **Persistence**: PVC needed? If yes: size (e.g. `5Gi`) and whether to use VolSync backup
- **Secrets**: 1Password ExternalSecret needed? If yes: 1Password item name

Read 1–2 existing apps in the same namespace to match local patterns before writing anything:

```bash
ls kubernetes/apps/<namespace>/
cat kubernetes/apps/<namespace>/<existing-app>/ks.yaml
cat kubernetes/apps/<namespace>/<existing-app>/app/helmrelease.yaml
```

---

## Step 2 — Find a Reference with Kubesearch

Invoke the `kubesearch` skill for the app name. Use the top result to fill in the remaining unknowns:

| What | Where it goes |
|---|---|
| Image repository + tag | Step 3 (image pinning) |
| Container port | `service.app.ports.http.port` in helmrelease |
| Mount paths | `persistence` block in helmrelease |
| App-specific env vars | `containers.app.env` in helmrelease |
| Secret env var names | `externalsecret.yaml` template fields |

Adapt any patterns from the reference to Artemis-Cluster conventions as documented in the kubesearch skill (remove TZ, replace HelmRepository with OCIRepository, replace Ingress with HTTPRoute, flag any shared Dragonfly/MariaDB deps, etc.).

If kubesearch returns no results, fall back to the GitHub search in the kubesearch skill and proceed with what you find.

---

## Step 3 — Pin the Image Tag

Using the image repository identified in Step 2, read `.agents/skills/modules/image-pinning.md` and follow it.

---

## Step 4 — Create Directory Structure

Read `.agents/skills/modules/templates/directory.md` and create the layout.

---

## Step 5 — Write Files

Read the relevant template module for each file and write it:

| File | Template module |
|---|---|
| `ks.yaml` | `.agents/skills/modules/templates/ks.md` |
| `app/kustomization.yaml` | `.agents/skills/modules/templates/kustomization.md` |
| `app/ocirepository.yaml` | `.agents/skills/modules/templates/ocirepository.md` |
| `app/helmrelease.yaml` | `.agents/skills/modules/templates/helmrelease.md` |
| `app/externalsecret.yaml` | `.agents/skills/modules/templates/externalsecret.md` (only if secrets needed) |

All YAML must follow `.agents/skills/modules/sorting.md`.

---

## Step 6 — Add to Namespace Kustomization

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources.

---

## Step 7 — Verify Files

```bash
find kubernetes/apps/<namespace>/<app> -type f | sort
```

Confirm all expected files are present.

---

## Step 8 — Test and Commit

Read `.agents/skills/modules/test-and-commit.md` and follow it.

If anything fails, read `.agents/skills/modules/common-issues.md` for diagnostics.
