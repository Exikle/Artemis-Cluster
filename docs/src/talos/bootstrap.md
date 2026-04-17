# Bootstrap

Full procedure to bring up the cluster from scratch. Run `just` from the repo root — the bootstrap `mod.just` orchestrates all stages.

---

## Prerequisites

- All 6 nodes booted into Talos maintenance mode (USB or netboot)
- `talosctl`, `kubectl`, `helm`, `helmfile`, `op` (1Password CLI) all installed and in PATH
- Active 1Password session (`op signin`)
- Talosconfig pointed at the control plane nodes

---

## Stage Overview

The default bootstrap target runs all stages in order:

```
just           (runs bootstrap/mod.just default)
  talos        → apply Talos config to all nodes
  kube         → bootstrap Kubernetes (etcd init)
  kubeconfig   → fetch kubeconfig via node IP
  wait         → wait for nodes to become not-ready (CNI not installed yet)
  namespaces   → create all app namespaces from kubernetes/apps/
  resources    → apply bootstrap secrets (1Password Connect, Cloudflare Tunnel ID)
  crds         → apply CRDs via helmfile (00-crds.yaml)
  apps         → install bootstrap apps via helmfile (01-apps.yaml)
  kubeconfig   → re-fetch kubeconfig now using Cilium LB
```

You can run any stage individually:

```bash
just bootstrap talos
just bootstrap kube
just bootstrap apps
# etc.
```

---

## Stage Details

### `talos` — Apply Talos Config

Iterates all nodes from `talosctl config info` and applies the rendered config. Skips nodes that are already configured (detects "certificate required" error).

```bash
just bootstrap talos
# or apply a single node
just talos apply-node talos-cp-01 --insecure
```

> Use `--insecure` for nodes that have never been configured (no client cert yet).

---

### `kube` — Bootstrap Kubernetes

Runs `talosctl bootstrap` on the first control plane. Retries until etcd reports `AlreadyExists` (idempotent).

```bash
just bootstrap kube
```

---

### `kubeconfig` — Fetch Kubeconfig

Fetches kubeconfig from the control plane and saves it to the repo root. Run twice — once early (using node IP) and once after Cilium is running (using LB VIP).

```bash
just bootstrap kubeconfig
```

---

### `namespaces` — Create Namespaces

Extracts `Namespace` resources from each app directory's kustomization and applies them with `--server-side`. This ensures namespaces exist before Flux tries to deploy into them.

---

### `resources` — Bootstrap Secrets

Renders `bootstrap/resources.yaml.j2` via the `op` CLI to resolve `op://` references and applies the result. This creates:

- `onepassword-connect-credentials-secret` in `external-secrets` (1Password Connect JSON credentials)
- `onepassword-connect-vault-secret` in `external-secrets` (Connect API token)
- `cloudflare-tunnel-id-secret` in `network` (Cloudflare Tunnel ID)

These secrets must exist before the helmfile apps can start.

---

### `crds` — Install CRDs

Applies CRDs from `bootstrap/helmfile.d/00-crds.yaml` using `helmfile template | kubectl apply`. This pre-installs CRDs for:

- `cloudflare-dns` (ExternalDNS)
- `envoy-gateway`
- `grafana-operator`
- `keda`
- `kube-prometheus-stack`

---

### `apps` — Install Bootstrap Apps

Runs `helmfile sync` on `bootstrap/helmfile.d/01-apps.yaml`. Install order (respecting `needs:` dependencies):

```
cilium
  → coredns
    → spegel
      → cert-manager
        → external-secrets
          → onepassword-connect  (+ ClusterSecretStore)
            → flux-operator
              → flux-instance    (starts Flux GitOps sync)
```

Once `flux-instance` is installed, Flux takes over and reconciles `kubernetes/apps/`.

---

## Post-Bootstrap Verification

```bash
# Nodes ready
kubectl get nodes -o wide

# All system pods running
kubectl get pods -n kube-system
kubectl get pods -n flux-system

# Flux reconciling
flux get kustomizations

# Cilium healthy
kubectl -n kube-system exec ds/cilium -- cilium status --brief

# BGP peers established
kubectl -n kube-system exec ds/cilium -- cilium bgp peers
```

---

## API Server Endpoint

The Kubernetes API server is accessed via:

- **VIP:** `https://10.10.99.99:6443` (L2 via Cilium, active once Cilium is running)
- **DNS:** `https://artemis.dcunha.io:6443` (resolves to 10.10.99.99 via split-horizon)
- **KubePrism (local proxy):** `127.0.0.1:7445` on each node (used by Cilium internally)

certSANs include `127.0.0.1`, `10.10.99.99`, and `artemis.dcunha.io`.
