# Task Automation Reference

This directory contains comprehensive documentation for all Taskfile automation in the Artemis Cluster.

## Quick Start

```bash
# List all available tasks
task --list-all

# Bootstrap a new cluster
task bootstrap:talos:genconfig
task bootstrap:talos:apply-all
task bootstrap:talos:bootstrap-etcd
task bootstrap:talos:kubeconfig

# Deploy Flux
task flux:bootstrap

# Validate everything
task validate:all
```

## Documentation by Module

- **[Bootstrap Tasks](bootstrap.md)** - Talos OS lifecycle management
- **[Flux Tasks](flux.md)** - Flux Operator and GitOps automation
- **[Kubernetes Tasks](kubernetes.md)** - kubectl utilities and debugging
- **[Validation Tasks](validation.md)** - SOPS, kustomize, and YAML validation
- **[Git Tasks](git.md)** - Git workflow helpers

## Task Organization

Tasks are organized into logical modules using Taskfile includes:

```yaml
includes:
  bootstrap: .taskfiles/Bootstrap/Taskfile.yaml
  flux: .taskfiles/Flux/Taskfile.yaml
  k8s: .taskfiles/Kubernetes/Taskfile.yaml
  validate: .taskfiles/Validation/Taskfile.yaml
  git: .taskfiles/Git/Taskfile.yaml
```

## Common Workflows

### Fresh Cluster Deployment

```bash
# 1. Generate Talos configs
task bootstrap:talos:genconfig

# 2. Apply to all nodes
task bootstrap:talos:apply-all

# 3. Bootstrap etcd
task bootstrap:talos:bootstrap-etcd

# 4. Get kubeconfig
task bootstrap:talos:kubeconfig

# 5. Bootstrap Flux
task flux:bootstrap

# 6. Wait and verify
task flux:verify
task k8s:pods
```

### Daily Operations

```bash
# Check cluster health
task k8s:nodes
task k8s:pods
task k8s:pods:failing

# Check Flux status
task flux:verify

# Force reconcile
task flux:reconcile:all

# Check Cilium
task k8s:cilium:status
task k8s:cilium:bgp
```

### Troubleshooting

```bash
# Check recent events
task k8s:events

# Debug networking
task k8s:cilium:status
task k8s:debug:dns

# Check gateway status
task k8s:gateway:status

# Validate configuration
task validate:all
```

## Variables

Key variables defined in root `taskfile.yaml`:

| Variable | Value | Description |
|----------|-------|-------------|
| `CONTROLPLANE_IPS` | `10.10.99.101-103` | Control plane node IPs |
| `WORKER_IPS` | `10.10.99.201-202` | Worker node IPs |
| `TALOS_VIP` | `10.10.99.99` | Talos API VIP |
| `CLUSTER_DIR` | `kubernetes/main` | Main cluster directory |
| `FLUX_SECRETS` | `kubernetes/main/bootstrap/flux/secrets` | SOPS encrypted secrets |