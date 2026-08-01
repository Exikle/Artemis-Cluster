# Artemis-Cluster — Agent Context

GitOps homelab Kubernetes cluster on Talos Linux, managed with Flux CD.
This file is the canonical reference for all AI agents working in this repo.

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecret (no SOPS)
- **Domain**: `dcunha.io` | **Repo**: <https://git.dcunha.io/exikle/Artemis-Cluster>
- **CNI**: Cilium (BGP) | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)

---

## Repo Structure

```text
.agents/          # AI agent instructions, references, and skills
bootstrap/        # Bootstrap justfile — run order matters
talos/            # Node configs (render-config from .yaml.j2 templates)
kubernetes/
  apps/           # App HelmReleases by namespace
  components/     # Shared kustomize components (kopiur, etc.)
  flux/sync/      # Entrypoint Kustomization → kubernetes/apps
```

---

## Hardware

### Control Planes (Metal)

- **3× Lenovo M710q** — `talos-cp-01/02/03`
    - Boot: 256GB SATA SSD | Ceph OSD: 256GB NVMe | VLAN 1099 (LAB, static IPs)

### Workers (Proxmox VMs on `pantheon`)

- **talos-w-01, talos-w-02**: 32GB RAM, 6 vCPU (NUMA), 64GB disk
- **talos-gpu-01**: 32GB RAM, 6 vCPU, ASRock Arc A380 passthrough (6GB)

### Proxmox Host (`pantheon`)

- HPE ML150 G9 | 2× Xeon E5-2620 v3 (24 cores total)
- HP RAID card must be in HBA mode (ssacli or F9 BIOS) to expose raw disks

### Storage

- **TrueNAS** (`atlas`, 10.10.99.100): ~41TB usable (3× RAIDZ2), NFS `/mnt/atlas/media`
- **Rook-Ceph**: 3 OSDs (one per M710q, 256GB SATA each) — app config/DBs only, not media

---

## Networking

| VLAN | Name | Subnet          | Purpose                          |
| ---- | ---- | --------------- | -------------------------------- |
| 1001 | HME  | 10.10.1.0/24    | Trusted home                     |
| 1099 | LAB  | 10.10.99.0/24   | Servers, K8s nodes               |
| 1152 | IOT  | 10.10.152.0/24  | IoT (reachable from worker pods) |
| 1151 | GST  | 10.10.151.0/24  | Guest                            |
| 1088 | TST  | 192.168.88.0/24 | Testing                          |

- **UCG-Max** (10.10.99.1): WAN/NAT, VLANs, DHCP, BGP AS 64533, DNS (dcunha.io via external-dns-unifi)
- **Mikrotik CRS309**: L2 switch only

---

## Namespaces

| Namespace          | Purpose                                          |
| ------------------ | ------------------------------------------------ |
| `flux-system`      | Flux operator/instance, monitor, notifications   |
| `media`            | Arr stack, download clients, media apps          |
| `cortex`           | AI stack — litellm proxy/MCP, memini, SearXNG    |
| `home-automation`  | Home Assistant, MQTT, Zigbee/Matter, ESPHome     |
| `observability`    | Metrics, logs, dashboards, alerting              |
| `security`         | Pocket-ID (OIDC), LLDAP                          |
| `rook-ceph`        | Rook-Ceph cluster (3 OSDs) — app config/DBs only |
| `network`          | Envoy Gateway, Cloudflare tunnel, DNS            |
| `external-secrets` | External Secrets Operator (1Password)            |

App lists rot — for the current apps in a namespace, run `ls kubernetes/apps/<namespace>/`.

---

## Bootstrap Order

1. `talosctl apply-config --insecure --nodes <cp-ip> --file talos/controlplane.yaml`
2. `talosctl apply-config --insecure --nodes <worker-ip> --file talos/worker.yaml`
3. `just bootstrap` — Cilium → CoreDNS → cert-manager → external-secrets → 1Password → flux-operator → flux-instance

---

## Dev Tooling (mise)

```toml
"uv" = "latest"
"pipx:flux-local" = "latest"
prettier = "latest"
cilium-cli = "latest"
crane = "latest"        # container image tag + digest lookup
krew = "latest"
yamlfmt = "latest"
lefthook = "latest"
"github:mitsuhiko/minijinja" = "latest"
```

Task runner: `just` (`bootstrap/mod.just`, `kubernetes/mod.just`)

---

## Known Hardware & Ops Issues

- **Proxmox HP RAID**: ssacli or F9 BIOS → HBA mode to expose raw disks
- **Eaton UPS**: batteries dead — not providing real protection
- **TrueNAS netdata.conf**: must be replaced after every TrueNAS update — run on `atlas` (10.10.99.100):

```bash
curl -s https://raw.githubusercontent.com/Supporterino/truenas-graphite-to-prometheus/main/netdata.conf \
  | sudo tee /etc/netdata/netdata.conf && sudo systemctl restart netdata
```

---

## Agent Instructions

Read `.agents/instructions/` before working in this repo:

| File                     | Contents                                                         |
| ------------------------ | ---------------------------------------------------------------- |
| `cluster-conventions.md` | App structure, app-template v5, secrets pattern, reference index |
| `yaml-conventions.md`    | Field ordering and YAML sorting rules for all manifests          |
| `commit-style.md`        | Commit workflow, squash rules, message format, safety rules      |
| `session.md`             | Session journal format, when to write entries, memini usage      |

Read `.agents/references/` for topic-specific patterns (load only what's relevant):

| File                    | Contents                                                                       |
| ----------------------- | ------------------------------------------------------------------------------ |
| `flux-patterns.md`      | Flux reconciliation, cross-namespace gotchas, CRD timing race, anti-patterns   |
| `identity-stack.md`     | lldap → Pocket-ID → tinyauth chain, LDAP fallback, ResourceSet grants, gotchas |
| `media-stack.md`        | Arr stack, cross-seed, download clients, Prowlarr rules                        |
| `memory-config.md`      | `.mcp.json` litellm tiers, memini plugin usage — when and how to update        |
| `networking.md`         | Gateways (internal/external), cluster traffic rules, VLANs                     |
| `observability.md`      | Grafana Operator, ServiceMonitor gaps, Rook metrics, kromgo badges             |
| `postgres-dragonfly.md` | Shared CNPG Postgres + Dragonfly — app onboarding, DSN format, gotchas         |
| `storage.md`            | Rook-Ceph, kopiur, NFS, RBD CSI recovery, Prometheus WAL                       |
| `talos.md`              | Node config management, extension changes, automated upgrades                  |

---

## Skills

`.agents/skills/` holds the repeatable cluster tasks. Each `SKILL.md` carries `name:` and
`description:` frontmatter, and `.claude/skills/<name>` is a symlink to it — that frontmatter
is what lets Claude Code invoke a skill on its own, rather than only when someone types its
name. A skill added without frontmatter is invisible. See `add-agent-content` (global).

Cluster-agnostic skills live in `~/.claude/skills/` and are available in every repo, so they
are not listed here: `forgejo`, `triage-renovate`, `build-container`, `playwright`,
`add-agent-content`.

| Skill                         | Natural Language Triggers                                                                                 |
| ----------------------------- | --------------------------------------------------------------------------------------------------------- |
| `deploy-app/SKILL.md`         | "deploy X", "add app X", "set up X in namespace Y", "create a new app", "onboard X to the cluster"        |
| `fix-flux/SKILL.md`           | "flux is broken", "HelmRelease stuck", "kustomization not reconciling", "ExternalSecret not syncing"      |
| `kopiur-restore/SKILL.md`     | "restore X from backup", "recover PVC", "roll back X's data", "kopiur restore"                            |
| `kopiur-pvc-migrate/SKILL.md` | "migrate PVC to openebs-zfs", "move PVC to new storageclass", "kopiur migration", "Frostlink PVC migrate" |
| `rbd-csi-recovery/SKILL.md`   | "pod stuck ContainerCreating", "RBD CSI", "volume won't mount", "input/output error on mount"             |
| `add-oidc-app/SKILL.md`       | "add SSO to X", "wire X into Pocket-ID", "set up OIDC for X", "single sign-on for X"                      |
| `add-tinyauth-app/SKILL.md`   | "protect X with tinyauth", "gate X behind tinyauth", "shared login for X", "ext_authz for X"              |
| `kubesearch/SKILL.md`         | "find examples for X", "how do others deploy X", "search kubesearch for X", "look up X in home-ops repos" |
| `review-app/SKILL.md`         | "review X deployment", "audit X manifests", "check X against conventions", "lint X app"                   |
| `migrate-namespace/SKILL.md`  | "move X to namespace Y", "migrate X from default to media", "change namespace for X"                      |
| `cluster-status/SKILL.md`     | "cluster status", "what's broken", "health check", "anything down", "quick status"                        |
| `watch-deploys/SKILL.md`      | "watch the deploy", "monitor rollout", "keep an eye on flux", "loop watch", "/loop watch-deploys"         |
| `cnpg-database/SKILL.md`      | "add PostgreSQL", "set up CNPG", "deploy a database", "add postgres for X", "CNPG cluster"                |
| `talos-ops/SKILL.md`          | "apply talos config", "upgrade talos node", "reboot node", "talos extension", "node config change"        |
| `grafana-dashboard/SKILL.md`  | "add a Grafana dashboard", "GrafanaDashboard CRD", "$$variable not working", "datasource panels empty"    |
| `flux-validate/SKILL.md`      | "validate manifests", "render kustomization", "flate diff", "pre-commit check", "flux diff before commit" |
| `restore-drill/SKILL.md`      | "backup health check", "CNPG backup status", "restore drill", "are backups working", "WAL archiving"      |
| `apoci-federation/SKILL.md`   | "federate apoci", "apoci ActivityPub follow", "mirror apoci artifacts between instances"                  |

---

## Agents

Specialized subagents in `.agents/agents/` for deep, focused work:

| Agent               | Purpose                                                                                        |
| ------------------- | ---------------------------------------------------------------------------------------------- |
| `cluster-health.md` | Read-only reliability audit across all layers: Flux → nodes → storage → network → certs → apps |
