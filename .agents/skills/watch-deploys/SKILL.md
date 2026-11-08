---
name: watch-deploys
description: Watch an in-flight deployment or Flux reconciliation until it settles or fails, reporting state transitions as they happen. Use for "watch the deploy", "monitor the rollout", "keep an eye on flux", or when a change was just pushed and its landing needs following. Scoped to the Artemis cluster.
---

# Skill: Watch Deploys

This skill is a delta-aware cluster state watcher. Use it with `/loop 30s /watch-deploys` during active deployments.

Each tick shows only what **changed** since the last tick, not the full cluster state.

## State Cache

Store the previous snapshot at `/tmp/artemis-watch-deploys.json`. On the first run (no cache), show the full current state as the baseline and write the cache.

## What to Track

```bash
# Flux snapshot
flux get kustomizations -A
flux get helmreleases -A

# Pod snapshot
kubectl get pods -A -o json

# Node snapshot
kubectl get nodes -o json
```

If local kubectl is unavailable, use the `-ops` k8s MCP tools. List them and match on the server and tool portion (pods list, resources list), as `.agents/instructions/tooling.md` § MCP servers describes.

## Delta Logic

Compare the current snapshot to the cached snapshot:

| Change type                                 | What to show                               |
| ------------------------------------------- | ------------------------------------------ |
| Kustomization/HelmRelease: NotReady → Ready | `RECOVERED: <name> (<ns>)`                 |
| Kustomization/HelmRelease: Ready → NotReady | `BROKE: <name> (<ns>) — <reason>`          |
| Kustomization/HelmRelease: newly Suspended  | `SUSPENDED: <name> (<ns>)`                 |
| Pod restart count increased                 | `RESTARTED: <pod> (<ns>) — restarts: N→M`  |
| Pod phase changed                           | `PHASE CHANGE: <pod> (<ns>) — <old>→<new>` |
| Node readiness changed                      | `NODE: <name> — Ready→NotReady`            |

## Output Format

```
Tick [20:14:32 ET] — Δ since 20:14:02

RECOVERED:  immich (default) HelmRelease → Ready
BROKE:      komf (media) HelmRelease → Failed: "container image not found"
RESTARTED:  memini-xxx-yyy (cortex) restarts: 0→1

✓ Nodes: all ready
✓ No new Flux suspensions
```

If nothing changed, output: `✓ No changes since 20:14:02`

## Cadence

- Active deploy: `/loop 30s /watch-deploys`
- Idle monitoring: `/loop 2m /watch-deploys`
- Stop when all resources are back to Ready
