# Artemis-Cluster — Claude Context

This file is a pointer, and nothing else. All shared agent context lives in `AGENTS.md` and
`.agents/`, so Claude Code and opencode read the same thing. Do not add cluster facts,
conventions or rules here — they go in `.agents/instructions/` (always loaded) or
`.agents/references/` (on demand). Claude-Code-only mechanics — hooks, the generated guards, the
skill and subagent symlinks — are in `.agents/references/claude-code-setup.md`.

@AGENTS.md

@.agents/instructions/tooling.md
@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md
