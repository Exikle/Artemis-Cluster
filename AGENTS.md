# Artemis-Cluster — Agent Context

GitOps homelab Kubernetes cluster on Talos Linux, managed with Flux CD.
This file is the canonical reference for all AI agents working in this repo.

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecret (no SOPS)
- **Domain**: `dcunha.io` | **Repo**: <https://git.dcunha.io/exikle/Artemis-Cluster>
- **CNI**: Cilium (BGP) | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)

---

## Repo Structure

`ls` at the repo root is the map. Only `kubernetes/` reconciles via Flux — `terraform/`,
`ansible/` and `talos/` are invisible to it. App directory shapes (single, multi-component,
operator/operand, CR collection, fleet) are defined in `cluster-conventions.md` § App Directory
Structure.

---

## Hardware

### Control Planes (Metal)

- **3× Lenovo M710q** — `talos-cp-01/02/03`
    - 256GB NVMe (Samsung MZVLW256HEHP) for cluster storage | VLAN 1099 (LAB, static IPs)
    - Boot SATA SSD, and **the three are not the same**: cp-02/03 are 860 EVO 500GB (TLC),
      **cp-01 is an 860 QVO 1TB (QLC)**. etcd's WAL lives on this device, and QLC's sustained
      small sync writes are its worst case: cp-01 measures ~12.4ms per write against ~1.15ms on
      cp-02, which makes cp-01's apiserver ~7× slower on pod reads and is the root cause of the
      cluster-wide Multus sandbox failures in #1956. The drive is not failing — no ATA errors, 8%
      full, stable for months. It is the wrong class of drive for etcd. Full model strings come
      from the `by-id` symlink (`talosctl get disk sda -o yaml`); the `model:` field truncates at
      16 bytes to "Samsung SSD 860" and hides EVO/QVO.

### Workers (Proxmox VMs on `pantheon`)

- **talos-w-01, talos-w-02**: 32GB RAM, 6 vCPU (NUMA), 64GB disk
- **talos-gpu-01**: 32GB RAM, 6 vCPU, ASRock Arc A380 passthrough (6GB)

### Workers (Metal)

- **ymir**: Gigabyte C246N-WU2 | Xeon E-2124G (4C/4T) | 16GB (2 slots free) | 128GB SATA M.2
    - **1U chassis** — 44mm internal, so no discrete GPU fits; the x16 slot is not usable for one
    - UHD Graphics P630 iGPU — HEVC 10-bit + VP9 decode, better transcode than the M710q HD 530s
    - `eno1` (`d8:5e:d3:00:ea:81`) is the cabled NIC; `enp3s0` (`…:82`) unused
    - BIOS F1 — leave defaults; `Initial Display Output → IGFX` and `CSM → Disabled` both kill video

### Proxmox Host (`pantheon`)

- HPE ML150 G9 | 2× Xeon E5-2620 v3 (24 cores total)
- HP RAID card must be in HBA mode (ssacli or F9 BIOS) to expose raw disks

### Storage

- **TrueNAS** (`atlas`, 10.10.99.100): ~41TB usable (3× RAIDZ2), NFS `/mnt/atlas/media`
- **miroir** (`miroir-system`): replicated block storage on the M710q NVMe, StorageClasses
  `miroir` (default, 3 replicas) and `miroir-local`. App config/DBs only, not media.
  **Rook-Ceph was removed in `b9008ac55`** — no `ceph-block`, no CephFS, no CephCluster CRD.

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

`ls kubernetes/apps/` is the ground truth for the namespace list, and
`ls kubernetes/apps/<namespace>/` for what runs in each. Operators that serve the whole cluster
get their own `*-system` namespace; `external-endpoints` fronts hosts that are not in Kubernetes.

`database` is load-bearing: the shared-data-layer policy (`cluster-conventions.md` § Deployment
Philosophy) means new apps onboard onto the Postgres and Dragonfly there rather than running
their own.

---

## Bootstrap Order

Full sequence, the `[confirm]` gate, and the `.j2` template trap: `.agents/references/bootstrap.md`.

---

## Dev Tooling (mise)

Tool pins are in `.mise/config.toml` — `talos` is pinned to the cluster's running Talos version.

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
- **TrueNAS netdata metrics**: automated as of 2026-08-22 — no longer a manual chore.
  A TrueNAS update replaces `/etc/netdata`, which silently stops metrics reaching
  `truenas-exporter` in the cluster. `ansible/roles/netdata_exporter` keeps the canonical
  config on a dataset (`/mnt/atlas/config/netdata/`) and registers a POSTINIT init script
  so the box repairs itself at boot. Re-run `just ansible apply atlas` if it ever drifts.

    The earlier instruction here said to re-fetch `netdata.conf` from the
    `truenas-graphite-to-prometheus` repo. That named the wrong file: the exporting config
    actually lives in **`/etc/netdata/exporting.conf`** (a `[graphite:prometheus]` block
    pointing at `10.10.99.93:9109`), and `netdata.conf` itself is stock.

---

## Writing docs in this repo: the list rule

**A doc may carry a list only when it holds a fact a `grep` or `ls` cannot recover** — an
allocation, an intent, a rationale, or a historical correction. Anything a one-line command
answers must _be_ the command, not its output.

Keep, because the fact is not in the tree:

- the Dragonfly index registry (`postgres-dragonfly.md`) — an index _claimed but unconfigured_
  exists nowhere else
- the media port tables (`media-stack.md`) — they record which ports were deliberately normalised
  and which were not, and say the live Service is authoritative
- the CNPG cluster inventory — one row since immich was consolidated in on 2026-09-01; kept because
  the fact that there is exactly one is itself the thing worth stating
- the app _role_ columns ("Prowlarr is the indexer source of truth") — pure rationale
- the skills and agents catalogs below — the sync rule is stated and enforced

Delete, because the tree already answers it:

- which apps carry a given component — `grep -rln 'components/<name>' kubernetes/apps/`
- how many apps carry it — a count is maintenance debt in exchange for nothing; no check anywhere
  depends on the number, and it was previously written in five files at once
- which apps are on shared Postgres, on tinyauth, or in a namespace — `grep`, `ls`, or `kubectl get`
- dated snapshot columns (key counts, live versions) — stale within the week, and the doc that
  carries one usually also carries the command that answers it live

An outstanding action item is not a list at all: **parked work becomes a Forgejo issue**
(`.agents/references/issue-tracking.md`), and the doc links to it. A strikethrough TODO in a
reference doc is the failure mode this rule exists to stop.

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

| File                         | Contents                                                                                                  |
| ---------------------------- | --------------------------------------------------------------------------------------------------------- |
| `ansible.md`                 | Host config — scope, collections, 1Password lookup, netdata initscript fix, traps                         |
| `app-structure.md`           | The five canonical app directory shapes — single, multi-component, operator/operand, CR collection, fleet |
| `anubis.md`                  | Anubis PoW scraper deterrence — component shape, Forgejo allow-list, caveats                              |
| `arcade-eco.md`              | eco game server — one-way save migration, the 15m `timeout`, GDI+ root requirement, the gatus probe       |
| `bootstrap.md`               | Cluster bootstrap order, the `just bootstrap cluster` recipe, `.j2` render trap                           |
| `claude-code-setup.md`       | Hooks, generated guards, skill/subagent symlinks — Claude Code only                                       |
| `cortex-mcp.md`              | The MCP fleet — per-server config, upstream quirks, tool-surface budget, RBAC                             |
| `flux-patterns.md`           | Flux reconciliation, cross-namespace gotchas, CRD timing race, anti-patterns                              |
| `gpu.md`                     | Intel GPUs — the DRA and device-plugin lanes, CEL selectors, drm-exporter, the Arc, `xe` vs `i915`        |
| `hermes.md`                  | hermes-agent — deployed and operational; model choice, skills, chaski wiring                              |
| `issue-tracking.md`          | Parked/blocked work becomes a Forgejo issue; label taxonomy, board limits                                 |
| `identity-stack.md`          | lldap → Pocket-ID → tinyauth chain, LDAP fallback, ResourceSet grants, gotchas                            |
| `kopiur.md`                  | Backups — `ClusterRepository/atlas`, component defaults, mover uid, restores                              |
| `media-stack.md`             | Arr stack, cross-seed, download clients, Prowlarr rules, zeroscaler, `:80` ports                          |
| `memory-config.md`           | `.mcp.json` litellm tiers, memini plugin usage — when and how to update                                   |
| `networking.md`              | Gateways (internal/external/edge), cluster traffic rules, VLANs, CoreDNS guards                           |
| `observability.md`           | VictoriaMetrics stack, Grafana Operator, ServiceMonitor gaps, kromgo badges                               |
| `pantheon-zfs.md`            | `pantheon`'s ZFS pools, HBA bay mapping, drive intake — host, not k8s, storage                            |
| `pod-security-exceptions.md` | Every app that deviates from the default security context, and what actually breaks under it              |
| `postgres-dragonfly.md`      | Shared CNPG Postgres + Dragonfly — onboarding, DSN, dedicated-cluster exception                           |
| `renovate.md`                | Preset pinning, automerge policy, per-app guards (Talos, pocket-id)                                       |
| `storage.md`                 | Entry point — StorageClasses, NFS media mount, orphaned PVCs, Prometheus WAL                              |
| `scheduling.md`              | Request-based packing, descheduler thresholds, cordon's eviction trap, Tekton pinning                     |
| `talos.md`                   | Node config management, schematic types (incl. `metal`), extensions, upgrades                             |
| `tekton-ci.md`               | `oci-push` shape and rationale, the workflow-vs-library clocks, Tekton step-request trap                  |
| `terraform.md`               | OpenTofu — ownership boundary, provider choices, state, import-first, traps                               |
| `towonel-agent.md`           | Publishing Artemis services through frostlink's towonel tunnel; `edge-gateway`                            |

---

## Skills

`.agents/skills/` holds the repeatable cluster tasks. Each `SKILL.md` carries `name:` and
`description:` frontmatter — that frontmatter is what lets an agent invoke a skill on its own,
rather than only when someone types its name. A skill added without frontmatter is invisible.
See `add-agent-content` (global).

opencode discovers `.agents/skills/<name>/SKILL.md` natively. Claude Code does not, so every
skill also needs a `.claude/skills/<name>` symlink pointing at it.

**The catalog is not repeated here.** Claude Code injects every skill's name and description
into the system prompt already, and opencode reads the directory; `ls .agents/skills/` is the
list. A table here would be a third copy that drifts — which it did, twice, before this note
replaced it. Cluster-agnostic skills live in `~/.claude/skills/` and are available everywhere:
`forgejo`, `triage-renovate`, `build-container`, `playwright`, `add-agent-content`.

Retired 2026-08-21: `cnpg-database` (merged into `deploy-app` +
`.agents/references/postgres-dragonfly.md` — its "one Cluster per app, never shared" policy was
superseded on 2026-07-02), `migrate-namespace` (built on VolSync `ReplicationSource`/
`ReplicationDestination`, CRDs that no longer exist; its one durable rule now lives in
`flux-patterns.md`), and `kopiur-pvc-migrate` (a completed one-shot migration, and Frostlink
content misfiled here).

Split 2026-09-01: `review-app` was doing two incompatible jobs under one name — a one-minute
mechanical lint and a deep correctness audit — and in practice the lint always finished first and
reported PASS, so the audit never happened. It now keeps only the lint half (plus a
`just kube render-local-ks` step and a mandatory "Not checked by this skill" block, so a clean lint
cannot be mistaken for a clearance). **The word "audit" moved to the `audit-app` subagent**
(`.agents/agents/audit-app.md`), which reads the live cluster. If you are looking for the deep
review that used to be promised here, that is where it went.

---

## Agents

Specialized subagents in `.agents/agents/` for deep, focused work. Each needs `name:`,
`description:`, and `mode: subagent` frontmatter, plus a symlink into `.claude/agents/` and
`.opencode/agents/` — neither client reads `.agents/agents/` directly. Both clients surface the
name and description themselves, so the catalog is `ls .agents/agents/`, not a table here.

When to spawn one and where its findings should be published: `~/.claude/CLAUDE.md`
§ Delegation and context, plus `.agents/instructions/tooling.md` § Subagents in this repo.
