# Module: ks.yaml Template

Spec field order is in `.agents/instructions/yaml-conventions.md` § ks.yaml.

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
        kind: OCIRepository
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

## With kopiur backup (add components + postBuild)

```yaml
components:
    - ../../../../components/kopiur/backup
postBuild:
    substitute:
        APP: *app
        KOPIUR_CAPACITY: 5Gi
```

## With scale-to-zero (add to components)

```yaml
components:
    - ../../../../components/zeroscaler
```

## With shared Postgres (add components + postBuild)

```yaml
components:
    - ../../../../components/postgres/app
postBuild:
    substitute:
        APP: *app
```

## Full example (storage + secrets + kopiur)

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
        kind: OCIRepository
        name: flux-system
        namespace: flux-system
    interval: 1h
    dependsOn:
        - name: onepassword-connect
          namespace: external-secrets
    components:
        - ../../../../components/kopiur/backup
    postBuild:
        substitute:
            APP: *app
            KOPIUR_CAPACITY: 5Gi
    wait: true
```

## Components

`ls kubernetes/components` lists them. Each component's substitutions are the `${...}` references in
its own files (`grep -rho '\${[A-Z_]*' kubernetes/components/<name>`), and
`grep -rln 'components/<name>' kubernetes/apps/` shows who uses it, with a working example.
`kopiur/backup` renders a PVC, `Restore`, `SnapshotPolicy` and `SnapshotSchedule`.
`envoy-oidc` needs `pocket-id-operator` in `dependsOn` and an `oidcclient.yaml` (see `add-oidc-app`).

All paths sit four `../` from `kubernetes/apps/<ns>/<app>/` — counting wrong is the most common
failure here (`../../../` resolves outside the kustomize root and the build errors). Components
stack.

## Notes

- YAML blocks in these templates render at 4-space indent; real manifests are 2-space. Copy the
  structure, not the indentation (`yaml-conventions.md` § What the tooling does for you).
- Use YAML anchor `&app` on `metadata.name` and alias `*app` everywhere the app name repeats
  (labels, postBuild).
- Always include `namespace:` on every cross-namespace `dependsOn` entry — omitting it silently
  resolves to the local namespace.
- `retryInterval` and `timeout` are optional — add only when the app is known to be slow to
  reconcile.
- `healthChecks` goes last, after `wait`. Only a handful of apps need it — a CRD-bearing operator
  whose dependents must not start until a named object exists.
