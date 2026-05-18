# Skill: Deploy App

Deploy a new application to Artemis-Cluster following the canonical GitOps workflow.

## Step 1 — Gather Requirements

Confirm before proceeding:

- **App name** (e.g. `myapp`)
- **Namespace** — must exist or user confirms creating it
- **Chart**: default is app-template v5. Ask if different.
- **Image**: repository + tag
- **Port**: container's HTTP port
- **Route**: internal (`internal-gateway`) or external (`external-gateway`), or none
- **Hostname**: e.g. `myapp.dcunha.io`
- **Persistence**: PVC needed? If yes: size (e.g. `5Gi`) and whether to use VolSync backup
- **Secrets**: 1Password ExternalSecret needed? If yes: 1Password item name

## Step 2 — Read Conventions and Existing Patterns

Read the relevant reference files before writing anything:

- `.agents/instructions/cluster-conventions.md` — app structure, app-template v5, secrets pattern
- `.agents/references/flux-patterns.md` — `dependsOn`, `sourceRef`, cross-namespace rules
- `.agents/references/networking.md` — gateway names, route syntax

Then read 1-2 existing apps in the same namespace to match local patterns:

```bash
ls kubernetes/apps/<namespace>/
cat kubernetes/apps/<namespace>/<existing-app>/ks.yaml
cat kubernetes/apps/<namespace>/<existing-app>/app/helmrelease.yaml
```

## Step 3 — Create Directory Structure

```
kubernetes/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    ├── helmrelease.yaml
    └── externalsecret.yaml   (only if secrets needed)
```

## Step 4 — Write Files

> All YAML must follow the field ordering rules in `.agents/instructions/sorting-instructions.md`. Key points for app-template HelmReleases: `defaultPodOptions` before all other `spec.values` keys; remaining `spec.values` keys alphabetical; `enabled` always first within its block; `image` always first within a container block; `resources` before `securityContext` in containers.

### ks.yaml

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: <app>
spec:
    commonMetadata:
        labels:
            app.kubernetes.io/name: <app>
    dependsOn:
        - name: rook-ceph-cluster # always
        - name: external-secrets-onepassword # if using ExternalSecret
        - name: volsync # remove if not using VolSync
    interval: 1h
    path: ./kubernetes/apps/<namespace>/<app>/app
    postBuild: # only if using VolSync
        substitute:
            VOLSYNC_CAPACITY: 5Gi
    prune: true
    sourceRef:
        kind: GitRepository
        name: flux-system
    targetNamespace: <namespace>
```

### app/ocirepository.yaml

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
    name: <app>
spec:
    interval: 1h
    layerSelector:
        mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
        operation: copy
    ref:
        tag: 5.0.0
    url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

### app/kustomization.yaml

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
    - ./ocirepository.yaml
    - ./helmrelease.yaml
    # - ./externalsecret.yaml  # uncomment if using secrets
```

### app/helmrelease.yaml

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
    name: <app>
spec:
    chartRef:
        kind: OCIRepository
        name: <app>
    interval: 1h
    values:
        defaultPodOptions:
            securityContext:
                fsGroup: 1000
                fsGroupChangePolicy: OnRootMismatch
                runAsGroup: 1000
                runAsNonRoot: true
                runAsUser: 1000
        controllers:
            <app>:
                annotations:
                    reloader.stakater.com/auto: "true"
                containers:
                    app:
                        image:
                            repository: <image-repo>
                            tag: <image-tag>
                        probes:
                            liveness:
                                enabled: true
                            readiness:
                                enabled: true
                            startup:
                                enabled: false
                        resources:
                            requests:
                                cpu: 10m
                                memory: 128Mi
                            limits:
                                memory: 512Mi
                        securityContext:
                            allowPrivilegeEscalation: false
                            capabilities:
                                drop:
                                    - ALL
                            readOnlyRootFilesystem: true
        persistence: # only if PVC needed
            data:
                existingClaim: <app>
                globalMounts:
                    - path: /data
            tmp:
                globalMounts:
                    - path: /tmp
                type: emptyDir
        route:
            app:
                hostnames:
                    - "<hostname>"
                parentRefs:
                    - name: internal-gateway # or external-gateway
                      namespace: network
        service:
            app:
                ports:
                    http:
                        port: <port>
```

### app/externalsecret.yaml (only if secrets needed)

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
    name: <app>
spec:
    dataFrom:
        - extract:
              key: <1password-item-name>
    refreshInterval: 1h
    secretStoreRef:
        kind: ClusterSecretStore
        name: onepassword-connect
    target:
        name: <app>
        template:
            data:
                SOME_KEY: "{{ .FIELD_NAME }}"
```

## Step 5 — Add to Namespace Kustomization

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources list.

## Step 6 — Verify Files

```bash
find kubernetes/apps/<namespace>/<app> -type f
```

Confirm all expected files are present before proceeding.

## Step 7 — Test Live

```bash
just kube apply-ks <namespace> <namespace>-<app>
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl describe helmrelease <app> -n <namespace>
```

Wait for explicit user confirmation before committing.

## Step 8 — Commit

Only after user confirms:

```bash
git add kubernetes/apps/<namespace>/<app>/ kubernetes/apps/<namespace>/kustomization.yaml
git commit -m "feat(<namespace>): deploy <app>"
git push origin main
just kube sync-git
```

## Common Issues

- **Permission denied**: try `runAsNonRoot: false` temporarily to identify required UID
- **readOnlyRootFilesystem errors**: add `emptyDir` mounts for any paths the app writes to
- **ExternalSecret not syncing**: verify 1Password field names match exactly; run `just kube sync-es`
- **HelmRelease stuck**: `flux suspend hr <app> -n <ns>` → delete helm secrets → `flux resume hr <app> -n <ns>`
