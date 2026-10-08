# Session Notes — Artemis-Cluster

Journal format and the memini and Stop-hook rules are in `~/.agents/AGENTS.md` § Memory. Only
what is specific to this repo lives here.

- The journal hooks are global (`~/.claude/settings.json`), not in this repo. A `PreCompact` hook
  trims the log to its newest 250 lines (one `.bak` kept) — do not prune by hand. After a
  compaction, a `SessionStart` `compact` hook re-injects only `## Current State`, so keep that
  section current.
- **Because there is no staging cluster, the WHY behind a live change matters more than usual.**
  Record what was applied with `just kube apply-ks`, what the user confirmed, and anything left
  suspended.
- **memini** gets non-obvious operational discoveries — a quirk, a failure mode, a workaround
  that would cost real time to re-derive. **`.agents/`** gets conventions, architecture and
  policy: anything a future agent should read _before_ starting work belongs in a version-
  controlled instruction, reference or skill file, not in semantic memory.
