# Skill: Cluster Status

Quick read-only health digest of Artemis-Cluster. Produces a 🟢/🟡/🔴 summary per layer.

## Run

```bash
# Flux — not-ready resources
flux get kustomizations -A --status-selector ready=false
flux get helmreleases -A --status-selector ready=false

# Nodes
kubectl get nodes -o wide

# Unhealthy pods (exclude Succeeded/Completed)
kubectl get pods -A --field-selector='status.phase!=Running,status.phase!=Succeeded' | grep -v Completed

# Recent warning events
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20

# Flux suspended resources
flux get all -A | grep -i suspend
```

Use `mcp__artemis-ops__mcp-k8s_kubectl_get` and `mcp__artemis-ops__mcp-k8s_kubectl_generic` if local kubectl is unavailable.

## Output Format

```
## Cluster Status — HH:MM ET

| Status | Layer       | Notes                                         |
|--------|-------------|-----------------------------------------------|
| 🟢     | Flux        | All 42 kustomizations + 38 helmreleases ready |
| 🟡     | Pods        | 1 pending: foo-bar-xxx in media               |
| 🔴     | Nodes       | talos-w-02 NotReady (15m)                     |
| 🟢     | Events      | No warnings in last 15 min                    |
```

## Layers (check in order)

1. **Flux** — kustomizations + helmreleases not Ready; any Suspended
2. **Nodes** — NotReady; check `talos-cp-01/02/03`, `talos-w-01`, `talos-w-02`, `talos-gpu-01`
3. **Pods** — not Running (skip Completed/Succeeded jobs)
4. **Events** — Warning events in last 15 minutes

## Status Key

- 🟢 All clear
- 🟡 Degraded / non-critical issue
- 🔴 Down / blocking issue requiring action
