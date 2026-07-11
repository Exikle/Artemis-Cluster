# Skill: Add Agent Instructions, References, or Skills

How to add new content to the `.agents/` system in this repo.

## Three-Tier Structure

| Type            | Location                         | Use when                                                                                           |
| --------------- | -------------------------------- | -------------------------------------------------------------------------------------------------- |
| **Instruction** | `.agents/instructions/*.md`      | Always-relevant rules that apply to most work (YAML conventions, commit style, secrets pattern)    |
| **Reference**   | `.agents/references/*.md`        | Topic-specific patterns loaded on demand by skills (Flux gotchas, storage rules, networking)       |
| **Skill**       | `.agents/skills/<name>/SKILL.md` | A repeatable multi-step task with a clear trigger (deploy app, restore PVC, fix stuck HelmRelease) |

## Adding an Instruction

1. Create `.agents/instructions/<topic>.md`
2. Keep it focused — one topic per file; lead with the most important rule
3. Update the table in `AGENTS.md` under **Agent Instructions**

`AGENTS.md` is the only place this catalog is listed — `CLAUDE.md` just points to it, to avoid the two tables drifting apart.

## Adding a Reference

1. Create `.agents/references/<topic>.md`
2. Use headers for logical sections; include runnable commands where relevant
3. Update the table in `AGENTS.md` under **Agent Instructions** (references sub-table)
4. Add a pointer in `.agents/instructions/cluster-conventions.md` under **Topic References**
5. Update any skills that should load this reference to mention it in their intro

## Adding a Skill

1. Create `.agents/skills/<skill-name>/SKILL.md` using this structure:

```markdown
# Skill: <Human Name>

One-sentence description of what this skill does.

> Read `.agents/references/<relevant>.md` before proceeding.

## Step 1 — Confirm / Gather Requirements

...

## Common Issues / Gotchas

...
```

2. Lead with gather/confirm — don't assume inputs
3. Cite specific reference files the skill should read (add `> Read ...` note at top)
4. Include runnable commands with actual flags, not pseudocode
5. End with a Gotchas section for known failure modes
6. Update the table in `AGENTS.md` under **Skills** (the only skills catalog — `CLAUDE.md` points to it)
7. Add a slash command redirect:

```bash
printf 'See `.agents/skills/<skill-name>/SKILL.md` for the full runbook.\n' \
  > .claude/commands/<skill-name>.md
```

## CLAUDE.local.md — Local Persistent Context

Claude Code reads both `CLAUDE.md` (committed) and `CLAUDE.local.md` (gitignored, machine-local).

Use `CLAUDE.local.md` in the repo root for working notes that should persist across compaction but never be committed — for example, kubectl commands for an app you're actively debugging, temporary workflow notes, or in-progress investigation context.

```bash
# Create a local context file (already gitignored by .gitignore's .claude/* rule if in .claude/)
# For repo-root CLAUDE.local.md, add it to .gitignore if not already there
echo "CLAUDE.local.md" >> .gitignore
```

Example content:

```markdown
# Persistent Context (survives compaction)

## <App> Debugging

kubectl exec -it -n <ns> deploy/<app> -- bash
kubectl logs -n <ns> -l app.kubernetes.io/name=<app> --tail=100
```

This file is NOT a substitute for `.agents/` — it's for ephemeral working state, not permanent runbooks.

## Maintaining Memory & MCP Config

> Read `.agents/references/memory-config.md` for the full explanation.

`.mcp.json` (repo root) registers the litellm MCP tiers — update it when a tier is added, renamed, or its URL changes. `memini` (cross-session memory) is a Claude Code plugin, not repo config; there's nothing to update in this repo when its behavior changes.

Config changes belong in the commit alongside the changes that motivated them.

---

## Commit Pattern

```bash
git add .agents/<path-to-changed-files> .claude/commands/ AGENTS.md CLAUDE.md
git commit -m "chore(agents): add <name> skill/instruction/reference"
```

## Checklist

- [ ] File created in the correct location
- [ ] `AGENTS.md` table updated
- [ ] `cluster-conventions.md` Topic References table updated (if reference)
- [ ] Slash command redirect added (for skills only)
- [ ] Relevant skills updated to cite the new reference (if reference)
- [ ] Committed with `chore(agents):` prefix
