# Artemis-Cluster — Claude Context

This file is a pointer, and nothing else. All shared agent context lives in `AGENTS.md` and
`.agents/`, so Claude Code and opencode read the same thing. Do not add cluster facts,
conventions or rules here — they go in `.agents/instructions/` (always loaded) or
`.agents/references/` (on demand). Claude-Code-only mechanics — hooks, the generated guards, the
skill and subagent symlinks — are in `.agents/references/claude-code-setup.md`.

@AGENTS.md

Manifest field ordering is NOT imported here. It is a path-scoped rule
(`.claude/rules/yaml-conventions.md`, a symlink to the same file opencode globs) that loads only
when Claude touches `kubernetes/**/*.yaml`. If ordering guidance ever seems absent while editing a
manifest, that rule is why — check it loaded before assuming the convention changed.

@.agents/instructions/tooling.md
@.agents/instructions/cluster-conventions.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md
