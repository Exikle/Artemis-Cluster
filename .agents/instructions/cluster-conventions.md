# Cluster Conventions — Artemis-Cluster

## App Directory Structure (canonical)

```
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

## Gateways

- `internal-gateway` (namespace `network`) = LAN only, resolves via UCG-Max DNS
- `external-gateway` (namespace `network`) = Cloudflare tunnel, public internet
- Always use `<app>.<namespace>.svc.cluster.local` for pod-to-pod — never external hostnames

## VolSync

- Referenced in `ks.yaml` components: `../../../../components/volsync`
- PVC size: set in `ks.yaml` postBuild substitute `VOLSYNC_CAPACITY` — not in app manifests
- `moverSecurityContext.fsGroupChangePolicy: OnRootMismatch` — prevents kubelet rechowning all files on every backup
- `moverAffinity` podAntiAffinity required — prevents all mover pods landing on talos-w-01 causing RBD mount storms
- If wrong ownership after restore: set `fsGroupChangePolicy: Always` on the app pod (not the mover)

## Flux Patterns

- Test live before committing: `just kube apply-ks <ns> <kustomization-name>`
- Stuck HelmRelease: `flux suspend hr <app> -n <ns>` → `kubectl delete secret -n <ns> -l name=<app>,owner=helm` → `flux resume hr <app> -n <ns>`
- `prune: false` on flux-instance Kustomization — never prune Flux itself
- `dependsOn` must list actual runtime dependencies (not just chart sources)
- Force reconcile: `flux reconcile kustomization <name> -n flux-system --with-source`
- Force git sync: `just kube sync-git`

## Rook-Ceph

- `useAllNodes: false` — never change to `useAllNodes: true`
- 3 OSDs total on M710q control plane nodes — do not add without explicit direction
- Storage classes: `ceph-block` (RWO block), `ceph-filesystem` (RWX)
- `pg_autoscaler` hard limit: `mon_max_pg_per_osd=250` — cannot be exceeded by adding pools

## Talos

- Config: `just talos render-config <node>` → `just talos apply-node <node>`
- Extension changes: edit schematic → `just talos gen-schematic-id <schematic>` → update `nodes/<node>.yaml.j2` → `apply-node --mode=reboot`
- tuppr in `system-upgrade` namespace handles automated Kubernetes/Talos upgrades

## RBD CSI Recovery (pods stuck ContainerCreating)

1. Restart CSI plugin: `kubectl delete pod -n rook-ceph -l app=csi-rbdplugin --field-selector spec.nodeName=<node>`
2. Clean stale VolumeAttachments: `kubectl get volumeattachment | grep <node>` → delete
3. If kernel-level: `talosctl reboot -n <ip> --wait`
4. Hard reset: Proxmox `qm reset <vmid>`

## Prometheus WAL Corruption (after crash)

- Never delete individual WAL segments — creates sequential gaps
- Scale down → wipe entire `/prometheus/prometheus-db/wal/` → scale back up

## Useful Just Commands

```bash
just kube apply-ks <ns> <ks>     # apply Kustomization live (test before commit)
just kube sync-git                # force Flux to reconcile from git
just kube sync-hr                 # force-sync all HelmReleases
just kube sync-es                 # force-sync all ExternalSecrets
just kube view-secret <ns> <s>   # decode and view a secret
just kube snapshot                # trigger VolSync manual snapshots
just kube prune-pods              # delete Failed/Pending/Succeeded pods
```

## Common Anti-Patterns

- **Sharing OCIRepository**: Every app needs its own — never reuse
- **HTTPRoute as standalone file**: Goes in helmrelease values unless it's a non-app-template resource
- **SOPS**: Fully removed — do not introduce
- **External hostnames for cluster traffic**: Always svc.cluster.local
- **PVC size in helmrelease**: Belongs in ks.yaml VOLSYNC_CAPACITY
- **git add . / git add -A**: Always stage specific files by name
