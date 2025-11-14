# Flux Tasks

Tasks for managing Flux Operator, GitOps synchronization, and cluster state reconciliation.

**Module:** `flux` (`.taskfiles/Flux/Taskfile.yaml`)

---

## Complete Bootstrap

### `flux:bootstrap`

Run complete Flux Operator bootstrap pipeline.

**Usage:**
```bash
task flux:bootstrap
```

**What it does:**
1. Installs Flux Operator
2. Applies SOPS encrypted secrets
3. Deploys FluxInstance CR
4. Verifies installation

**Time:** ~2-3 minutes

**Equivalent to:**
```bash
task flux:install-operator
task flux:apply-secrets
task flux:apply-instance
task flux:verify
```

---

## Installation Steps

### `flux:install-operator`

Deploy Flux Operator (CRDs + controller).

**Usage:**
```bash
task flux:install-operator
```

**What it does:**
1. Applies `flux-operator.yaml` to cluster
2. Waits for operator deployment to be available (5min timeout)
3. Creates `flux-system` namespace
4. Installs FluxInstance CRD

**Files applied:**
- `kubernetes/main/bootstrap/flux/flux-operator.yaml`

**Verification:**
```bash
kubectl get deployment flux-operator -n flux-system
# Should show 1/1 READY
```

---

### `flux:apply-secrets`

Decrypt and apply all SOPS encrypted secrets.

**Usage:**
```bash
task flux:apply-secrets
```

**What it does:**
1. Decrypts `age-key.secret.sops.yaml` (SOPS decryption key)
2. Decrypts `github-deploy-key.secret.sops.yaml` (GitHub SSH key)
3. Optionally decrypts `cluster-secrets.secret.sops.yaml` (cluster vars)
4. Applies all to `flux-system` namespace

**Files:**
- `age-key.secret.sops.yaml` → `sops-age` secret
- `github-deploy-key.secret.sops.yaml` → `flux-system` secret
- `cluster-secrets.secret.sops.yaml` → `cluster-secrets` secret (optional)

---

### `flux:apply-instance`

Apply FluxInstance CR to start GitOps.

**Usage:**
```bash
task flux:apply-instance
```

**What it does:**
1. Applies `flux-instance.yaml`
2. Flux Operator deploys all Flux controllers
3. GitRepository sync begins

**Controllers deployed:**
- source-controller
- kustomize-controller
- helm-controller
- notification-controller
- image-reflector-controller
- image-automation-controller

---

### `flux:verify`

Verify Flux installation and show status.

**Usage:**
```bash
task flux:verify
```

**What it shows:**
1. FluxInstance status
2. Flux controller deployments
3. Flux controller pods
4. GitRepository sync status
5. All Kustomizations

---

## Reconciliation

### `flux:reconcile:all`

Force reconcile all layers.

**Usage:**
```bash
task flux:reconcile:all
```

### `flux:reconcile:infra`

Force reconcile infrastructure layer only.

**Usage:**
```bash
task flux:reconcile:infra
```

**Reconciles:**
- Cilium CNI
- Cilium BGP config
- Cilium Gateway API
- CoreDNS
- Democratic CSI

### `flux:reconcile:platform`

Force reconcile platform layer only.

**Usage:**
```bash
task flux:reconcile:platform
```

**Reconciles:**
- cert-manager
- external-dns
- external-secrets
- Security tools
- Observability stack
- Operators

### `flux:reconcile:apps`

Force reconcile apps layer only.

**Usage:**
```bash
task flux:reconcile:apps
```

---

## Common Workflows

### Initial Flux Deployment

```bash
# After Talos bootstrap
task bootstrap:talos:kubeconfig

# Bootstrap Flux
task flux:bootstrap

# Monitor deployment
watch kubectl get pods -n flux-system

# Verify everything is synced
task flux:verify
```

### Push Changes and Sync

```bash
# Make changes to manifests
vim kubernetes/main/platform/cert-manager/app/helmrelease.yaml

# Commit and push
git add .
git commit -m "feat: update cert-manager"
git push

# Force Flux to sync immediately
task flux:reconcile:platform

# Watch for changes
watch kubectl get pods -n cert-manager
```

---

## Troubleshooting

### GitRepository not syncing

```bash
# Check GitRepository status
kubectl get gitrepository -n flux-system flux-system

# Check for auth errors
kubectl describe gitrepository flux-system -n flux-system

# Test SSH manually
kubectl run -it --rm debug --image=alpine/git --restart=Never -- \
  sh -c "ssh -T git@github.com"
```

### Kustomization stuck

```bash
# Get error message
kubectl describe kustomization <name> -n flux-system

# Force reconcile
flux reconcile kustomization <name> -n flux-system

# Suspend and resume (nuclear option)
flux suspend kustomization <name> -n flux-system
flux resume kustomization <name> -n flux-system
```

---

## Variables Used

| Variable | Value | Description |
|----------|-------|-------------|
| `FLUX_BOOTSTRAP` | `kubernetes/main/bootstrap/flux` | Flux bootstrap directory |
| `FLUX_SECRETS` | `kubernetes/main/bootstrap/flux/secrets` | SOPS encrypted secrets |

---

## Related Documentation

- [Flux Operator Documentation](https://fluxcd.control-plane.io/operator/)
- [Flux CD Documentation](https://fluxcd.io/)
- [Bootstrap Documentation](bootstrap.md)
- [Validation Tasks](validation.md)