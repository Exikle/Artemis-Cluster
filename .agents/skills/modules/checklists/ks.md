# Checklist: ks.yaml

Mark each item **PASS**, **FAIL**, or **N/A**.

Authoritative spec field order: `targetNamespace → commonMetadata → path → prune → sourceRef → interval → retryInterval → timeout → dependsOn → components → postBuild → wait → healthChecks`

| #   | Check                                                                                                                                                                                                                   | Result |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| K1  | Schema comment present: `# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json`                                                                     |        |
| K2  | `spec` fields follow canonical order: `targetNamespace → commonMetadata → path → prune → sourceRef → interval → [retryInterval → timeout →] [dependsOn →] [components →] [postBuild →] [wait] [→ healthChecks]`         |        |
| K3  | `commonMetadata.labels` includes `app.kubernetes.io/name: <app>`                                                                                                                                                        |        |
| K4  | `path: ./kubernetes/apps/<namespace>/<app>/app`                                                                                                                                                                         |        |
| K5  | `prune: true` (or intentionally `false` with a documented reason, e.g. rook-ceph-operator)                                                                                                                              |        |
| K6  | `sourceRef.kind: OCIRepository`, `name: flux-system`, `namespace: flux-system` — **`GitRepository` is WRONG**, the flux source is OCI and a GitRepository ref fails with `source not found`                             |        |
| K7  | `interval: 1h` (or `30m` for kube-system bootstrap apps)                                                                                                                                                                |        |
| K8  | `dependsOn` includes `rook-ceph-cluster` (namespace: `rook-ceph`) when app uses Ceph storage                                                                                                                            |        |
| K9  | If ExternalSecret used: `dependsOn` includes `onepassword-connect` (namespace: `external-secrets`)                                                                                                                      |        |
| K10 | If kopiur used: `components` includes `../../../../components/kopiur/backup`                                                                                                                                            |        |
| K11 | If kopiur used: `postBuild.substitute.KOPIUR_CAPACITY` is set                                                                                                                                                           |        |
| K12 | Every cross-namespace `dependsOn` entry has an explicit `namespace:` field                                                                                                                                              |        |
| K13 | If the app idles (web UI, no background work): consider `../../../../components/zeroscaler` — 11 apps use it. N/A for anything that must stay warm                                                                      |        |
| K14 | If the app needs Postgres: `components` includes `../../../../components/postgres/cert` **and** `postBuild.substitute.PG_APP` is set. A per-app CNPG `Cluster` is a FAIL unless justified (see `postgres-dragonfly.md`) |        |
| K15 | Every `components` path uses exactly four `../` — `../../../` is outside the kustomize root                                                                                                                             |        |
