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
4. Update the table in `CLAUDE.md` under **Before Working on Manifests**

## Adding a Reference

1. Create `.agents/references/<topic>.md`
2. Use headers for logical sections; include runnable commands where relevant
3. Update the table in `AGENTS.md` under **Agent Instructions** (references sub-table)
4. Update the table in `CLAUDE.md` under **Before Working on Manifests** (references sub-table)
5. Add a pointer in `.agents/instructions/cluster-conventions.md` under **Topic References**
6. Update any skills that should load this reference to mention it in their intro

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
6. Update the table in `AGENTS.md` under **Skills**
7. Add a slash command redirect:

```bash
printf 'See `.agents/skills/<skill-name>/SKILL.md` for the full runbook.\n' \
  > .claude/commands/<skill-name>.md
```

## Commit Pattern

```bash
git add .agents/ .claude/commands/ AGENTS.md CLAUDE.md
git commit -m "chore(agents): add <name> skill/instruction/reference"
```

## Checklist

- [ ] File created in the correct location
- [ ] `AGENTS.md` table updated
- [ ] `CLAUDE.md` table updated (if instruction or reference)
- [ ] `cluster-conventions.md` Topic References table updated (if reference)
- [ ] Slash command redirect added (for skills only)
- [ ] Relevant skills updated to cite the new reference (if reference)
- [ ] Committed with `chore(agents):` prefix
