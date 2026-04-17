# Upgrades (tuppr)

[tuppr](https://github.com/siderolabs/tuppr) automates Talos and Kubernetes upgrades via GitOps. It is deployed in the `system-upgrade` namespace and managed by Flux.

---

## How It Works

tuppr watches `TalosUpgrade` and `KubernetesUpgrade` CRDs. When Renovate bumps the version in those resources and Flux reconciles, tuppr performs the upgrade automatically — draining nodes, upgrading, and continuing without manual intervention.

Renovate picks up new versions via `# renovate:` annotations on the CRDs.

---

## Current Versions

Managed in `kubernetes/apps/system-upgrade/tuppr/upgrades/`:

| Resource     | Kind              | Current Version |
| ------------ | ----------------- | --------------- |
| `talos`      | TalosUpgrade      | v1.12.6         |
| `kubernetes` | KubernetesUpgrade | v1.35.4         |

---

## TalosUpgrade

The `TalosUpgrade` resource specifies the installer image per node schematic. Workers and GPU nodes use a different schematic hash than control planes (different extensions).

Renovate manages the version via a `datasource=docker` annotation pointing to `ghcr.io/siderolabs/installer`.

Before upgrading Talos, verify the schematic IDs are still valid:

```bash
just talos gen-schematic-id controlplane
just talos gen-schematic-id worker
just talos gen-schematic-id gpu
```

If the schematic hashes change (e.g. after adding extensions), update the node `.yaml.j2` files and re-apply before triggering a tuppr upgrade.

---

## KubernetesUpgrade

The `KubernetesUpgrade` resource specifies the target Kubernetes version. tuppr runs `talosctl upgrade-k8s` internally.

---

## Manual Upgrade (without tuppr)

If you need to upgrade outside of tuppr:

```bash
# Upgrade Talos on a single node
just talos upgrade-node talos-cp-01

# Upgrade Kubernetes
just talos upgrade-k8s v1.36.0
```

`upgrade-node` reads the install image from the node's `.yaml.j2` file automatically.

---

## Prometheus Alerts

tuppr ships PrometheusRules for upgrade job status:

- `tuppr.talosupgrade` — TalosUpgrade job failures
- `tuppr.kubernetesupgrade` — KubernetesUpgrade job failures
- `tuppr.jobs` — generic job failure alert

---

## KubernetesTalosAPIAccess

The `system-upgrade` namespace is granted `os:admin` access to the Talos API via `kubernetesTalosAPIAccess` on all control plane nodes. This allows tuppr to call `talosctl` against nodes from within the cluster.
