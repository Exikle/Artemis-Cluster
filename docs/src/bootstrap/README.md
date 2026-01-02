# Cluster Bootstrap Guide

This guide explains how to bootstrap the Artemis Cluster from scratch using the "Rainy Day" method. This process is designed to recover the cluster from a complete failure state or to initialize it for the first time.

The bootstrap process relies on **Talos Linux**, **Just** (command runner), and **Helmfile** to bring up a minimal viable cluster before handing control over to **Flux**.

## Prerequisites

Ensure you have the following tools installed on your local machine:
- `talosctl`: Talos CLI for node management.
- `kubectl`: Kubernetes CLI.
- `just`: Task runner.
- `sops`: Secret operations for decryption.
- `age`: Encryption tool.
- `helmfile`: Declarative Helm chart management.
- `yq`: YAML processor.

## Directory Structure

The bootstrap logic is contained within the `bootstrap/` directory:

\`\`\`text
bootstrap/
├── helmfile.d/
│   ├── 00-crds.yaml          # Installs CRDs (Prometheus, Envoy Gateway, Cert-Manager)
│   ├── 01-apps.yaml          # Installs Critical Apps (Network, Secrets, GitOps)
│   └── templates/
│       └── values.yaml.gotmpl # Template to extract values from existing HelmReleases
├── mod.just                  # Orchestration logic (Talos -> Kube -> Secrets -> Apps)
├── resources.yaml.j2         # Template for injecting secrets (Age Key, Bitwarden Token)
└── secrets/                  # Directory for encrypted bootstrap secrets
    ├── age-key.secret.sops.yaml
    ├── bitwarden-provider.secret.sops.yaml
    └── github.secret.sops.yaml
\`\`\`

---

## Step-by-Step Bootstrap Process

### 1. Configure Talos Nodes
This step applies the Talos configuration to your nodes. It iterates through all nodes defined in your `talosctl` config and applies the configuration insecurely (required for initial bootstrap).

\`\`\`bash
just bootstrap talos
\`\`\`

### 2. Bootstrap Kubernetes API
Initializes the Kubernetes control plane on the controller node. This command will loop until the API server reports "AlreadyExists," ensuring the cluster is ready.

\`\`\`bash
just bootstrap kube
\`\`\`

### 3. Fetch Kubeconfig
Retrieves the admin `kubeconfig` from the cluster and merges it into your local configuration.

\`\`\`bash
just bootstrap kubeconfig
\`\`\`

### 4. Wait for Nodes
Pauses execution until all nodes report as `Ready` (or at least reachable). This prevents race conditions where pods are scheduled on nodes that aren't fully online.

\`\`\`bash
just bootstrap wait
\`\`\`

### 5. Apply Namespaces
Creates the core namespaces defined in your `kubernetes/apps` directory. This is critical because Helmfile releases target specific namespaces (e.g., `kube-system`, `external-secrets`).

\`\`\`bash
just bootstrap namespaces
\`\`\`

### 6. Install CRDs
Installs Custom Resource Definitions (CRDs) for critical components like Prometheus, Envoy Gateway, and Cert-Manager. This ensures that later applications don't fail due to missing resource types.

\`\`\`bash
just bootstrap crds
\`\`\`

### 7. Decrypt & Apply Secrets
This is the most critical step. It performs the following actions on-the-fly **without writing secrets to disk**:
1.  Decrypts the **Age Key** (for Flux).
2.  Decrypts the **Bitwarden Credentials** (Access Token, Project ID, Org ID).
3.  Decrypts the **GitHub Deploy Key** (for Flux SSH access).
4.  Injects these values into `resources.yaml.j2`.
5.  Applies the resulting Secret manifests to the cluster.

\`\`\`bash
just bootstrap resources
\`\`\`

### 8. Install Critical Apps
Installs the "Minimum Viable Cluster" stack using Helmfile:
1.  **Cilium:** Networking and CNI.
2.  **CoreDNS:** Cluster DNS.
3.  **Spegel:** Local container registry cache.
4.  **Cert-Manager:** Certificate management (required for Bitwarden).
5.  **External Secrets:** Connects to Bitwarden to fetch all other secrets.
6.  **Flux:** The GitOps engine.

**Note:** This step includes hooks that wait for CRDs to be ready and applies the Bitwarden `ClusterSecretStore` automatically.

\`\`\`bash
just bootstrap apps
\`\`\`

---

## Full One-Shot Command

If you are confident in your configuration, you can run the entire sequence with the default target:

\`\`\`bash
just bootstrap
\`\`\`

This runs: `talos -> kube -> wait -> namespaces -> crds -> resources -> apps -> kubeconfig`

## Troubleshooting

### "Resource not found" Errors
If you see errors about missing CRDs (e.g., `servicemonitors.monitoring.coreos.com`), ensure `just bootstrap crds` ran successfully.

### Secret Decryption Fails
Ensure you have the correct **Age Private Key** loaded in your local environment or `SOPS_AGE_KEY_FILE` environment variable. The bootstrap script relies on your local ability to decrypt the files in `bootstrap/secrets/`.

### Flux Synchronization Issues
Check the Flux logs if the cluster bootstrap finishes but apps aren't syncing:
\`\`\`bash
kubectl logs -n flux-system -l app=source-controller
kubectl logs -n flux-system -l app=kustomize-controller
\`\`\`
Ensure the `github-deploy-key` secret was correctly applied during the `resources` step.
