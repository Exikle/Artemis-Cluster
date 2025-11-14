# Kubernetes Tasks

Tasks for kubectl utilities, cluster debugging, Cilium networking, and Gateway API management.

**Module:** `k8s` (`.taskfiles/Kubernetes/Taskfile.yaml`)

---

## Cluster Status

### `k8s:nodes`

Show all Kubernetes nodes.

**Usage:**
```bash
task k8s:nodes
```

**Output:**
```
NAME          STATUS   ROLES           AGE   VERSION
talos-cp-01   Ready    control-plane   10d   v1.31.0
talos-cp-02   Ready    control-plane   10d   v1.31.0
talos-cp-03   Ready    control-plane   10d   v1.31.0
talos-wk-01   Ready    <none>          10d   v1.31.0
talos-wk-02   Ready    <none>          10d   v1.31.0
```

---

### `k8s:pods`

Show all pods in all namespaces.

**Usage:**
```bash
task k8s:pods
```

---

### `k8s:pods:failing`

Show only failing/pending pods.

**Usage:**
```bash
task k8s:pods:failing
```

**What it shows:**
- Pods not in Running state
- Pods not in Completed state
- Useful for quick troubleshooting

---

### `k8s:events`

Show recent cluster events.

**Usage:**
```bash
task k8s:events
```

**Shows:**
- Last 50 events sorted by timestamp
- Warnings, errors, and info events
- Pod scheduling issues
- Node problems

---

### `k8s:namespaces`

List all namespaces.

**Usage:**
```bash
task k8s:namespaces
```

---

## Resource Monitoring

### `k8s:top:nodes`

Show node resource usage.

**Usage:**
```bash
task k8s:top:nodes
```

**Output:**
```
NAME          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
talos-cp-01   500m         12%    2048Mi          25%
talos-cp-02   480m         12%    2100Mi          26%
...
```

**Prerequisites:**
- metrics-server must be deployed

---

### `k8s:top:pods`

Show pod resource usage across all namespaces.

**Usage:**
```bash
task k8s:top:pods
```

---

## Cilium Networking

### `k8s:cilium:status`

Check Cilium CNI status.

**Usage:**
```bash
task k8s:cilium:status
```

**Output:**
```
KubeProxyReplacement:    True
Cluster health:          5/5 reachable
Host firewall:           Disabled
CNI Chaining:            none
Cilium:                  OK
```

---

### `k8s:cilium:bgp`

Check Cilium BGP peer status.

**Usage:**
```bash
task k8s:cilium:bgp
```

**Output:**
```
Node           Local AS   Peer AS   Peer Address    Session State
talos-cp-01    64500      64553     172.16.99.1     established
talos-cp-02    64500      64553     172.16.99.1     established
...
```

**What to check:**
- All nodes show "established"
- Peer address matches pfSense IP
- AS numbers are correct

---

### `k8s:cilium:connectivity`

Run Cilium connectivity test suite.

**Usage:**
```bash
task k8s:cilium:connectivity
```

**Warning:** This creates test pods and can take several minutes.

---

## Gateway API

### `k8s:gateway:list`

List all Gateway resources.

**Usage:**
```bash
task k8s:gateway:list
```

**Output:**
```
NAMESPACE   NAME               CLASS    ADDRESS        PROGRAMMED
default     external-gateway   cilium   10.10.99.98    True
default     internal-gateway   cilium   10.10.99.97    True
```

---

### `k8s:gateway:routes`

List all HTTPRoutes.

**Usage:**
```bash
task k8s:gateway:routes
```

**Shows:**
- All HTTPRoute resources
- Hostnames configured
- Parent gateway references
- ACCEPTED status

---

### `k8s:gateway:status`

Show detailed Gateway status.

**Usage:**
```bash
task k8s:gateway:status
```

**Shows:**
- Gateway conditions
- Listener status
- Attached routes
- IP addresses assigned

---

## Debugging

### `k8s:debug:pod`

Start an interactive debug pod with networking tools.

**Usage:**
```bash
task k8s:debug:pod
```

**What it does:**
- Launches nicolaka/netshoot container
- Drops you into an interactive shell
- Auto-deletes when you exit

**Available tools:**
- curl, wget, ping, nslookup, dig
- tcpdump, netstat, ss, ip
- traceroute, mtr, iperf

**Example usage:**
```bash
task k8s:debug:pod

# Inside the pod:
curl kubernetes.default.svc.cluster.local
ping 1.1.1.1
nslookup google.com
```

---

### `k8s:debug:dns`

Test DNS resolution in the cluster.

**Usage:**
```bash
task k8s:debug:dns
```

**What it tests:**
- Cluster DNS resolution
- Looks up kubernetes.default.svc.cluster.local
- Verifies CoreDNS is working

**Expected output:**
```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      kubernetes.default.svc.cluster.local
Address 1: 10.96.0.1 kubernetes.default.svc.cluster.local
```

---

### `k8s:health`

Run comprehensive cluster health check.

**Usage:**
```bash
task k8s:health
```

**Requires:**
- `scripts/health-check.sh` to exist

**What it checks:**
- Node status
- Flux kustomizations
- Cilium status
- BGP peers
- Gateways
- Infrastructure pods
- Platform pods

---

## Common Workflows

### Daily Health Check

```bash
# Check nodes
task k8s:nodes

# Check for failing pods
task k8s:pods:failing

# Check resource usage
task k8s:top:nodes
task k8s:top:pods

# Check network
task k8s:cilium:status
task k8s:cilium:bgp
```

### Troubleshoot Network Issues

```bash
# Check Cilium health
task k8s:cilium:status

# Check BGP peering
task k8s:cilium:bgp

# Test DNS
task k8s:debug:dns

# Interactive debug
task k8s:debug:pod
```

### Check Gateway Status

```bash
# List all gateways
task k8s:gateway:list

# Check routes
task k8s:gateway:routes

# Detailed status
task k8s:gateway:status
```

---

## Related Documentation

- [Cilium Documentation](https://docs.cilium.io/)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)