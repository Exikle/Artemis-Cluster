---
name: cluster-status
description: Take a fast read on overall cluster health — failing pods, unready Flux resources, node and storage state — and report what is actually broken. Use for "cluster status", "what's broken", "health check", "anything down", or "quick status". Scoped to the Artemis cluster.
---

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

If local kubectl is unavailable, use the `-ops` k8s MCP tools: list them and match on the server and tool portion (resources list/get, events list), per `.agents/instructions/tooling.md` § MCP servers.

## Output Format

```
## Cluster Status — HH:MM ET

| Status | Layer       | Notes                                         |
|--------|-------------|-----------------------------------------------|
| 🟢     | Flux        | All kustomizations + helmreleases ready       |
| 🟡     | Pods        | 1 pending: foo-bar-xxx in media               |
| 🔴     | Nodes       | talos-w-02 NotReady (15m)                     |
| 🟢     | Events      | No warnings in last 15 min                    |
```

## Layers (check in order)

1. **Flux** — kustomizations + helmreleases not Ready; any Suspended
2. **Nodes** — NotReady; `kubectl get nodes` lists every node (ymir included)
3. **Pods** — not Running (skip Completed/Succeeded jobs)
4. **Events** — Warning events in last 15 minutes

## Status Key

- 🟢 All clear
- 🟡 Degraded / non-critical issue
- 🔴 Down / blocking issue requiring action
