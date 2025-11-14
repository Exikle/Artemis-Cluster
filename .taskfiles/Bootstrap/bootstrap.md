# Bootstrap Tasks

Tasks for managing Talos OS lifecycle: config generation, node provisioning, etcd bootstrap, and cluster initialization.

**Module:** `bootstrap` (`.taskfiles/Bootstrap/Taskfile.yaml`)

---

## Configuration Generation

### `bootstrap:talos:genconfig`

Generate Talos machine configurations using talhelper.

**Usage:**
```bash
task bootstrap:talos:genconfig
```

**What it does:**
1. Reads `talconfig.yaml` from `kubernetes/main/bootstrap/talos/`
2. Generates machine configs for all nodes
3. Outputs configs to `clusterconfig/` directory

**Output files:**
- `main-control-01.yaml`
- `main-control-02.yaml`
- `main-control-03.yaml`
- `main-worker-01.yaml`
- `main-worker-02.yaml`

**Prerequisites:**
- `talhelper` installed
- `talconfig.yaml` configured with node details

---

## Node Provisioning

### `bootstrap:talos:apply-all`

Apply Talos configuration to ALL nodes (control planes + workers).

**Usage:**
```bash
task bootstrap:talos:apply-all
```

**What it does:**
- Sequentially applies configs to all 5 nodes
- Uses `--insecure` flag for initial bootstrap
- Nodes will reboot and apply configuration

**Order:**
1. control-01 (10.10.99.101)
2. control-02 (10.10.99.102)
3. control-03 (10.10.99.103)
4. worker-01 (10.10.99.201)
5. worker-02 (10.10.99.202)

**Time:** ~5-10 minutes total

---

## Cluster Initialization

### `bootstrap:talos:bootstrap-etcd`

Bootstrap etcd on the first control plane node.

**Usage:**
```bash
task bootstrap:talos:bootstrap-etcd
```

**What it does:**
- Initializes etcd cluster on control-01
- Forms the foundation for Kubernetes cluster
- Only run ONCE per cluster

**Prerequisites:**
- All control plane nodes must have Talos applied
- Nodes must be rebooted and running Talos

**Verification:**
```bash
talosctl health --nodes 10.10.99.101
```

**⚠️ Warning:** Only run this task once! Running it again will break the cluster.

---

### `bootstrap:talos:kubeconfig`

Retrieve kubeconfig from Talos cluster.

**Usage:**
```bash
task bootstrap:talos:kubeconfig
```

**What it does:**
- Extracts kubeconfig from control-01
- Merges into `~/.kube/config`
- Sets context to `artemis-cluster`

**Verification:**
```bash
kubectl get nodes
# Should show all 5 nodes
```

---

## Cluster Management

### `bootstrap:talos:health`

Check Talos cluster health.

**Usage:**
```bash
task bootstrap:talos:health
```

**Output:**
```
NODE          READY   VERSION
control-01    True    v1.8.0
control-02    True    v1.8.0
control-03    True    v1.8.0
worker-01     True    v1.8.0
worker-02     True    v1.8.0
```

---

### `bootstrap:talos:dashboard`

Open interactive Talos dashboard.

**Usage:**
```bash
task bootstrap:talos:dashboard
```

**What it shows:**
- Real-time node status
- Resource usage (CPU, memory, disk)
- Service states
- Logs

**Navigation:**
- `Tab` / `Shift+Tab` - Switch panels
- `q` - Quit
- `Enter` - Expand selected item

---

## Complete Bootstrap Workflow

### Fresh Cluster from Scratch

```bash
# 1. Generate configs
task bootstrap:talos:genconfig

# 2. Review generated configs
ls -la kubernetes/main/bootstrap/talos/clusterconfig/

# 3. Apply to all nodes (nodes will reboot)
task bootstrap:talos:apply-all

# 4. Wait for nodes to come back up (~2-3 minutes)
# Monitor: talosctl dmesg --nodes 10.10.99.101 -f

# 5. Bootstrap etcd (ONLY ONCE!)
task bootstrap:talos:bootstrap-etcd

# 6. Wait for cluster to stabilize (~1-2 minutes)
task bootstrap:talos:health

# 7. Get kubeconfig
task bootstrap:talos:kubeconfig

# 8. Verify Kubernetes
kubectl get nodes
# All nodes should be Ready

# 9. Continue to Flux bootstrap
task flux:bootstrap
```

---

## Troubleshooting

### Node not responding after apply

```bash
# Check Talos logs
talosctl dmesg --nodes <NODE_IP> -f

# Common issues:
# - Wrong disk device (check BOOT_DISK variable)
# - Network misconfiguration
# - Hardware compatibility
```

### etcd bootstrap fails

```bash
# Check if etcd is already bootstrapped
talosctl get members --nodes 10.10.99.101

# If stuck, may need to reset nodes and start over
talosctl reset --nodes <NODE_IP> --graceful=false
```

### Can't get kubeconfig

```bash
# Ensure cluster is healthy first
task bootstrap:talos:health

# Check talosctl can reach API
talosctl version --nodes 10.10.99.101

# Verify certificates
talosctl get secretstatus --nodes 10.10.99.101
```

---

## Variables Used

| Variable | Value | Used By |
|----------|-------|---------|
| `CONTROLPLANE_IPS[0]` | `10.10.99.101` | apply-control-01, bootstrap-etcd, kubeconfig |
| `CONTROLPLANE_IPS[1]` | `10.10.99.102` | apply-control-02 |
| `CONTROLPLANE_IPS[2]` | `10.10.99.103` | apply-control-03 |
| `WORKER_IPS[0]` | `10.10.99.201` | apply-worker-01 |
| `WORKER_IPS[1]` | `10.10.99.202` | apply-worker-02 |
| `TALOS_BOOTSTRAP` | `kubernetes/main/bootstrap/talos` | genconfig |

---

## Related Documentation

- [Talos Documentation](https://www.talos.dev/latest/)
- [talhelper Documentation](https://budimanjojo.github.io/talhelper/)
- [Flux Tasks](flux.md) - Next steps after bootstrap