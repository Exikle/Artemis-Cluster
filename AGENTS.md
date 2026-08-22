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
terraform/        # OpenTofu — Proxmox, UniFi, Cloudflare (invisible to Flux)
ansible/          # Host config — pantheon, atlas, Forgejo LXC, CRS309 (invisible to Flux)
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

### Workers (Metal)

- **ymir**: Gigabyte C246N-WU2 | Xeon E-2124G (4C/4T) | 16GB (2 slots free) | 128GB SATA M.2
    - UHD Graphics P630 iGPU — HEVC 10-bit + VP9 decode, better transcode than the M710q HD 530s
    - `eno1` (`d8:5e:d3:00:ea:81`) is the cabled NIC; `enp3s0` (`…:82`) unused
    - BIOS F1 — leave defaults; `Initial Display Output → IGFX` and `CSM → Disabled` both kill video

### Proxmox Host (`pantheon`)

- HPE ML150 G9 | 2× Xeon E5-2620 v3 (24 cores total)
- HP RAID card must be in HBA mode (ssacli or F9 BIOS) to expose raw disks

### Storage

- **TrueNAS** (`atlas`, 10.10.99.100): ~41TB usable (3× RAIDZ2), NFS `/mnt/atlas/media`
- **Rook-Ceph**: 3 OSDs (one per M710q, 256GB NVMe — Samsung MZVLW256HEHP/PM961, no PLP)
  — app config/DBs only, not media

---

## Networking

| VLAN | Name | Subnet          | IPv6                    | Purpose                          |
| ---- | ---- | --------------- | ----------------------- | -------------------------------- |
| 1001 | HME  | 10.10.1.0/24    | none                    | Trusted home                     |
| 1099 | LAB  | 10.10.99.0/24   | `2607:fea8:4e1f:3800::` | Servers, K8s nodes               |
| 1152 | IOT  | 10.10.152.0/24  | `2607:fea8:4e1f:3801::` | IoT (reachable from worker pods) |
| 1151 | GST  | 10.10.151.0/24  | none                    | Guest                            |
| 1088 | TST  | 192.168.88.0/24 | none                    | Testing                          |

- **UCG-Max** (10.10.99.1): WAN/NAT, VLANs, DHCP, BGP AS 64533, DNS (dcunha.io via external-dns-unifi)
- **Mikrotik CRS309** (172.16.99.2, `/30` transit on VLAN 99): L2 switching, but it **does** hold
  IPv6 config — it owns `fd00:10:10:152::1` on IOT and ran RA there. Do not assume it is L2-only
  when debugging IPv6.

### IPv6

Rogers delegates a prefix via DHCPv6-PD on the UCG WAN; the UCG carves a `/64` per VLAN and is
the **only** IPv6 router on 1099 and 1152. The delegated prefix rotates — never hardcode a GUA
from it (the `iot` NAD deliberately uses the UCG's stable link-local `fe80::58d6:1fff:fe27:c2e3`
as its `::/0` gateway).

**Pods are IPv4-only** — Cilium runs `enable-ipv6: false` and pod/service CIDRs are v4-only, so
any pod that resolves an AAAA and dials it gets `ENETUNREACH`. Nodes have working IPv6 egress on
`bond0.1099`; pods do not. See `.agents/references/networking.md` for the Matter/`sbr` link-local
trap before touching RA on VLAN 1152.

---

## Namespaces

22 namespaces under `kubernetes/apps/`. `ls kubernetes/apps/` is the ground truth — this table
goes stale, and app lists inside a namespace go stale faster
(`ls kubernetes/apps/<namespace>/`).

| Namespace            | Purpose                                                           |
| -------------------- | ----------------------------------------------------------------- |
| `arcade`             | Game servers — minecraft, eco                                     |
| `cert-manager`       | cert-manager + the Postgres server/client CA ClusterIssuers       |
| `cnpg-system`        | CloudNativePG operator                                            |
| `cortex`             | AI stack — litellm proxy/MCP, memini, SearXNG, hermes             |
| `database`           | **Shared data layer** — CNPG `postgres` + `pooler-rw`, Dragonfly  |
| `default`            | Immich, Komga, xbrowsersync                                       |
| `dragonfly-system`   | Dragonfly operator                                                |
| `external-endpoints` | HTTPRoutes/Services fronting non-k8s hosts (forgejo, TrueNAS, …)  |
| `external-secrets`   | External Secrets Operator (1Password)                             |
| `fediverse`          | apoci ActivityPub OCI registry                                    |
| `flux-system`        | Flux operator/instance, monitor, notifications                    |
| `forgejo`            | Forgejo-adjacent workloads — buildkit, forgesync, tekton-runner   |
| `home-automation`    | Home Assistant, MQTT, Zigbee/Matter, ESPHome                      |
| `kopiur-system`      | kopiur backup operator (replaced VolSync 2026-08-01)              |
| `kube-system`        | Cilium, CoreDNS, etcd-defrag, device plugins                      |
| `media`              | Arr stack, download clients, jellyfin, seerr, books/docs apps     |
| `network`            | Envoy Gateway (3 gateways), Cloudflare tunnel, DNS, towonel-agent |
| `observability`      | VictoriaMetrics, Grafana, logs, alerting, exporters               |
| `rook-ceph`          | Rook-Ceph cluster (3 OSDs) — app config/DBs only                  |
| `security`           | Pocket-ID (OIDC), LLDAP, tinyauth                                 |
| `system-upgrade`     | tuppr — automated Talos/Kubernetes upgrades                       |
| `tekton-system`      | Tekton pipelines                                                  |

`database` is load-bearing: the shared-data-layer policy (`cluster-conventions.md` § Deployment
Philosophy) means new apps onboard onto the Postgres and Dragonfly there rather than running
their own.

---

## Bootstrap Order

1. `just talos render-config <node> > /tmp/<node>.yaml` for each node, then
   `talosctl apply-config --insecure --nodes <node-ip> --file /tmp/<node>.yaml`
2. `just bootstrap` — Cilium → CoreDNS → cert-manager → external-secrets → 1Password → flux-operator → flux-instance

Node configs are Jinja2 templates (`talos/controlplane.yaml.j2`, `talos/worker.yaml.j2`,
`talos/nodes/<node>.yaml.j2`) — `talosctl apply-config --file` cannot read a `.j2`. Always go
through `just talos render-config`. See `.agents/references/talos.md`.

---

## Dev Tooling (mise)

```toml
talos = "1.14.0-rc.1"   # pinned to the cluster's Talos version
python  = "latest"
uv      = "latest"
opentofu = "latest"
oxfmt    = "latest"
shellcheck = "latest"
zizmor     = "latest"
"pipx:ansible-core" = "latest"
"pipx:ansible-lint" = "latest"
"github:home-operations/flate"     = "latest"
"github:home-operations/kopiur"    = "latest"
"github:home-operations/yayamlls"  = "latest"
"github:mitsuhiko/minijinja"       = "latest"
```

Config lives in `.mise/config.toml` (not `.mise.toml`), with `.mise/mise.lock` checksummed.
`just`, `kubectl`, `helmfile`, `op`, `gum`, `yq` and `kustomize` are assumed globally
installed. `.mise/config.toml` also pins `LANG`/`LC_ALL` to `C.UTF-8` — ansible refuses to
start otherwise, because this box exports a locale it has not generated.

Task runner: `just` — modules in `bootstrap/`, `kubernetes/`, `talos/`, `terraform/`,
`ansible/` and `ai/`, each a `mod.just` wired from the root `.justfile`.

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

| File                     | Contents                                                            |
| ------------------------ | ------------------------------------------------------------------- |
| `tooling.md`             | Critical rules, `just` commands, MCP server tiers                   |
| `cluster-conventions.md` | App structure, app-template v5, secrets pattern, reference index    |
| `yaml-conventions.md`    | Field ordering, YAML sorting, and the no-comments-in-manifests rule |
| `commit-style.md`        | Commit workflow, squash rules, message format, safety rules         |
| `session.md`             | Session journal format, when to write entries, memini usage         |

Read `.agents/references/` for topic-specific patterns (load only what's relevant):

| File                         | Contents                                                                          |
| ---------------------------- | --------------------------------------------------------------------------------- |
| `ansible.md`                 | Host config — scope, collections, 1Password lookup, netdata initscript fix, traps |
| `anubis.md`                  | Anubis PoW scraper deterrence — component shape, Forgejo allow-list, caveats      |
| `flux-patterns.md`           | Flux reconciliation, cross-namespace gotchas, CRD timing race, anti-patterns      |
| `hermes.md`                  | hermes-agent — deployed and operational; model choice, skills, chaski wiring      |
| `identity-stack.md`          | lldap → Pocket-ID → tinyauth chain, LDAP fallback, ResourceSet grants, gotchas    |
| `kopiur.md`                  | Backups — `ClusterRepository/atlas`, component defaults, mover uid, restores      |
| `media-stack.md`             | Arr stack, cross-seed, download clients, Prowlarr rules, zeroscaler, `:80` ports  |
| `memory-config.md`           | `.mcp.json` litellm tiers, memini plugin usage — when and how to update           |
| `networking.md`              | Gateways (internal/external/edge), cluster traffic rules, VLANs, CoreDNS guards   |
| `observability.md`           | VictoriaMetrics stack, Grafana Operator, ServiceMonitor gaps, kromgo badges       |
| `osd-topology-2026-08-21.md` | Dated capacity/redundancy evaluation behind the OSD rules — not live reference    |
| `pantheon-zfs.md`            | `pantheon`'s ZFS pools, HBA bay mapping, drive intake — host, not k8s, storage    |
| `postgres-dragonfly.md`      | Shared CNPG Postgres + Dragonfly — onboarding, DSN, dedicated-cluster exception   |
| `renovate.md`                | Preset pinning, automerge policy, per-app guards (Talos, pocket-id, rook-ceph)    |
| `rook-ceph.md`               | OSD topology rules, Ceph versions, CephX, mgr modules, RBD CSI recovery           |
| `storage.md`                 | Entry point — StorageClasses, NFS media mount, orphaned PVCs, Prometheus WAL      |
| `talos.md`                   | Node config management, schematic types (incl. `metal`), extensions, upgrades     |
| `terraform.md`               | OpenTofu — ownership boundary, provider choices, state, import-first, traps       |
| `towonel-agent.md`           | Publishing Artemis services through frostlink's towonel tunnel; `edge-gateway`    |

---

## Skills

`.agents/skills/` holds the repeatable cluster tasks. Each `SKILL.md` carries `name:` and
`description:` frontmatter — that frontmatter is what lets an agent invoke a skill on its own,
rather than only when someone types its name. A skill added without frontmatter is invisible.
See `add-agent-content` (global).

opencode discovers `.agents/skills/<name>/SKILL.md` natively. Claude Code does not, so every
skill also needs a `.claude/skills/<name>` symlink pointing at it.

Cluster-agnostic skills live in `~/.claude/skills/` and are available in every repo, so they
are not listed here: `forgejo`, `triage-renovate`, `build-container`, `playwright`,
`add-agent-content`.

Sixteen skills. This table must match `ls .agents/skills/` exactly (excluding `modules/`, which
is shared include material, not a skill, and is deliberately not symlinked).

Retired 2026-08-21: `cnpg-database` (merged into `deploy-app` +
`.agents/references/postgres-dragonfly.md` — its "one Cluster per app, never shared" policy was
superseded on 2026-07-02), `migrate-namespace` (built on VolSync `ReplicationSource`/
`ReplicationDestination`, CRDs that no longer exist; its one durable rule now lives in
`flux-patterns.md`), and `kopiur-pvc-migrate` (a completed one-shot migration, and Frostlink
content misfiled here).

| Skill                        | Natural Language Triggers                                                                                 |
| ---------------------------- | --------------------------------------------------------------------------------------------------------- |
| `deploy-app/SKILL.md`        | "deploy X", "add app X", "set up X in namespace Y", "create a new app", "onboard X to the cluster"        |
| `fix-flux/SKILL.md`          | "flux is broken", "HelmRelease stuck", "kustomization not reconciling", "ExternalSecret not syncing"      |
| `kopiur-restore/SKILL.md`    | "restore X from backup", "recover PVC", "roll back X's data", "kopiur restore", "the PVC is empty"        |
| `rbd-csi-recovery/SKILL.md`  | "pod stuck ContainerCreating", "RBD CSI", "volume won't mount", "input/output error on mount"             |
| `osd-rebuild/SKILL.md`       | "rebuild OSD", "replace the ceph drive", "compress existing ceph data", "swap the NVMe in cp-0X"          |
| `add-oidc-app/SKILL.md`      | "add SSO to X", "wire X into Pocket-ID", "set up OIDC for X", "single sign-on for X"                      |
| `add-tinyauth-app/SKILL.md`  | "protect X with tinyauth", "gate X behind tinyauth", "shared login for X", "ext_authz for X"              |
| `kubesearch/SKILL.md`        | "find examples for X", "how do others deploy X", "search kubesearch for X", "look up X in home-ops repos" |
| `review-app/SKILL.md`        | "review X deployment", "audit X manifests", "check X against conventions", "lint X app"                   |
| `cluster-status/SKILL.md`    | "cluster status", "what's broken", "health check", "anything down", "quick status"                        |
| `watch-deploys/SKILL.md`     | "watch the deploy", "monitor rollout", "keep an eye on flux", "loop watch", "/loop watch-deploys"         |
| `talos-ops/SKILL.md`         | "apply talos config", "upgrade talos node", "reboot node", "talos extension", "node config change"        |
| `grafana-dashboard/SKILL.md` | "add a Grafana dashboard", "GrafanaDashboard CRD", "$$variable not working", "datasource panels empty"    |
| `flux-validate/SKILL.md`     | "validate manifests", "render kustomization", "flate diff", "pre-commit check", "flux diff before commit" |
| `restore-drill/SKILL.md`     | "backup health check", "CNPG backup status", "restore drill", "are backups working", "WAL archiving"      |
| `apoci-federation/SKILL.md`  | "federate apoci", "apoci ActivityPub follow", "apoci webfinger", "apoci retention", "registry GC"         |

---

## Agents

Specialized subagents in `.agents/agents/` for deep, focused work. Each needs `name:`,
`description:`, and `mode: subagent` frontmatter, plus a symlink into `.claude/agents/` and
`.opencode/agents/` — neither client reads `.agents/agents/` directly.

When to spawn one, what it costs not to, and where its findings should be published:
`~/.claude/CLAUDE.md` § Subagents, § Context Economy, § Artifacts, plus
`.agents/instructions/tooling.md` § Subagents in this repo.

| Agent               | Purpose                                                                                        |
| ------------------- | ---------------------------------------------------------------------------------------------- |
| `cluster-health.md` | Read-only reliability audit across all layers: Flux → nodes → storage → network → certs → apps |
