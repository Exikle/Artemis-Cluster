# Session Journal — Artemis-Cluster

The file `.claude/session-journal.md` persists across context compactions. Write to it so the
next context window can resume without losing track of what was happening.

## When to Write an Entry

- A plan or approach is agreed with the user
- Work starts on a distinct task or scope
- A piece of work completes (commit made, app deployed, issue resolved)
- A key decision is made — especially the WHY
- Hitting a blocker or dead end
- Before context is likely to compact (long debugging session, multi-step deploy)

## Entry Format

```
### YYYY-MM-DD HH:MM — Type: brief title
- What happened and why (2–4 bullets)
- Key detail a future Claude needs to continue
- Files changed, commands run, decisions made
```

Types: `Plan`, `Started`, `Completed`, `Decision`, `Blocked`, `Context`

## Current State Block

Always update the `## Current State` block when focus changes:

```markdown
## Current State

- **Focus:** deploying paperless-ngx in media namespace
- **Blocked:** nothing
```

## Rules

- Entries are append-only, newest first under `## Log`
- Include the WHY, not just the what — "used emptyDir because readOnlyRootFilesystem blocks /tmp writes" beats "added emptyDir"
- Keep entries short — 2–4 bullets each
- The PreCompact hook trims old entries automatically; don't worry about length

## memini — Lessons

`mcp__memini__*` tools store short lessons that persist across sessions with semantic search + reranking.

**Load**: when starting work on a distinct topic or component, call `memory_recall` or `memory_answer` with relevant keywords (e.g. `"toolhive mcp"`, `"rook ceph recovery"`, `"flux helmrelease"`). Skip if the topic is trivial or already covered by file-based memory.

**Save**: after any non-obvious discovery — a quirk, a failure mode, a workaround — call `memory_remember`. Good candidates:

- An unexpected API behaviour or field requirement
- A command/flag that fixed a recurring problem
- Something that would take >5 minutes to re-derive next time

Bad candidates (use file-based memory instead): conventions, architecture, project context, anything already in `.agents/` files.

Keep lessons short — one sentence of fact + one sentence of why/how.
