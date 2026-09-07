# Session Notes — Artemis-Cluster

Journal format, when to write, and the memini rules are in the global agent context
(`~/.claude/CLAUDE.md` § Memory). Only what is specific to this repo lives here.

- The journal is `.claude/session-journal.md`, gitignored. A `PreCompact` hook trims it — do not
  prune by hand. A `Stop` hook blocks on exit if commits are not reflected; if it names commits
  you did not make, check `git log` first, because it counts the user's own.
- **Because there is no staging cluster, the WHY behind a live change matters more than usual.**
  Record what was applied with `just kube apply-ks`, what the user confirmed, and anything left
  suspended.
- **memini** gets non-obvious operational discoveries — a quirk, a failure mode, a workaround
  that would cost real time to re-derive. **`.agents/`** gets conventions, architecture and
  policy: anything a future agent should read _before_ starting work belongs in a version-
  controlled instruction, reference or skill file, not in semantic memory.
