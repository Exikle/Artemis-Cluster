# Tooling & Critical Rules — Artemis-Cluster

Production GitOps homelab. Every push to `main` reconciles immediately to production via Flux.
**No staging cluster — test with `just kube apply-ks` before committing.**

This file is auto-loaded by every agent client (Claude Code via `CLAUDE.md`, opencode via
`opencode.json` → `instructions`). Anything both tools need goes here, not in a tool-specific file.

## Critical Rules

- **No SOPS** — secrets via 1Password ExternalSecret only (`ClusterSecretStore: onepassword-connect`)
- **No TZ env var** — k8tz handles timezone cluster-wide; never set `TZ` in pod specs
- **No shared OCIRepository** — every app gets its own standalone OCIRepository
- **No external hostnames for cluster traffic** — always `<app>.<namespace>.svc.cluster.local`
- **Routes in HelmRelease values** — `HTTPRoute` goes in helmrelease values, not standalone files
- **Test before commit** — `just kube apply-ks <ns> <ks>` then wait for explicit user confirmation
- **Resume Flux only after CI rebuilds the artifact** — `just kube resume-ks`, never before `Push Artifact` is green
- **No `git add .` or `git add -A`** — stage specific files by name only
- **Never apply cluster changes through MCP** — no `kubectl apply`, no MCP apply equivalent

## just commands

```bash
just kube apply-ks <ns> <ks>              # apply a Kustomization live (suspends flux first)
just kube resume-ks                       # resume everything suspended — children first, root last
                                          # REQUIRED after every apply-ks session
just kube sync <ocirepo|hr|ks|es>         # force-sync a Flux resource type
just kube render-local-ks <ns> <ks>       # validate with flate (offline, no cluster needed)
just kube snapshot                        # snapshot every kopiur SnapshotPolicy
just kube browse-pvc <ns> <pvc>           # browse a PVC interactively
just talos render-config <node>           # render Jinja2 node config
just talos apply-node <node>              # apply config live (no reboot)
```

Full recipe list: `bootstrap/mod.just`, `kubernetes/mod.just`.

## MCP servers

Three LiteLLM tiers plus memini. This repo's registrations are `.mcp.json` (Claude Code) and
`opencode.json` → `mcp` (opencode), but there are **five** across the machine and a tier change
means editing all of them — `.agents/references/memory-config.md` § Five registration files is
canonical for that list and for the per-tier auth. Per-server detail lives in
`.agents/references/cortex-mcp.md`.

| Server            | Capability                                                                                          |
| ----------------- | --------------------------------------------------------------------------------------------------- |
| `litellm-ops`     | k8s (pods, logs, exec, resources, events, scale), Flux (read-only), Forgejo, GitHub, Home Assistant |
| `litellm-general` | Grafana, SearXNG web search + URL fetch, VictoriaLogs (LogsQL), Context7 docs                       |
| `litellm-media`   | Sonarr / Radarr / Prowlarr, seerr (formerly Jellyseerr — the app and its tools are `seerr`)         |
| `memini`          | Cross-session semantic memory                                                                       |

**Tool names are prefixed differently per client** — Claude Code renders them as
`mcp__<server>__<tool>`, opencode as `<server>_<tool>`. Never hardcode a full tool name from
this file; list the available tools and match on the server + tool portion.

- Web lookups go through the SearXNG tools, never a built-in web-search tool
- Default kubeconfig context is `artemis`. Switch to Frostlink: `kubectx frostlink`
- Prefer the k8s MCP tools over shelling out to `kubectl` for read-only inspection

## Skills and subagents

Catalog with natural-language triggers: `AGENTS.md` § Skills and § Agents. Not duplicated here
— that table drifted out of sync with `.agents/skills/` twice before, so `AGENTS.md` is the
only place it is listed.

Both clients discover skills from `.agents/skills/<name>/SKILL.md` — Claude Code through the
`.claude/skills/<name>` symlinks, opencode natively. Subagents in `.agents/agents/<name>.md` are
symlinked into `.claude/agents/` and `.opencode/agents/` for the same reason.

### Subagents in this repo

When to spawn one at all is covered in the global agent context (`~/.claude/CLAUDE.md`
§ Subagents), why it is worth doing in § Context Economy, and where a subagent's findings should
be published in § Artifacts. None of that is repeated here. What is specific to Artemis:

- **Subagents here are read-only recon by default.** The Critical Rules above — test with
  `apply-ks` before committing, never commit until the user confirms the live deployment, never
  apply through MCP — all assume a human in the loop. A subagent has no way to get that
  confirmation, so it investigates and reports; you apply.
- **Say the safety rules in the prompt, every time.** A fresh agent does not inherit this file.
  If it must not commit, must not push, and must not run `just kube apply-ks`, the prompt has to
  say so in those words. "Follow the repo conventions" is not sufficient — it has not read them
  yet.
- **Parallel agents must own disjoint paths.** Artemis and frostlink are separate repos and can
  be worked in parallel safely. Two agents inside `.agents/` cannot — they will clobber each
  other's edits with no conflict and no error. Same for two agents under `kubernetes/`.
- Point an agent at ground truth, not at a doc: "verify every `sourceRef.kind` against
  `grep -r --include=ks.yaml kubernetes/`" beats "check whether the docs are stale". Most of the
  drift this repo has accumulated came from docs restating each other instead of the tree.

Catalog of the subagents defined here: `AGENTS.md` § Agents — same reason the skills catalog
lives there and not in this file.
