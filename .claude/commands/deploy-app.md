Deploy a new application to the Artemis-Cluster following the canonical GitOps workflow.

## Step 1 — Gather requirements

Ask the user for:

- **App name** (e.g. `myapp`)
- **Namespace** (e.g. `media`, `cortex`, `home-automation`) — must already exist or user confirms creating it
- **Chart**: default is `app-template` v5 (`oci://ghcr.io/bjw-s-labs/helm/app-template`, tag `5.0.0`). Ask if different.
- **Image**: repository + tag
- **Port**: the container's HTTP port
- **Route**: internal (LAN via `internal-gateway`) or external (Cloudflare via `external-gateway`), or none
- **Hostname**: e.g. `myapp.dcunha.io`
- **Persistence**: does it need a PVC? If yes, ask for size (e.g. `5Gi`) and whether to use VolSync backup
- **Secrets**: does it need a 1Password ExternalSecret? If yes, ask for the 1Password item name

## Step 2 — Create the directory structure

```
kubernetes/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    ├── helmrelease.yaml
    └── externalsecret.yaml   (only if secrets needed)
```

## Step 3 — Write the files using these exact templates

### ks.yaml

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd/flux2/main/schemas/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: <namespace>-<app>
    namespace: flux-system
spec:
    targetNamespace: <namespace>
    commonMetadata:
        labels:
            app.kubernetes.io/name: <app>
    path: ./kubernetes/apps/<namespace>/<app>/app
    prune: true
    sourceRef:
        kind: GitRepository
        name: flux-system
    interval: 1h
    retryInterval: 2m
    timeout: 5m
    dependsOn:
        - name: rook-ceph-cluster # always
        - name: external-secrets-onepassword # if using ExternalSecret
        - name: volsync # if using VolSync — remove if not
    # Only include postBuild if using VolSync:
    postBuild:
        substitute:
            VOLSYNC_CAPACITY: 5Gi
```

### app/ocirepository.yaml

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd/flux2/main/schemas/ocirepository_v1beta2.json
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

### app/helmrelease.yaml (app-template v5 pattern)

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
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
        controllers:
            <app>:
                annotations:
                    reloader.stakater.com/auto: "true"
                containers:
                    app:
                        image:
                            repository: <image-repo>
                            tag: <image-tag>
                        env:
                            TZ: America/Toronto
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
                            readOnlyRootFilesystem: true
                            capabilities:
                                drop:
                                    - ALL
        defaultPodOptions:
            securityContext:
                runAsNonRoot: true
                runAsUser: 1000
                runAsGroup: 1000
                fsGroupChangePolicy: OnRootMismatch
        service:
            app:
                ports:
                    http:
                        port: &port <port>
        route:
            app:
                hostnames:
                    - "<hostname>"
                parentRefs:
                    - name: internal-gateway # or external-gateway
                      namespace: network
        # Only include if PVC needed:
        persistence:
            data:
                existingClaim: <app> # when using VolSync component
                globalMounts:
                    - path: /data
            tmp:
                type: emptyDir
                globalMounts:
                    - path: /tmp
```

### app/externalsecret.yaml (only if secrets needed)

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
    name: <app>
spec:
    secretStoreRef:
        kind: ClusterSecretStore
        name: onepassword-connect
    target:
        name: <app>
        template:
            data:
                SOME_KEY: "{{ .FIELD_NAME }}"
    dataFrom:
        - extract:
              key: <1password-item-name>
    refreshInterval: 1h
```

## Step 4 — Add to namespace kustomization

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources list.

## Step 5 — Test live before committing

```bash
PATH="$HOME/.local/share/mise/shims:$PATH" just kube apply-ks <namespace> <namespace>-<app>
```

Watch for errors. Check pod status:

```bash
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl describe helmrelease <app> -n <namespace>
```

Wait for user to confirm the app is running correctly before proceeding.

## Step 6 — Commit and push

Only after user confirms live deployment works:

```bash
git add kubernetes/apps/<namespace>/<app>/ kubernetes/apps/<namespace>/kustomization.yaml
git commit -m "feat(<namespace>): deploy <app>"
git push origin main
PATH="$HOME/.local/share/mise/shims:$PATH" just kube sync-git
```

## Common issues

- **Pod won't start (permission denied)**: try `runAsNonRoot: false` temporarily to identify the required UID, then set correctly
- **readOnlyRootFilesystem errors**: add `emptyDir` mounts for any paths the app writes to (logs, tmp, cache)
- **Image pull errors**: verify repository URL and tag exist; check if private registry needs imagePullSecret
- **ExternalSecret not syncing**: verify 1Password field names match exactly what's in the template; run `just kube sync-es`
- **HelmRelease stuck**: `flux suspend hr <app> -n <namespace>` → delete helm secrets → `flux resume hr <app> -n <namespace>`
