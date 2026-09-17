# Artemis-Cluster — Claude Code entry point

This file is a pointer and nothing else. All shared agent context lives in `AGENTS.md` and
`.agents/`, so Claude Code and opencode read the same thing. Do not add cluster facts,
conventions or rules here.

@AGENTS.md

@.agents/instructions/tooling.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md

`cluster-conventions.md` and `yaml-conventions.md` are **not** imported here. They are
`paths:`-scoped rules symlinked into `.claude/rules/`, so they load only when Claude touches
`kubernetes/**` and `kubernetes/**/*.yaml` respectively. If a convention seems absent while you
are editing a manifest, that is why — check the rule loaded before assuming it changed.

Claude-Code-only mechanics — hooks, generated guards, skill and subagent symlinks — are in
`.agents/references/claude-code-setup.md`.
