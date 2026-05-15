# Skill: Add Agent Instructions or Skills

How to add new instructions or skills to the `.agents/` system in this repo.

## When to add an instruction vs. a skill

| Type                                          | Use when                                                                                                                                          |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Instruction** (`.agents/instructions/*.md`) | Always-relevant rules or conventions — patterns that apply to most work in this repo (e.g. how to write manifests, commit style, secrets pattern) |
| **Skill** (`.agents/skills/<name>/SKILL.md`)  | A repeatable multi-step task with a clear trigger (e.g. "deploy an app", "restore a PVC", "fix a stuck HelmRelease")                              |

## Adding a New Instruction

1. Create `.agents/instructions/<topic>.md`
2. Keep it focused — one topic per file
3. Lead with the most important rule; put reference tables and examples after
4. Update the table in `AGENTS.md` under **Agent Instructions**:
    ```markdown
    | `<topic>.md` | One-line summary of what it covers |
    ```

## Adding a New Skill

1. Create `.agents/skills/<skill-name>/SKILL.md`
2. Structure:

    ```markdown
    # Skill: <Human Name>

    One-sentence description of what this skill does.

    ## Step 1 — <First Step>

    ...

    ## Common Issues / Gotchas

    ...
    ```

3. Lead with gather/confirm — don't assume inputs
4. Include runnable commands with actual flags, not pseudocode
5. End with a Gotchas section for known failure modes
6. Update the table in `AGENTS.md` under **Skills**:
    ```markdown
    | `<skill-name>/SKILL.md` | "trigger phrase the agent should match" |
    ```

## Updating the Slash Command Redirect

`.claude/commands/` has thin redirect files that point to skills. Add one if you want `/skill-name` to work as a Claude Code slash command:

```bash
printf 'See `.agents/skills/<skill-name>/SKILL.md` for the full runbook.\n' \
  > .claude/commands/<skill-name>.md
```

Then stage and commit it alongside the skill.

## Commit Pattern

```bash
git add .agents/ .claude/commands/ AGENTS.md
PATH="$HOME/.local/share/mise/shims:$PATH" git commit -m "chore(agents): add <name> skill/instruction"
```

## Checklist

- [ ] File created in the right location
- [ ] AGENTS.md table updated
- [ ] Slash command redirect added (for skills)
- [ ] Committed with `chore(agents):` prefix
