# Artemis-Cluster — Claude Context

This file is a pointer. All shared agent context lives in `AGENTS.md` and `.agents/`, so that
Claude Code and opencode read the same thing. Do not add cluster facts, conventions, or rules
here — put them in `.agents/instructions/` (always loaded) or `.agents/references/` (on demand).

> **Cluster facts, hardware, namespaces, skills catalog, references index**: `AGENTS.md` — read it first, it is canonical.

@AGENTS.md

## Always-Loaded Instructions

@.agents/instructions/tooling.md
@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md
@.agents/instructions/issue-tracking.md

## Claude Code specifics

Behaviour that has no opencode equivalent and therefore stays out of `.agents/`:

- **Hooks** — `.claude/settings.json` wires `SessionStart` (git state injection),
  `PreToolUse:Bash` (destructive-command guard), and `PostToolUse:Edit|Write` (manifest lint).
  opencode gets the same guard via `.opencode/plugins/guard-destructive.js`; if you change one,
  change the other. Both strip heredoc bodies before matching — a heredoc body is data, not a
  command, and matching it blocked writing docs that merely quoted a guarded command.
- **Skill symlinks** — `.claude/skills/<name>` → `.agents/skills/<name>`. A new skill needs the
  symlink added or Claude Code cannot see it. opencode reads `.agents/skills/` directly.
- **Subagent symlinks** — `.claude/agents/<name>.md` → `.agents/agents/<name>.md`.
