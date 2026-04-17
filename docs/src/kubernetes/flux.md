# Flux & GitOps

The cluster is managed entirely via GitOps using [Flux Operator](https://github.com/controlplaneio-fluxcd/flux-operator) + [FluxInstance](https://fluxcd.io/flux/operator/).

---

## Architecture

```
flux-operator          → manages Flux lifecycle (install, upgrade, health)
  └── flux-instance    → defines sync config (repo, branch, path)
        └── GitRepository (flux-system/flux-system) → github.com/Exikle/Artemis-Cluster
              └── Kustomization (artemis-cluster) → ./kubernetes/apps
                    └── per-namespace Kustomizations → HelmReleases
```

**Sync entrypoint:** `kubernetes/flux/sync/cluster.yaml` — one root Kustomization pointing to `kubernetes/apps`, syncing every hour.

---

## Key Behaviours

All child Kustomizations and HelmReleases inherit these defaults (patched by the root Kustomization):

- **CRD strategy:** `CreateReplace` on install and upgrade
- **Upgrade remediation:** retry 2×, remediate last failure
- **Rollback:** `cleanupOnFail: true`, `recreate: true`
- **Deletion policy:** `WaitForTermination`

The `flux-system` Kustomization has `prune: false` — Flux will never delete itself.

---

## Repo Structure

```
kubernetes/
├── apps/                  # All namespaced app resources
│   ├── <namespace>/
│   │   ├── <app>/
│   │   │   ├── ks.yaml    # Flux Kustomization
│   │   │   └── app/       # HelmRelease, secrets, config
│   │   └── kustomization.yaml
│   └── kustomization.yaml
├── components/            # Shared Kustomize components
│   ├── alerts/            # Alertmanager + GitHub status providers
│   ├── nfs-scaler/        # KEDA ScaledObject for NFS
│   └── volsync/           # VolSync PVC/ReplicationSource templates
└── flux/
    └── sync/
        ├── cluster.yaml   # Root Kustomization
        └── kustomization.yaml
```

---

## Upgrading Flux

Change the version in `flux-operator` or `flux-instance` HelmRelease — the operator handles the rolling update. Renovate manages version bumps automatically.

---

## Flux CLI Quick Reference

```bash
# Check all Kustomizations
flux get kustomizations -A

# Check all HelmReleases
flux get helmreleases -A

# Force reconcile a specific app
flux reconcile kustomization <name> -n flux-system --with-source

# Force reconcile all
flux reconcile source git flux-system

# Suspend a HelmRelease (stop auto-sync)
flux suspend helmrelease <name> -n <namespace>

# Resume
flux resume helmrelease <name> -n <namespace>

# Check events
kubectl get events -n flux-system --sort-by='.lastTimestamp'
```

---

## Self-hosted GitHub Runners (`actions-runner-system`)

The `actions-runner-controller` runs self-hosted GitHub Actions runners in the cluster, used for Renovate automation workflows. Managed by the `runner` HelmRelease in `kubernetes/apps/actions-runner-system/`.
