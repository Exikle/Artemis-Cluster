# Artemis-Cluster — Claude Context

> **Full reference in `AGENTS.md`** — hardware, networking, namespaces, bootstrap order, known issues.
> **Behavioral rules and task runbooks in `.agents/`** — read relevant files before working.

## Identity

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **Cluster**: Artemis-Cluster on Talos Linux
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecret (no SOPS)
- **Domain**: `dcunha.io` | **Repo**: <https://github.com/Exikle/Artemis-Cluster>
- **CNI**: Cilium (BGP) | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)

---

## Always-Loaded Instructions

@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md

---

## Topic References (load on demand)

For topic-specific patterns, read from `.agents/references/`:

| File                          | Contents                                                      |
| ----------------------------- | ------------------------------------------------------------- |
| `references/flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race |
| `references/storage.md`       | Rook-Ceph, VolSync, NFS, RBD CSI recovery                     |
| `references/networking.md`    | Gateways, cluster traffic rules, VLANs                        |
| `references/observability.md` | Grafana Operator, ServiceMonitor gaps, Rook metrics, kromgo   |
| `references/talos.md`         | Node config management, extension changes                     |
| `instructions/media-stack.md` | Arr stack, cross-seed, download clients, Prowlarr rules       |

## Skills

Use `.agents/skills/` for repeatable tasks — invoke via the Skill tool or a `/slash-command`.
See `AGENTS.md` for the full skills table with trigger phrases.

---

## Critical Rules

- **No SOPS** — secrets via 1Password ExternalSecret only (`ClusterSecretStore: onepassword-connect`)
- **No TZ env var** — k8tz handles timezone cluster-wide; never set `TZ` in pod specs
- **No shared OCIRepository** — every app gets its own standalone OCIRepository
- **No external hostnames for cluster traffic** — always `<app>.<namespace>.svc.cluster.local`
- **No `git add .` or `git add -A`** — stage specific files by name only
- **Routes in HelmRelease values** — `HTTPRoute` goes in helmrelease values, not standalone files
- **Test before commit** — `just kube apply-ks <ns> <ks>` then wait for explicit user confirmation
