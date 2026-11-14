# home-infra — Claude Code entry point

This file is a pointer and nothing else. All shared agent context lives in `AGENTS.md` and
`.agents/`, so Claude Code and opencode read the same thing. Do not add cluster facts,
conventions or rules here.

@AGENTS.md

@.agents/instructions/tooling.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md

This file does not import `cluster-conventions.md` and `yaml-conventions.md`. They are
`paths:`-scoped rules symlinked into `.claude/rules/`. They load only when Claude touches
`clusters/artemis/kubernetes/**` and `clusters/artemis/kubernetes/**/*.yaml` respectively. If a convention seems absent while you
edit a manifest, that is the reason. Make sure that the rule loaded before you assume it changed.

The Claude-Code-only mechanics are in `.agents/references/claude-code-setup.md`. They are the
hooks, the generated guards, and the skill and subagent symlinks.
