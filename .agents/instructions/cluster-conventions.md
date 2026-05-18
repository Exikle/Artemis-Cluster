# Cluster Conventions — Artemis-Cluster

## App Directory Structure (canonical)

```text
kubernetes/apps/<namespace>/<app>/
├── ks.yaml                  # Flux Kustomization — dependsOn, VolSync component, PVC size
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml   # standalone OCIRepository — every app gets its own
    ├── helmrelease.yaml     # HTTPRoutes defined in values here, not separate files
    └── externalsecret.yaml  # only if secrets needed
```

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources.

## Helm / app-template v5

- Chart: `oci://ghcr.io/bjw-s-labs/helm/app-template` tag `5.0.0` (note: `-labs`, not `-bjw-s`)
- Every app gets its own standalone `OCIRepository` — never share or reuse one
- `chartRef` in HelmRelease: `kind: OCIRepository, name: <app>`
- OCIRepository API version: `source.toolkit.fluxcd.io/v1` (not `v1beta2`)
- Reloader: `reloader.stakater.com/auto: "true"` annotation on controller
- Default security context: `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch`
- Container security: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: {drop: ["ALL"]}`
- Routes: defined inline under `route.app:` in helmrelease values — NOT as standalone HTTPRoute files
- PVC: `existingClaim: <app>` when using VolSync component
- NFS media: `server: 10.10.99.100, path: /mnt/atlas/media` → `/media`

## Secrets

- SOPS is fully removed — never suggest age encryption or `sops --encrypt`
- All secrets: 1Password ExternalSecret with `ClusterSecretStore: onepassword-connect`
- ExternalSecret API version: `external-secrets.io/v1`
- `dataFrom.extract.key: <1password-item-name>` pulls all fields from item
- Template field names must exactly match 1Password field names — mismatch = empty secret, no error

## Deployment Philosophy

**Prefer siloed deployments** — each app owns its own data layer.

| Need                  | Preferred approach                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------- |
| Relational DB         | SQLite if supported (no external dependency); else CNPG component (app-specific PostgreSQL) |
| Redis / queue / cache | Small sidecar Redis or app-specific instance — not cluster-wide Dragonfly                   |
| Multi-component apps  | Split into separate kustomizations (e.g. Immich: database / app / microservices / ml)       |

When evaluating kubesearch results, flag any `dependsOn: dragonfly-cluster` or `dependsOn: mariadb` — these require adaptation to the silo pattern before deploying.

## Common Mistakes — Quick Reference

| Pattern                  | Correct                          | Wrong                                   |
| ------------------------ | -------------------------------- | --------------------------------------- |
| Secret store name        | `onepassword-connect`            | `onepassword`, `1password-connect`      |
| Gateway (internal)       | `internal-gateway`               | `internal`, `envoy-internal`            |
| Gateway (external)       | `external-gateway`               | `external`, `envoy-external`            |
| Gateway namespace        | `network`                        | `default`, `networking`                 |
| OCIRepository API        | `source.toolkit.fluxcd.io/v1`    | `v1beta2`                               |
| ExternalSecret API       | `external-secrets.io/v1`         | `v1beta1`                               |
| Flux Kustomization API   | `kustomize.toolkit.fluxcd.io/v1` | `v1beta2`                               |
| Image tag                | `v1.0.0@sha256:abc...`           | `latest`, bare `v1.0.0`                 |
| Timezone                 | never set `TZ` — k8tz handles it | `TZ: America/Toronto`                   |
| HTTPRoute location       | inline in helmrelease values     | standalone HTTPRoute file               |
| Cluster traffic          | `<app>.<ns>.svc.cluster.local`   | external hostname                       |
| OCIRepository scope      | one per app                      | shared across apps                      |
| Block storage class      | `ceph-block`                     | `rook-ceph-block`, `ceph-block-storage` |
| Filesystem storage class | `ceph-filesystem`                | `cephfs`, `ceph-fs`                     |
| Arr probe path           | `/ping`                          | `/`, `/health`                          |

## Topic References

For deeper patterns, read from `.agents/references/`:

| File               | Contents                                                                     |
| ------------------ | ---------------------------------------------------------------------------- |
| `flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race, anti-patterns |
| `storage.md`       | Rook-Ceph, VolSync, NFS, RBD CSI recovery, Prometheus WAL                    |
| `networking.md`    | Gateways, cluster traffic rules, VLANs                                       |
| `observability.md` | Grafana Operator, ServiceMonitor gaps, Rook metrics, kromgo                  |
| `talos.md`         | Node config management, extension changes                                    |
