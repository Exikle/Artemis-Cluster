# Artemis-Cluster — Agent Context

GitOps homelab Kubernetes cluster on Talos Linux, reconciled by Flux CD. This file is the entry
point for every AI agent that works here. It is short on purpose. It holds what is true on
every turn, and an index of where everything else is.

- Global rules (identity, commit hygiene, delegation, memory, Bash calls) load from
  `~/.agents/AGENTS.md` and `~/.agents/rules/` every session. This file does not restate them.
- Domain: `dcunha.io` | Repo: <https://git.dcunha.io/exikle/Artemis-Cluster>
- GitOps: Flux CD + Flux Operator | Secrets: 1Password ExternalSecret, no SOPS
- CNI: Cilium (BGP) | Ingress: Envoy Gateway (Gateway API / HTTPRoute)

`ls` at the repo root is the map. Flux reconciles only `kubernetes/`. Flux cannot see `terraform/`,
`ansible/` and `talos/`.

---

## The rules that apply to every turn

Everything else is conditional. These rules are not.

1. `main` is production. There is no staging cluster. Every push reconciles immediately.
   Suspend the root Kustomization and the target Kustomization. Run `just kube apply-ks`. Then
   wait for the user to confirm the live deployment before you commit. Suspend twice, not once.
   `apply-ks` suspends nothing, and a child that reconciles on its own interval silently reverts
   your edits.
2. Never apply cluster changes through an MCP tool. The MCP k8s tools are for read-only
   inspection. Writes go through git, or through `just kube apply-ks` during a test.
3. Secrets are 1Password ExternalSecrets (`ClusterSecretStore: onepassword-connect`). SOPS is
   fully removed. Never suggest age encryption or `sops --encrypt`.
4. Pods are dual-stack, but in practice they talk IPv4. Pods get a ULA IPv6 address beside
   IPv4. Services stay IPv4-only unless they opt in. CoreDNS answers every AAAA with NODATA,
   so pods only ever dial IPv4 by name. An `ENETUNREACH` on IPv6 means the address came from
   somewhere other than cluster DNS. `networking.md` § Dual-stack wins over this line.
5. Cluster traffic uses `<app>.<namespace>.svc.cluster.local`, never an external hostname.
6. Parked or blocked work becomes a Forgejo issue, never only a journal bullet.
7. Agents edit in a worktree, never the main checkout. Before the first edit, run
   `just wt new <type>/<slug>` (`feat`, `fix`, `chore`, … as in commit subjects). Work only in
   the `.worktrees/<type>-<slug>` path that it prints. One agent per worktree. Run
   `just wt rm <type>/<slug>` when the branch is merged. A pre-commit check refuses agent commits
   made in the main checkout.

The system enforces a rule that has to hold. It is not only written down. `guard-destructive.sh`
hard-blocks the destructive verbs in both cluster repos, whatever the permission mode. If you
reach for a way around a guard, stop. Hand the change back as a commit. Do not look for another
route.

---

## Where everything else is

The client loads `.agents/instructions/` for you. It does not load `.agents/references/`. Open
one when its trigger comes up.

### Always loaded

| File                           | What it settles                                     |
| ------------------------------ | --------------------------------------------------- |
| `instructions/tooling.md`      | `just` recipes, the MCP tiers, briefing subagents   |
| `instructions/commit-style.md` | The test-then-commit sequence and the signing model |
| `instructions/session.md`      | Journal hooks, memini vs `.agents/` boundary        |

### Loaded when you touch a matching path

| File                                  | Loads on               |
| ------------------------------------- | ---------------------- |
| `instructions/cluster-conventions.md` | `kubernetes/**`        |
| `instructions/yaml-conventions.md`    | `kubernetes/**/*.yaml` |

Both are `paths:`-scoped rules symlinked into `.claude/rules/`. If the manifest field ordering or
the app-template conventions seem absent while you edit a manifest, that scoping is the reason.
Make sure that the rule loaded before you assume the convention changed. opencode has no path
scoping and globs all five files unconditionally.

### Read on demand

Open the file when its subject comes up. Do not read the whole directory.

| Read this                    | When                                                                         |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `ansible.md`                 | Changing host config outside Kubernetes: TrueNAS, pantheon, Forgejo          |
| `app-structure.md`           | Choosing a directory shape for a new app, or wondering why one looks odd     |
| `bootstrap.md`               | Rebuilding the cluster from nothing, or editing a `.j2` template             |
| `ci.md`                      | A Forgejo workflow, the runner, buildkit, or the `oci-push` Flux artifact    |
| `claude-code-remote.md`      | The in-cluster Claude Code Remote Control pod: access, bootstrap, tools      |
| `claude-code-setup.md`       | Touching a hook, a guard, or a skill/subagent symlink                        |
| `cortex-mcp.md`              | An MCP server misbehaves, or you are adding one                              |
| `flux-patterns.md`           | A reconcile is stuck, or you are wiring `dependsOn` across namespaces        |
| `gpu.md`                     | Scheduling anything onto the Arc A380 or ymir's iGPU                         |
| `hardware.md`                | Sizing a workload, pinning to a node, buying a part, or an unexplained stall |
| `hermes.md`                  | Changing hermes-agent's model, skills, or chaski wiring                      |
| `identity-stack.md`          | Wiring SSO: lldap, Pocket-ID, tinyauth                                       |
| `issue-tracking.md`          | Filing the Forgejo issue that parked work becomes                            |
| `kopiur.md`                  | Backups and restores                                                         |
| `media-stack.md`             | The arr stack, cross-seed, download clients, zeroscaler                      |
| `memory-config.md`           | Editing `.mcp.json` tiers or memini plugin usage                             |
| `networking.md`              | Gateways, VLANs, CoreDNS, BGP, Multus: read before any RA or DNS change      |
| `observability.md`           | VictoriaMetrics, Grafana, ServiceMonitors, kromgo                            |
| `pantheon-networking.md`     | pantheon's vNIC/bridge: single-NIC blast radius, tap pps knee                |
| `pantheon-zfs.md`            | pantheon's ZFS pools, HBA bays, drive intake                                 |
| `pod-security-exceptions.md` | An app needs to deviate from the default security context                    |
| `postgres-dragonfly.md`      | Onboarding an app onto shared Postgres or Dragonfly                          |
| `renovate.md`                | Triaging the PR queue, or a per-app update guard                             |
| `scheduling.md`              | Packing, descheduler thresholds, cordoning a node                            |
| `storage.md`                 | StorageClasses, the NFS media mount, orphaned PVCs                           |
| `talos.md`                   | Node config, schematics, extensions, upgrades                                |
| `terraform.md`               | OpenTofu: the ownership boundary and import-first rule                       |
| `towonel-agent.md`           | Publishing any public service (either domain) on `edge-gateway` via towonel  |

### Skills and subagents

`ls .agents/skills/` and `ls .agents/agents/` are the catalogs. Both clients inject the `name:`
and `description:` of each one themselves. A table here would be a third copy that drifts. It
drifted twice before this note replaced it.

Auto-invocation cannot see a skill without frontmatter. Claude Code cannot see a skill without a
`.claude/skills/<name>` symlink. It also cannot see a subagent without a
`.claude/agents/<name>.md` symlink. `just ai lint-agents` checks all of this.

Cluster-agnostic skills live in `~/.claude/skills/` and work everywhere: `forgejo`,
`triage-renovate`, `build-container`, `playwright`, `add-agent-content`, `simple-english`.

---

## Writing docs in this repo

### Plain English

Load the `simple-english` skill before you write a new markdown file or change an existing one.
This covers `README.md` files, `AGENTS.md`, everything in `.agents/`, and the markdown that the
Hermes and Claude Code pods mount. Write the new text in the style of the skill. Do not rewrite
the parts of a file that you did not need to change.

The skill never changes code, commands, identifiers, paths, quoted errors or facts. A skill
description in frontmatter stays on one line. It can use an em-dash, because `just ai lint-agents`
rejects a colon followed by a space in that value.

### The list rule

A doc may carry a list only when the list holds a fact that a `grep` or `ls` cannot recover. Such
a fact is an allocation, an intent, a rationale, or a historical correction. If a one-line
command answers the question, the doc must give the command, not its output.

Keep these, because the fact is not in the tree:

- The Dragonfly index registry. An index that is _claimed but unconfigured_ exists nowhere else.
- The media port tables. They record which ports were deliberately normalised and which were not.
- The app _role_ columns ("Prowlarr is the indexer source of truth").
- The hardware inventory (which SSD is in which box).

Delete these, because the tree already answers the question:

- Which apps carry a component (`grep -rln 'components/<name>' kubernetes/apps/`).
- How many apps carry it.
- Which apps are on shared Postgres or in a namespace.
- Dated snapshot columns, such as key counts and live versions.

An outstanding action item is not a list at all. Parked work becomes a Forgejo issue, and the doc
links to it. A strikethrough TODO in a reference doc is the failure that this rule exists to stop.

### Never restate a rule that lives in another file

Link to it and say which one wins. The duplicate is what drifts. This risk is real. A sibling
repo logged a wrong `Approve` on a PostgreSQL major-version upgrade because a copied rule had
drifted from its original.

### Make a version fact a command, not a number

Renovate bumps `app-template` across the whole fleet. A doc that prints a tag is stale the week
after the doc is written. Print the command that recovers the tag instead:
`grep -h 'tag:' kubernetes/apps/*/*/app/ocirepository.yaml | sort | uniq -c | sort -rn | head -1`.

### Manifests carry configuration, not prose

No comments under `kubernetes/`. Rationale goes in a reference doc. There it is searchable, and
no one must re-read it on every manifest edit. The three machine-oriented exceptions are in
`yaml-conventions.md`.

---

## What was deliberately removed — do not resurrect it

`grep` cannot tell you that something is absent on purpose.

- Rook-Ceph: removed in `b9008ac55`. There is no `ceph-block`, no CephFS, and no CephCluster CRD.
  The only StorageClasses are `miroir` (the cluster default, 2 replicas, use this one) and
  `miroir-local` (1 replica, for kopiur caches and staging clones only). Both are RWO. Neither
  offers RWX. If you pick `miroir-local` for the data of an app, the data is unreplicated.
- SOPS: fully removed. Never suggest age encryption.
- Dedicated per-app Postgres: immich was the last one. It moved into the shared cluster on
  2026-09-01. The silo-first policy was superseded on 2026-07-02.
- VolSync: replaced by kopiur. The `ReplicationSource` and `ReplicationDestination` CRDs no longer
  exist.
- Retired skills (2026-08-21): `cnpg-database` (merged into `deploy-app` +
  `postgres-dragonfly.md`), `migrate-namespace` (built on CRDs that are gone), and
  `kopiur-pvc-migrate` (a completed one-shot migration).
- The audit half of `review-app` (2026-09-01): the skill did a one-minute lint and a deep audit
  under one name. The lint always finished first and reported PASS, so the audit never ran.
  `review-app` is now the lint only. The audit moved to the `audit-app` subagent.
