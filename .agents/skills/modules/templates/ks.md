# Module: ks.yaml Template

Spec field order: `targetNamespace → commonMetadata → path → prune → sourceRef → interval →
retryInterval → timeout → dependsOn → components → postBuild → wait → healthChecks`

Canonical order lives in `.agents/instructions/yaml-conventions.md` § ks.yaml — this is a copy
for convenience; that file wins on any disagreement.

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

## With Rook-Ceph storage (add to dependsOn)

```yaml
dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph
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
        - name: rook-ceph-cluster
          namespace: rook-ceph
    components:
        - ../../../../components/kopiur/backup
    postBuild:
        substitute:
            APP: *app
            KOPIUR_CAPACITY: 5Gi
    wait: true
```

## Live components — what an app can actually pull in

| Component path                         | What it does                                                | `postBuild.substitute`                                                                                         |
| -------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `../../../../components/kopiur/backup` | kopiur `Snapshot` + `SnapshotPolicy` + the app PVC          | `APP`, `KOPIUR_CAPACITY` (defaults `5Gi`); `KOPIUR_PUID`/`KOPIUR_PGID` (both default `1000`)                   |
| `../../../../components/zeroscaler`    | HPA `minReplicas: 0`, scaled by an external `probe_success` | `APP`; optional `CONTROLLER` (`Deployment`), `ZEROSCALER_METRIC_NAME`, `ZEROSCALER_JOB_NAME`                   |
| `../../../../components/postgres/app`  | password-auth onboarding onto the shared CNPG cluster       | `APP` (`PG_APP` only if the db name differs)                                                                   |
| `../../../../components/anubis`        | PoW scraper deterrence in front of a route                  | `APP`, `ANUBIS_TARGET`; optional `HTTP_ROUTE_TARGET`                                                           |
| `../../../../components/tinyauth`      | tinyauth `ext_authz` `SecurityPolicy` on a route            | `APP`; optional `HTTP_ROUTE_TARGET` (defaults to `${APP}` — set it when the HTTPRoute's name is not the app's) |

Who currently uses each is deliberately not listed — `grep -rln 'components/<name>' kubernetes/apps/`
answers it and is never stale.

They all sit at four `../` from `kubernetes/apps/<ns>/<app>/` — counting wrong is the most
common failure here (`../../../` resolves outside the kustomize root and the build errors).
Components stack — an app may carry several in one list (`media/bazarr` carries zeroscaler,
kopiur and tinyauth together).

## Notes

- **The YAML blocks above render at 4-space indent — real manifests are 2-space.** Do not copy
  the indentation. oxfmt (lefthook pre-commit, `printWidth 100`) reformats YAML inside markdown
  code fences to its own 4-space style and will undo any attempt to fix it here, while
  `.editorconfig` sets `indent_size = 2` for `*.yaml` under `kubernetes/`. Copy the structure,
  re-indent to 2.
- Use YAML anchor `&app` on `metadata.name` and alias `*app` everywhere the app name repeats
  (labels, postBuild).
- Always include `namespace:` on every cross-namespace `dependsOn` entry — omitting it silently
  resolves to the local namespace.
- `rook-ceph-cluster` dep is required whenever the app uses a PVC backed by Ceph (block or
  filesystem).
- `retryInterval` and `timeout` are optional — add only when the app is known to be slow to
  reconcile.
- `healthChecks` goes last, after `wait`. Only a handful of apps need it — a CRD-bearing operator
  whose dependents must not start until a named object exists.
