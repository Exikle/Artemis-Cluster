---
name: deploy-app
description: Deploy a new app into the Flux cluster end to end — scaffold the ks.yaml and app/ manifests, wire the OCIRepository, HelmRelease, routes, storage, and any ExternalSecret, then test-apply before committing. Use for "deploy X", "add app X", "set up X in namespace Y", "create a new app", or "onboard X to the cluster". Scoped to the Artemis cluster.
---

# Skill: Deploy App

Deploy a new application to Artemis-Cluster following the canonical GitOps workflow.

**Before writing any files, read:**

- `.agents/instructions/cluster-conventions.md`
- `.agents/instructions/yaml-conventions.md`
- `.agents/references/flux-patterns.md`
- `.agents/references/networking.md` (if the app needs a route)
- `.agents/references/storage.md` (if the app needs persistence) and `.agents/references/kopiur.md`
  (if it needs backups)
- `.agents/references/postgres-dragonfly.md` — **required reading if the app needs Postgres,
  Redis, or any cache.** The shared CNPG cluster (via `postgres-rw`, password auth, the
  `../../../../components/postgres/app` component and an `APP` substitution) and the shared
  Dragonfly in `database` are the default. Do **not** create a per-app CNPG `Cluster` or a
  sidecar Redis/Valkey — that policy was superseded on 2026-07-02, and `immich` is the only
  remaining dedicated cluster. The reference covers onboarding, the DSN shape, the pgbouncer
  sidecar for cert-incapable clients, and the dedicated-cluster exception.
- `.agents/references/media-stack.md` (if deploying into the `media` namespace)

---

## Step 1 — Gather Requirements

Confirm before proceeding:

- **App name** (e.g. `myapp`)
- **Namespace** — must exist or user confirms creating it
- **Chart**: default is app-template v5. Ask if different.
- **Route**: internal (`internal-gateway`), external (`external-gateway`), edge (`edge-gateway`,
  `*.frostlink.dev` via towonel), or none. An app may attach to more than one.
- **Hostname**: e.g. `myapp.dcunha.io`
- **Persistence**: PVC needed? If yes: size (e.g. `5Gi`) and whether to use kopiur backup
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

| What                   | Where it goes                                |
| ---------------------- | -------------------------------------------- |
| Image repository + tag | Step 3 (image pinning)                       |
| Container port         | `service.app.ports.http.port` in helmrelease |
| Mount paths            | `persistence` block in helmrelease           |
| App-specific env vars  | `containers.app.env` in helmrelease          |
| Secret env var names   | `externalsecret.yaml` template fields        |

Adapt any patterns from the reference to Artemis-Cluster conventions as documented in the kubesearch skill (remove TZ, replace HelmRepository with OCIRepository, replace Ingress with HTTPRoute, remap any MariaDB/Redis/per-app-Postgres deps onto the shared `database` namespace, etc.).

If kubesearch returns no results, fall back to the GitHub search in the kubesearch skill and proceed with what you find.

---

## Step 3 — Pin the Image Tag

Using the image repository identified in Step 2, read `.agents/skills/modules/image-pinning.md` and follow it.

---

## Step 4 — Create Directory Structure

Read `.agents/skills/modules/templates/directory.md` and create the layout.

**If the namespace doesn't exist yet**, create it first:

```
kubernetes/apps/<namespace>/
├── namespace.yaml
└── kustomization.yaml
```

`namespace.yaml` — use `name: _` (kustomize rewrites it from the `namespace:` field):

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
    name: _
    annotations:
        kustomize.toolkit.fluxcd.io/prune: disabled
    labels:
        pod-security.kubernetes.io/audit: privileged
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/warn: privileged
```

`kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <namespace>

components:
    - ../../components/alerts

resources:
    - ./namespace.yaml
    - ./<app>/ks.yaml
```

Flux auto-discovers the new namespace directory — no other wiring needed.

---

## Step 5 — Write Files

Read the relevant template module for each file and write it:

| File                      | Template module                                                               |
| ------------------------- | ----------------------------------------------------------------------------- |
| `ks.yaml`                 | `.agents/skills/modules/templates/ks.md`                                      |
| `app/kustomization.yaml`  | `.agents/skills/modules/templates/kustomization.md`                           |
| `app/ocirepository.yaml`  | `.agents/skills/modules/templates/ocirepository.md`                           |
| `app/helmrelease.yaml`    | `.agents/skills/modules/templates/helmrelease.md`                             |
| `app/externalsecret.yaml` | `.agents/skills/modules/templates/externalsecret.md` (only if secrets needed) |

All YAML must follow `.agents/instructions/yaml-conventions.md`.

---

## Step 6 — Add to Namespace Kustomization

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources.

---

## Step 7 — Verify Files

Confirm all expected files are present:

```bash
find kubernetes/apps/<namespace>/<app> -type f | sort
```

Then validate the kustomization renders cleanly with flate before applying:

```bash
just kube render-local-ks <namespace> <ks-name>
```

This runs `flate build ks` — catches schema errors, missing substitution variables, and malformed YAML before anything touches the cluster. Fix any errors before proceeding to Step 8.

---

## Step 8 — Test and Commit

Read `.agents/skills/modules/test-and-commit.md` and follow it.

If anything fails, read `.agents/skills/modules/common-issues.md` for diagnostics.
