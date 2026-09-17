# Artemis-Cluster — Agent Context

GitOps homelab Kubernetes cluster on Talos Linux, reconciled by Flux CD. This file is the entry
point for every AI agent working here, and it is deliberately short: it holds what is true on
**every** turn, plus an index of where everything else lives.

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **Domain**: `dcunha.io` | **Repo**: <https://git.dcunha.io/exikle/Artemis-Cluster>
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecret, no SOPS
- **CNI**: Cilium (BGP) | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)

`ls` at the repo root is the map. Only `kubernetes/` reconciles through Flux — `terraform/`,
`ansible/` and `talos/` are invisible to it.

---

## The seven rules that apply to every turn

Everything else is conditional. These are not.

1. **`main` is production.** There is no staging cluster. Every push reconciles immediately.
   Suspend the root **and** the target Kustomization, `just kube apply-ks`, then wait for the
   user to confirm the live deployment before committing. Two suspends, not one — `apply-ks`
   suspends nothing, and a child reconciling on its own interval silently reverts your edits.
2. **Never apply cluster changes through an MCP tool.** The MCP k8s tools are for read-only
   inspection. Writes go through git, or through `just kube apply-ks` during a test.
3. **Secrets are 1Password ExternalSecrets** (`ClusterSecretStore: onepassword-connect`). SOPS is
   fully removed — never suggest age encryption or `sops --encrypt`.
4. **Pods are IPv4-only.** Cilium runs `enable-ipv6: false`, and pod/service CIDRs are v4-only.
   Anything that resolves an AAAA and dials it gets `ENETUNREACH`. Nodes have working IPv6 egress
   on `bond0.1099`; pods do not.
5. **Cluster traffic uses `<app>.<namespace>.svc.cluster.local`**, never an external hostname.
6. **Stage files by name.** No `git add .`, no `git add -A`, no `--no-verify`. One-line semantic
   commit subject, no body, no `Co-Authored-By`.
7. **Parked or blocked work becomes a Forgejo issue**, never only a journal bullet.

A rule that has to hold is enforced, not just written: `guard-destructive.sh` hard-blocks the
destructive verbs in both cluster repos regardless of permission mode. If you find yourself
reaching for a way around a guard, that is the signal to stop and hand the change back as a
commit — not to look for another route.

---

## Where everything else is

`.agents/instructions/` is loaded for you. `.agents/references/` is not — open one when its
trigger comes up.

### Always loaded

| File                           | What it settles                                     |
| ------------------------------ | --------------------------------------------------- |
| `instructions/tooling.md`      | `just` recipes, the MCP tiers, one-command-per-call |
| `instructions/commit-style.md` | The test-then-commit sequence and the signing model |
| `instructions/session.md`      | Journal format, memini vs `.agents/` boundary       |

### Loaded when you touch a matching path

| File                                  | Loads on               |
| ------------------------------------- | ---------------------- |
| `instructions/cluster-conventions.md` | `kubernetes/**`        |
| `instructions/yaml-conventions.md`    | `kubernetes/**/*.yaml` |

Both are `paths:`-scoped rules symlinked into `.claude/rules/`. If manifest field ordering or the
app-template conventions seem absent while you are editing a manifest, that scoping is why —
confirm the rule loaded before assuming the convention changed. opencode has no path scoping and
globs all five files unconditionally.

### Read on demand

Open the file when its subject comes up. Do not read the whole directory.

| Read this                    | When                                                                         |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `ansible.md`                 | Changing host config outside Kubernetes — TrueNAS, pantheon, Forgejo         |
| `anubis.md`                  | Adding or tuning PoW scraper deterrence on a public route                    |
| `app-structure.md`           | Choosing a directory shape for a new app, or wondering why one looks odd     |
| `arcade-eco.md`              | Anything touching the eco game server                                        |
| `bootstrap.md`               | Rebuilding the cluster from nothing, or editing a `.j2` template             |
| `claude-code-setup.md`       | Touching a hook, a guard, or a skill/subagent symlink                        |
| `cortex-mcp.md`              | An MCP server misbehaves, or you are adding one                              |
| `flux-patterns.md`           | A reconcile is stuck, or you are wiring `dependsOn` across namespaces        |
| `gpu.md`                     | Scheduling anything onto the Arc A380 or ymir's iGPU                         |
| `hardware.md`                | Sizing a workload, pinning to a node, buying a part, or an unexplained stall |
| `hermes.md`                  | Changing hermes-agent's model, skills, or chaski wiring                      |
| `identity-stack.md`          | Wiring SSO — lldap, Pocket-ID, tinyauth                                      |
| `issue-tracking.md`          | Filing the Forgejo issue that parked work becomes                            |
| `kopiur.md`                  | Backups and restores                                                         |
| `media-stack.md`             | The arr stack, cross-seed, download clients, zeroscaler                      |
| `memory-config.md`           | Editing `.mcp.json` tiers or memini plugin usage                             |
| `networking.md`              | Gateways, VLANs, CoreDNS, BGP, Multus — read before any RA or DNS change     |
| `observability.md`           | VictoriaMetrics, Grafana, ServiceMonitors, kromgo                            |
| `pantheon-networking.md`     | pantheon's vNIC/bridge — single-NIC blast radius, tap pps knee               |
| `pantheon-zfs.md`            | pantheon's ZFS pools, HBA bays, drive intake                                 |
| `pod-security-exceptions.md` | An app needs to deviate from the default security context                    |
| `postgres-dragonfly.md`      | Onboarding an app onto shared Postgres or Dragonfly                          |
| `renovate.md`                | Triaging the PR queue, or a per-app update guard                             |
| `scheduling.md`              | Packing, descheduler thresholds, cordoning a node                            |
| `storage.md`                 | StorageClasses, the NFS media mount, orphaned PVCs                           |
| `talos.md`                   | Node config, schematics, extensions, upgrades                                |
| `tekton-ci.md`               | The `oci-push` pipeline or a Tekton step                                     |
| `terraform.md`               | OpenTofu — the ownership boundary and import-first rule                      |
| `towonel-agent.md`           | Publishing a service through frostlink's tunnel on `edge-gateway`            |

### Skills and subagents

`ls .agents/skills/` and `ls .agents/agents/` are the catalogs. Both clients inject each one's
`name:` and `description:` themselves, so a table here would be a third copy that drifts — which
it did, twice, before this note replaced it.

A skill without frontmatter is invisible to auto-invocation. A skill without a
`.claude/skills/<name>` symlink is invisible to Claude Code; a subagent without a
`.claude/agents/<name>.md` symlink likewise. `just ai lint-agents` checks all of this.

Cluster-agnostic skills live in `~/.claude/skills/` and work everywhere: `forgejo`,
`triage-renovate`, `build-container`, `playwright`, `add-agent-content`.

---

## Writing docs in this repo

### The list rule

**A doc may carry a list only when it holds a fact a `grep` or `ls` cannot recover** — an
allocation, an intent, a rationale, or a historical correction. Anything a one-line command
answers must _be_ the command, not its output.

Keep, because the fact is not in the tree: the Dragonfly index registry (an index _claimed but
unconfigured_ exists nowhere else); the media port tables (they record which ports were
deliberately normalised and which were not); the app _role_ columns ("Prowlarr is the indexer
source of truth"); the hardware inventory (which SSD is in which box).

Delete, because the tree already answers it: which apps carry a component
(`grep -rln 'components/<name>' kubernetes/apps/`); how many apps carry it; which apps are on
shared Postgres or in a namespace; dated snapshot columns like key counts and live versions.

An outstanding action item is not a list at all — parked work becomes a Forgejo issue and the doc
links to it. A strikethrough TODO in a reference doc is the failure mode this rule exists to stop.

### Never restate a rule that lives in another file

Link to it and say which one wins. The duplicate is what drifts. This is not theoretical: a
sibling repo logged a wrong `Approve` on a PostgreSQL major-version upgrade because a copied
rule had drifted from its original.

### Make a version fact a command, not a number

`app-template` is bumped fleet-wide by Renovate. A doc that prints a tag is stale the week after
it is written. Print the command that recovers it instead —
`grep -h 'tag:' kubernetes/apps/*/*/app/ocirepository.yaml | sort | uniq -c | sort -rn | head -1`.

### Manifests carry configuration, not prose

No comments under `kubernetes/`. Rationale goes in a reference doc, where it is searchable and
does not have to be re-read on every manifest edit. The three machine-oriented exceptions are in
`yaml-conventions.md`.

---

## What was deliberately removed — do not resurrect it

`grep` cannot tell you that something is absent on purpose.

- **Rook-Ceph** — removed in `b9008ac55`. No `ceph-block`, no CephFS, no CephCluster CRD. The only
  StorageClasses are `miroir` and `miroir-local`.
- **SOPS** — fully removed. Never suggest age encryption.
- **Dedicated per-app Postgres** — immich was the last one, consolidated into the shared cluster
  on 2026-09-01. The silo-first policy was superseded on 2026-07-02.
- **VolSync** — replaced by kopiur. `ReplicationSource`/`ReplicationDestination` CRDs no longer
  exist.
- **Retired skills** (2026-08-21) — `cnpg-database` (merged into `deploy-app` +
  `postgres-dragonfly.md`), `migrate-namespace` (built on CRDs that are gone),
  `kopiur-pvc-migrate` (a completed one-shot migration).
- **`review-app`'s audit half** (2026-09-01) — the skill was doing a one-minute lint and a deep
  audit under one name, and the lint always finished first and reported PASS, so the audit never
  happened. `review-app` is now the lint only. **The audit moved to the `audit-app` subagent.**
