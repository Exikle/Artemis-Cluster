# Module: ks.yaml Template

Spec field order: `targetNamespace → commonMetadata → path → prune → sourceRef → interval → retryInterval → timeout → dependsOn → components → postBuild → wait`

## Minimal (no persistence, no secrets)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: &app <app>
spec:
    targetNamespace: <namespace>
    commonMetadata:
        labels:
            app.kubernetes.io/name: *app
    path: ./kubernetes/apps/<namespace>/<app>/app
    prune: true
    sourceRef:
        kind: GitRepository
        name: flux-system
        namespace: flux-system
    interval: 1h
    wait: true
```

## With ExternalSecret (add to dependsOn)

```yaml
dependsOn:
    - name: onepassword-connect
      namespace: external-secrets
```

## With Rook-Ceph storage (add to dependsOn)

```yaml
dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph
```

## With VolSync backup (add components + postBuild)

```yaml
  components:
    - ../../../../components/volsync
  postBuild:
    substitute:
      APP: *app
      VOLSYNC_CAPACITY: 5Gi
```

## Full example (storage + secrets + VolSync)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: &app <app>
spec:
    targetNamespace: <namespace>
    commonMetadata:
        labels:
            app.kubernetes.io/name: *app
    path: ./kubernetes/apps/<namespace>/<app>/app
    prune: true
    sourceRef:
        kind: GitRepository
        name: flux-system
        namespace: flux-system
    interval: 1h
    dependsOn:
        - name: onepassword-connect
          namespace: external-secrets
        - name: rook-ceph-cluster
          namespace: rook-ceph
    components:
        - ../../../../components/volsync
    postBuild:
        substitute:
            APP: *app
            VOLSYNC_CAPACITY: 5Gi
    wait: true
```

## Notes

- Use YAML anchor `&app` on `metadata.name` and alias `*app` everywhere the app name repeats (labels, postBuild).
- Always include `namespace:` on every cross-namespace `dependsOn` entry — omitting it silently resolves to the local namespace.
- `rook-ceph-cluster` dep is required whenever the app uses a PVC backed by Ceph (block or filesystem).
- `retryInterval` and `timeout` are optional — add only when the app is known to be slow to reconcile.
