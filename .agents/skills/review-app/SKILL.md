# Skill: Review App Deployment

Audit an existing app's manifests against Artemis-Cluster conventions and report (then optionally fix) any violations.

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

## Step 3 — Run the Checklist

Work through every section below. Mark each item **PASS**, **FAIL**, or **N/A**.

### 3A — Directory Structure

| #   | Check                                                                                   | Result |
| --- | --------------------------------------------------------------------------------------- | ------ |
| S1  | `ks.yaml` exists at `kubernetes/apps/<namespace>/<app>/ks.yaml`                         |        |
| S2  | `app/kustomization.yaml` exists                                                         |        |
| S3  | `app/ocirepository.yaml` exists                                                         |        |
| S4  | `app/helmrelease.yaml` exists                                                           |        |
| S5  | `<app>/ks.yaml` is listed in `kubernetes/apps/<namespace>/kustomization.yaml` resources |        |
| S6  | No standalone `HTTPRoute` files — routes are in helmrelease values                      |        |
| S7  | No `.sops.yaml` or age-encrypted files present                                          |        |

### 3B — ks.yaml

| #   | Check                                                                                                                                                | Result |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| K1  | Schema comment: `# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd/flux2/main/schemas/kustomization_v1.json`                  |        |
| K2  | Field order: `targetNamespace → commonMetadata → path → prune → sourceRef → interval → retryInterval → timeout → dependsOn → components → postBuild` |        |
| K3  | `commonMetadata.labels` includes `app.kubernetes.io/name: <app>`                                                                                     |        |
| K4  | `path: ./kubernetes/apps/<namespace>/<app>/app`                                                                                                      |        |
| K5  | `prune: true`                                                                                                                                        |        |
| K6  | `sourceRef.kind: GitRepository`, `name: flux-system`                                                                                                 |        |
| K7  | `interval: 1h`                                                                                                                                       |        |
| K8  | `dependsOn` includes `rook-ceph-cluster`                                                                                                             |        |
| K9  | If ExternalSecret used: `dependsOn` includes `external-secrets-onepassword`                                                                          |        |
| K10 | If VolSync used: `components` includes `../../../../components/volsync`                                                                              |        |
| K11 | If VolSync used: `postBuild.substitute.VOLSYNC_CAPACITY` is set                                                                                      |        |
| K12 | If cross-namespace `dependsOn` entries: `namespace` field is explicit on each entry                                                                  |        |

### 3C — app/ocirepository.yaml

| #   | Check                                                                                                                                    | Result |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| O1  | Schema comment: `# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd/flux2/main/schemas/ocirepository_v1beta2.json` |        |
| O2  | `apiVersion: source.toolkit.fluxcd.io/v1` (not `v1beta2`)                                                                                |        |
| O3  | `url: oci://ghcr.io/bjw-s-labs/helm/app-template` (`bjw-s-labs`, not `bjw-s`)                                                            |        |
| O4  | `layerSelector.mediaType` and `layerSelector.operation: copy` present                                                                    |        |
| O5  | `ref.tag` is set (not empty)                                                                                                             |        |
| O6  | OCIRepository `name` matches the app name — it is not shared with another app                                                            |        |
| O7  | Metadata field order: `name → namespace → annotations → labels`                                                                          |        |
| O8  | Top-level field order: `apiVersion → kind → metadata → spec`                                                                             |        |

### 3D — app/helmrelease.yaml

**Structure & Schema**

| #   | Check                                                                                                                                                                             | Result |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| H1  | Schema comment: `# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json` |        |
| H2  | `apiVersion: helm.toolkit.fluxcd.io/v2`                                                                                                                                           |        |
| H3  | `chartRef.kind: OCIRepository`, `chartRef.name: <app>` (references own OCIRepository)                                                                                             |        |
| H4  | `interval: 1h`                                                                                                                                                                    |        |
| H5  | `spec` field order: `chartRef → interval → dependsOn → install → upgrade → values`                                                                                                |        |

**spec.values ordering (per sorting-instructions.md)**

| #   | Check                                                                   | Result |
| --- | ----------------------------------------------------------------------- | ------ |
| H6  | `defaultPodOptions` is the first key in `spec.values` (if present)      |        |
| H7  | All other `spec.values` keys are alphabetical after `defaultPodOptions` |        |

**defaultPodOptions**

| #   | Check                                                                   | Result |
| --- | ----------------------------------------------------------------------- | ------ |
| H8  | `defaultPodOptions.securityContext.runAsNonRoot: true`                  |        |
| H9  | `defaultPodOptions.securityContext.runAsUser: 1000`                     |        |
| H10 | `defaultPodOptions.securityContext.runAsGroup: 1000`                    |        |
| H11 | `defaultPodOptions.securityContext.fsGroup: 1000` (if PVC used)         |        |
| H12 | `defaultPodOptions.securityContext.fsGroupChangePolicy: OnRootMismatch` |        |

**Controllers**

| #   | Check                                                                                                             | Result |
| --- | ----------------------------------------------------------------------------------------------------------------- | ------ |
| H13 | Controller has annotation `reloader.stakater.com/auto: "true"`                                                    |        |
| H14 | Controller field order: `type → annotations → labels → <controller-specific> → pod → initContainers → containers` |        |

**Containers**

| #   | Check                                                   | Result |
| --- | ------------------------------------------------------- | ------ |
| H15 | `image` is the first field in every container block     |        |
| H16 | `env.TZ: America/Toronto` is set                        |        |
| H17 | `probes.liveness.enabled` is present                    |        |
| H18 | `probes.readiness.enabled` is present                   |        |
| H19 | `resources.requests` present (`cpu` and `memory`)       |        |
| H20 | `resources.limits.memory` present                       |        |
| H21 | `resources.requests` comes before `resources.limits`    |        |
| H22 | `securityContext.allowPrivilegeEscalation: false`       |        |
| H23 | `securityContext.readOnlyRootFilesystem: true`          |        |
| H24 | `securityContext.capabilities.drop: [ALL]`              |        |
| H25 | Container field order: `image` first, then alphabetical |        |

**Persistence**

| #   | Check                                                                                                      | Result |
| --- | ---------------------------------------------------------------------------------------------------------- | ------ |
| H26 | If VolSync used: `existingClaim: <app>` (not inline PVC spec)                                              |        |
| H27 | If `readOnlyRootFilesystem: true`: a `tmp` emptyDir mount exists                                           |        |
| H28 | Persistence item field order: `type → annotations → labels → <alphabetical> → globalMounts/advancedMounts` |        |

**Service**

| #   | Check                                                                    | Result |
| --- | ------------------------------------------------------------------------ | ------ |
| H29 | Service item field order: `type → annotations → labels → <alphabetical>` |        |

**Route**

| #   | Check                                                                                                      | Result |
| --- | ---------------------------------------------------------------------------------------------------------- | ------ |
| H30 | If route present: `parentRefs` references `internal-gateway` or `external-gateway` in `namespace: network` |        |
| H31 | Route defined under `route.app:` in values — not a standalone file                                         |        |

### 3E — app/externalsecret.yaml (if present)

| #   | Check                                                                  | Result |
| --- | ---------------------------------------------------------------------- | ------ |
| E1  | `apiVersion: external-secrets.io/v1` (not `v1beta1`)                   |        |
| E2  | `secretStoreRef.kind: ClusterSecretStore`, `name: onepassword-connect` |        |
| E3  | `refreshInterval: 1h`                                                  |        |
| E4  | `target.name` matches app name                                         |        |
| E5  | `dataFrom[].extract.key` matches the 1Password item name               |        |
| E6  | Template field names use `{{ .FIELD_NAME }}` syntax                    |        |

### 3F — General YAML Sorting

| #   | Check                                                                       | Result |
| --- | --------------------------------------------------------------------------- | ------ |
| Y1  | Top-level resource order: `apiVersion → kind → metadata → spec` (all files) |        |
| Y2  | `metadata` order: `name → namespace → annotations → labels` (all files)     |        |
| Y3  | `enabled` is the first field in any section that has it                     |        |
| Y4  | YAML inside string values (ConfigMap data) is NOT sorted                    |        |

---

## Step 4 — Report Findings

Output a summary grouped by severity:

```
## Review: <app> (<namespace>)

### FAIL (must fix)
- [H8] defaultPodOptions.securityContext.runAsNonRoot missing
- [K8] dependsOn missing rook-ceph-cluster

### WARN (convention drift, fix preferred)
- [H16] TZ env var not set — expected America/Toronto
- [Y3] enabled not first in probes.liveness block

### PASS
- All structure checks pass
- OCIRepository is standalone and correctly named
- Security context complete
```

If nothing fails: confirm the deployment is convention-compliant and no changes are needed.

---

## Step 5 — Fix Issues (if fix mode enabled)

For each FAIL or WARN, edit the file in place using the exact rules from:

- `.agents/instructions/yaml-conventions.md`
- `.agents/instructions/sorting-instructions.md`
- `.agents/instructions/cluster-conventions.md`

Apply all fixes before showing a diff. Do not change values or behavior — only fix ordering, missing boilerplate, and convention violations.

After fixing, re-read the edited files and confirm no issues remain.

---

## Step 6 — Test & Commit (if fixes were applied)

```bash
# Dry-run validation
PATH="$HOME/.local/share/mise/shims:$PATH" just kube apply-ks <namespace> <namespace>-<app>
kubectl describe helmrelease <app> -n <namespace>
```

Wait for explicit user confirmation before committing.

```bash
git add kubernetes/apps/<namespace>/<app>/
PATH="$HOME/.local/share/mise/shims:$PATH" git commit -m "fix(<namespace>): bring <app> manifests to convention"
```

---

## Common Issues & Gotchas

- **readOnlyRootFilesystem without tmp emptyDir**: app will crash writing to `/tmp` — always pair them
- **OCIRepository url with bjw-s (not bjw-s-labs)**: silently uses wrong registry path
- **source.toolkit.fluxcd.io/v1beta2**: outdated API version; should be `v1`
- **VOLSYNC_CAPACITY in helmrelease**: must be in `ks.yaml` postBuild, not the app's persistence spec
- **dependsOn without namespace field**: cross-namespace deps silently resolve to the local namespace — add `namespace:` explicitly
- **runAsNonRoot: true without matching UID**: app crashes with permission denied — ensure upstream image runs as 1000 or override accordingly
- **externalsecret.io/v1beta1**: outdated; use `external-secrets.io/v1`
