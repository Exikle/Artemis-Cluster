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

## Before Working on Manifests

Read `.agents/instructions/` files relevant to the task:

| File                     | Contents                                                         |
| ------------------------ | ---------------------------------------------------------------- |
| `cluster-conventions.md` | App structure, app-template v5, secrets pattern, reference index |
| `yaml-conventions.md`    | Field ordering and YAML sorting rules for all manifests          |
| `commit-style.md`        | Commit workflow, squash rules, message format, safety rules      |
| `media-stack.md`         | Arr stack, cross-seed, download clients, Prowlarr rules          |

For topic-specific patterns, read from `.agents/references/`:

| File               | Contents                                                      |
| ------------------ | ------------------------------------------------------------- |
| `flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race |
| `storage.md`       | Rook-Ceph, VolSync, NFS, RBD CSI recovery                     |
| `networking.md`    | Gateways, cluster traffic rules, VLANs                        |
| `observability.md` | Grafana Operator, ServiceMonitor gaps, Rook metrics, kromgo   |
| `talos.md`         | Node config management, extension changes                     |

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
