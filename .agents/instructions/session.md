# Session Notes — home-infra

Journal format and the memini and Stop-hook rules are in `~/.agents/AGENTS.md` § Memory. Only
what is specific to this repo lives here.

- The journal hooks are global (`~/.claude/settings.json`), not in this repo. A `PreCompact` hook
  trims the log to its newest 250 lines (one `.bak` kept). Do not prune by hand. After a
  compaction, a `SessionStart` `compact` hook re-injects only `## Current State`. Keep that
  section current.
- There is no staging cluster, so the reason for a live change matters more than usual. Record
  what you applied with `just kube apply-ks`, what the user confirmed, and anything left
  suspended.
- memini gets non-obvious operational discoveries: a quirk, a failure mode, or a workaround that
  would cost real time to re-derive. `.agents/` gets conventions, architecture and policy.
  Anything that a future agent must read _before_ it starts work belongs in a version-controlled
  instruction, reference or skill file, not in semantic memory.
