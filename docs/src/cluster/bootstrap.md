# Artemis Cluster - Complete Bootstrap Documentation

## Overview

This guide provides complete instructions for bootstrapping a Talos Kubernetes control plane cluster with 3 bare metal nodes.

**Cluster Specifications:**

- **OS:** TalosOS v1.11.5
- **Kubernetes:** v1.34.1
- **CNI:** Cilium v1.18.3
- **DNS:** CoreDNS v1.45.0
- **Control Planes:** 3 bare metal nodes (allow workloads)
- **Virtual IP (HA):** 10.10.99.99
- **Pod Network:** 10.42.0.0/16
- **Service Network:** 10.43.0.0/16

***

## Prerequisites

### Required Tools

```bash
talosctl v1.11.5+
kubectl v1.34+
sops (with age encryption)
helmfile
helm v3+
```

### Infrastructure Requirements

- 3 bare metal nodes with NVMe drives (`/dev/nvme0n1`)
- Network: `10.10.99.0/24` subnet
- Control plane IPs: `10.10.99.101`, `10.10.99.102`, `10.10.99.103`
- Virtual IP: `10.10.99.99`
- Talos installer USB drives

### Environment Setup

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

***

## Phase 1: Preparation

### Step 1: Verify Age Encryption

```bash
# Check age key exists
ls -la ~/.config/sops/age/keys.txt

# Extract public key for config encryption
AGE_PUBLIC_KEY=$(grep "# public key:" $SOPS_AGE_KEY_FILE | awk '{print $4}')
echo "Age public key: $AGE_PUBLIC_KEY"
```

### Step 2: Boot Nodes into Maintenance Mode

1. Insert Talos installer USB into each control plane node
2. Boot from USB and wait for maintenance mode (~2 minutes)
3. Verify nodes are reachable:

```bash
ping -c 2 10.10.99.101
ping -c 2 10.10.99.102
ping -c 2 10.10.99.103

# Verify maintenance mode
talosctl -n 10.10.99.101 --talosconfig="" version
talosctl -n 10.10.99.102 --talosconfig="" version
talosctl -n 10.10.99.103 --talosconfig="" version
```

### Step 3: Clean Up Previous Configurations

```bash
cd kubernetes/bootstrap/talos
rm -rf temp/
rm -f config/assets/talos-cp-*.secret.sops.yaml
```

***

## Phase 2: Configuration

### Step 4: Create Required Patches

Create all necessary Talos patches:

**Network Subnets Patch** (`config/patches/network-subnets.yaml`):

```yaml
cluster:
  network:
    podSubnets:
      - 10.42.0.0/16
    serviceSubnets:
      - 10.43.0.0/16
  apiServer:
    certSANs:
      - 127.0.0.1
      - 10.10.99.99
```

**VIP Patch** (`config/patches/vip.yaml`):

```yaml
machine:
  network:
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: true
        vip:
          ip: 10.10.99.99
```

**etcd Configuration** (`config/patches/etcd-config.yaml`):

```yaml
cluster:
  etcd:
    advertisedSubnets:
      - 10.10.99.0/24
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
```

**Control Plane Config** (`config/patches/control-plane-config.yaml`):

```yaml
cluster:
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
  coreDNS:
    disabled: true
```

**Sysctls** (`config/patches/sysctls.yaml`):

```yaml
machine:
  sysctls:
    fs.inotify.max_user_watches: "1048576"
    fs.inotify.max_user_instances: "8192"
    net.core.netdev_max_backlog: "30000"
    net.core.rmem_max: "67108864"
    net.core.wmem_max: "67108864"
```

**Node Labels** (`config/patches/node-labels.yaml`):

```yaml
machine:
  nodeLabels:
    bgppolicy: enabled
```

**Control Plane Install Disk** (`config/patches/controlplane-install-disk.yaml`):

```yaml
machine:
  install:
    disk: /dev/nvme0n1
```

***

### Step 5: Generate Base Configurations

```bash
cd kubernetes/bootstrap/talos

talosctl gen config artemis-cluster https://10.10.99.99:6443 \
  --kubernetes-version 1.34.1 \
  --talos-version v1.11.5 \
  --output-dir ./temp \
  --force
```

### Step 6: Generate Patched Control Plane Configs

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
AGE_PUBLIC_KEY=$(grep "# public key:" $SOPS_AGE_KEY_FILE | awk '{print $4}')

# Generate all 3 control planes
for i in 01 02 03; do
  talosctl machineconfig patch temp/controlplane.yaml \
    --patch @config/patches/network-subnets.yaml \
    --patch @config/patches/etcd-config.yaml \
    --patch @config/patches/control-plane-config.yaml \
    --patch @config/patches/sysctls.yaml \
    --patch @config/patches/containerd-config.yaml \
    --patch @config/patches/node-labels.yaml \
    --patch @config/patches/vip.yaml \
    --patch @config/patches/disable-cni-proxy.yaml \
    --patch @config/patches/allow-workloads-controlplane.yaml \
    --patch @config/patches/dhcp.yaml \
    --patch @config/patches/controlplane-install-disk.yaml \
    --patch @config/patches/openbs-mount.yaml \
    --patch "[{\"op\": \"add\", \"path\": \"/machine/network/hostname\", \"value\": \"talos-cp-$i\"}]" \
    --output temp/talos-cp-$i.yaml

  # Encrypt config
  sops --encrypt --age "$AGE_PUBLIC_KEY" \
    --encrypted-regex '^(token|crt|key|id|secret|secretboxEncryptionSecret|ca)$' \
    temp/talos-cp-$i.yaml > config/assets/talos-cp-$i.secret.sops.yaml
done

echo "✓ All configs generated and encrypted"
```

***

## Phase 3: Installation

### Step 7: Apply Configurations to Nodes

**⚠️ CRITICAL: Keep USB drives inserted during this step!**

```bash
cd kubernetes/bootstrap/talos

# Apply to all control planes
sops -d config/assets/talos-cp-01.secret.sops.yaml | \
  talosctl apply-config --insecure --nodes 10.10.99.101 --file /dev/stdin

sops -d config/assets/talos-cp-02.secret.sops.yaml | \
  talosctl apply-config --insecure --nodes 10.10.99.102 --file /dev/stdin

sops -d config/assets/talos-cp-03.secret.sops.yaml | \
  talosctl apply-config --insecure --nodes 10.10.99.103 --file /dev/stdin

echo "✓ Configs applied - installation in progress (7 minutes)"
sleep 420
```

### Step 8: Remove USB Drives

After installation completes:

1. Remove USB drives from all 3 nodes
2. Wait for nodes to boot from NVMe

```bash
echo "Remove USB drives now!"
echo "Waiting 2 minutes for NVMe boot..."
sleep 120
```

***

## Phase 4: Cluster Bootstrap

### Step 9: Configure Talosctl

```bash
cd kubernetes/bootstrap/talos

# Merge talosconfig
talosctl config merge temp/talosconfig

# Set endpoints
talosctl config endpoint 10.10.99.101 10.10.99.102 10.10.99.103
talosctl config node 10.10.99.101

# Verify connectivity
talosctl version
```

### Step 10: Bootstrap Kubernetes

```bash
# Bootstrap etcd and Kubernetes on first control plane
talosctl bootstrap --nodes 10.10.99.101

echo "✓ Bootstrap initiated - waiting 4 minutes"
sleep 240
```

### Step 11: Get Kubeconfig (Direct IP)

```bash
# Get kubeconfig using cp-01 direct IP (VIP not active yet)
talosctl kubeconfig --nodes 10.10.99.101 --endpoints 10.10.99.101 --force

# Verify cluster access (nodes will be NotReady without CNI)
kubectl get nodes
```

***

## Phase 5: CNI Installation

### Step 12: Prepare Cilium Configuration

Create `kubernetes/apps/kube-system/cilium/app/helm-values.yaml`:

```yaml
---
autoDirectNodeRoutes: true
bandwidthManager:
  enabled: true
  bbr: true
bpf:
  masquerade: true
  tproxy: true
cgroup:
  automount:
    enabled: false
  hostRoot: /sys/fs/cgroup
cluster:
  id: 1
  name: main
enableRuntimeDeviceDetection: true
endpointRoutes:
  enabled: true
hubble:
  enabled: false
ipam:
  mode: kubernetes
operator:
  replicas: 1
  rollOutPods: true
k8sClientRateLimit:
  qps: 32
  burst: 60
ipv4NativeRoutingCIDR: 10.42.0.0/16
k8sServiceHost: 127.0.0.1
k8sServicePort: 7445
kubeProxyReplacement: true
kubeProxyReplacementHealthzBindAddr: 0.0.0.0:10256
tunnelProtocol: ""
enableIPv4Masquerade: true
installNoConntrackIptablesRules: true
l2announcements:
  enabled: true
bgpControlPlane:
  enabled: true
gatewayAPI:
  enabled: true
loadBalancer:
  algorithm: maglev
  mode: dsr
localRedirectPolicy: true
ingressController:
  enabled: false
rollOutCiliumPods: true
routingMode: native
securityContext:
  privileged: true
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    cleanCiliumState:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE
```

### Step 13: Install Bootstrap Components

```bash
cd kubernetes/bootstrap

# Create required namespace
kubectl create namespace observability

# Install all components via helmfile
helmfile apply

echo "✓ Helmfile applied - waiting for Cilium"
```

### Step 14: Wait for Cluster Ready

```bash
# Wait for Cilium pods
kubectl wait --for=condition=Ready pods -n kube-system -l app.kubernetes.io/name=cilium --timeout=10m

# Wait for all nodes
kubectl wait --for=condition=Ready nodes --all --timeout=10m

echo "✓ Cluster is ready!"
```

***

## Phase 6: VIP Activation & Final Verification

### Step 15: Verify VIP

```bash
# Test VIP connectivity
ping -c 3 10.10.99.99

# Test API server via VIP
curl -k https://10.10.99.99:6443/version
```

### Step 16: Switch Kubeconfig to VIP

```bash
# Update kubeconfig to use VIP for HA
kubectl config set-cluster artemis-cluster --server=https://10.10.99.99:6443

# Verify VIP works
kubectl get nodes
```

### Step 17: Complete Health Check

```bash
# Verify all nodes Ready
kubectl get nodes -o wide

# Verify all system pods Running
kubectl get pods -A

# Check etcd cluster
talosctl -n 10.10.99.101 get members

# Verify Cilium status
kubectl -n kube-system exec ds/cilium -- cilium status --brief

# Check CoreDNS
kubectl get pods -n kube-system -l app.kubernetes.io/name=coredns

# Test DNS resolution
kubectl run dnstest --image=busybox:1.28 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/dnstest --timeout=60s
kubectl exec dnstest -- nslookup kubernetes.default
kubectl delete pod dnstest
```

***

## Success Criteria

Your cluster is fully operational when:

- ✅ All 3 control plane nodes show `Ready` status
- ✅ VIP (10.10.99.99) responds and API accessible via VIP
- ✅ Cilium pods Running (3 agents + 2 operators)
- ✅ CoreDNS pods Running (3 replicas)
- ✅ etcd cluster has 3 healthy members
- ✅ DNS resolution works
- ✅ kubectl operations work via VIP

***

## Key Configuration Notes

### Critical Settings for Talos 1.11.5 + Cilium 1.18.3

1. **VIP Configuration:** Must use `deviceSelector: physical: true` instead of hardcoded interface names
2. **Cilium Tunnel:** Use `tunnelProtocol: ""` (not deprecated `tunnel: disabled`)
3. **Cilium Device Detection:** Remove `devices` and `directRoutingDevice`, rely on `enableRuntimeDeviceDetection: true`
4. **systemd-boot:** Talos 1.11.5 doesn't support `extraKernelArgs` for interface naming
5. **Security Context:** Set `privileged: true` under `securityContext` for Talos compatibility

### Network Configuration

- **Pod CIDR:** 10.42.0.0/16
- **Service CIDR:** 10.43.0.0/16
- **VIP:** 10.10.99.99 (L2 announcement via Cilium)
- **API Server Ports:** 6443 (standard), 7445 (Cilium proxy)

***

## Troubleshooting

### Cilium Pods CrashLooping

- Check logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=cilium --tail=100`
- Common issue: device detection failed (solution: use `tunnelProtocol: ""` and runtime detection)

### VIP Not Working

- Verify VIP patch uses `deviceSelector: physical: true`
- Check addresses: `talosctl -n 10.10.99.101 get addresses`
- Ensure Cilium L2 announcements enabled

### Nodes Stuck NotReady

- Check Cilium status: `kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium`
- Verify CNI installation: `talosctl -n 10.10.99.101 get services`

### DNS Not Working

- Verify CoreDNS: `kubectl get pods -n kube-system -l app.kubernetes.io/name=coredns`
- Check service: `kubectl get svc -n kube-system kube-dns`
- Test directly: `kubectl exec <pod> -- nslookup kubernetes.default 10.43.0.10`

***

## Next Steps

After successful bootstrap:

1. **Commit working configuration to Git**
2. **Add worker nodes** (if needed)
3. **Install Flux** for GitOps
4. **Configure storage** (democratic-csi, OpenEBS, etc.)
5. **Deploy applications**

***

## Time Estimates

- **Total bootstrap time:** 20-25 minutes
- Config generation: 2 minutes
- Node installation: 7 minutes
- Kubernetes bootstrap: 4 minutes
- CNI installation: 5-10 minutes

---

**Congratulations! Your Artemis Kubernetes cluster is now fully operational with high availability! 🎉**
