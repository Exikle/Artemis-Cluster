# Adding an App

Most apps use the [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) Helm chart. This is the standard pattern for adding a new app to the cluster.

---

## Directory Structure

```
kubernetes/apps/<namespace>/<app-name>/
├── ks.yaml          # Flux Kustomization
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    ├── externalsecret.yaml   # (if secrets needed)
    └── httproute.yaml        # (if ingress needed)
```

---

## Step 1: Create the Flux Kustomization (`ks.yaml`)

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: &app my-app
    namespace: flux-system
spec:
    targetNamespace: my-namespace
    commonMetadata:
        labels:
            app.kubernetes.io/name: *app
    path: ./kubernetes/apps/my-namespace/my-app/app
    prune: true
    sourceRef:
        kind: GitRepository
        name: flux-system
    dependsOn:
        - name: external-secrets-stores # if using ExternalSecrets
        - name: rook-ceph-cluster # if using Ceph PVCs
        - name: volsync # if using VolSync backups
```

---

## Step 2: Add to Namespace Kustomization

Add the app to `kubernetes/apps/<namespace>/kustomization.yaml`:

```yaml
resources:
    - ./existing-app
    - ./my-app # add this line
```

---

## Step 3: Create the HelmRelease (`app/helmrelease.yaml`)

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
    name: my-app
spec:
    interval: 1h
    chartRef:
        kind: OCIRepository
        name: app-template
        namespace: flux-system
    values:
        controllers:
            my-app:
                containers:
                    app:
                        image:
                            repository: ghcr.io/example/my-app
                            tag: 1.0.0
                        env:
                            TZ: America/Toronto
        service:
            app:
                ports:
                    http:
                        port: 8080
        persistence:
            data:
                existingClaim: my-app-data
                globalMounts:
                    - path: /data
```

---

## Step 4: Add Secrets (if needed)

```yaml
# app/externalsecret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
    name: my-app
spec:
    refreshInterval: 1h
    secretStoreRef:
        kind: ClusterSecretStore
        name: onepassword-connect
    target:
        name: my-app
        creationPolicy: Owner
    data:
        - secretKey: API_KEY
          remoteRef:
              key: my-app
              property: API_KEY
```

Reference in HelmRelease:

```yaml
containers:
    app:
        envFrom:
            - secretRef:
                  name: my-app
```

---

## Step 5: Add Ingress (if needed)

### Internal only

```yaml
# app/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
    name: my-app
spec:
    parentRefs:
        - name: internal-gateway
          namespace: network
    hostnames:
        - my-app.dcunha.io
    rules:
        - matches:
              - path:
                    type: PathPrefix
                    value: /
          backendRefs:
              - name: my-app
                port: 8080
```

### External (internet-accessible)

Change `internal-gateway` to `external-gateway`.

---

## Step 6: Add VolSync Backup (if PVC needs backup)

Add the volsync component to `app/kustomization.yaml`:

```yaml
components:
    - ../../../components/volsync
```

Create a `ClaimName` annotation and ensure the `ReplicationSource` is configured with the correct PVC name and schedule in a patch.

---

## Step 7: Add Config Map (if needed)

Use a Kustomize ConfigMap generator to bundle config files:

```yaml
# app/kustomization.yaml
configMapGenerator:
    - name: my-app-config
      files:
          - config.yaml
```

Add `reloader.stakater.com/auto: "true"` to the controller annotation to restart pods when the ConfigMap changes.

---

## Conventions

- Use `TZ: America/Toronto` for timezone-sensitive apps
- Use `10.10.99.1` as DNS resolver (UCG-Max), not 8.8.8.8
- Internal cluster routing: `<app>.<namespace>.svc.cluster.local` — never external DNS for pod-to-pod
- Reloader annotation on controllers that need restart on config/secret change
- Prowlarr is the single indexer source — never add indexer keys directly to arr apps
