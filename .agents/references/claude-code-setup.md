# Claude Code setup — Artemis-Cluster

Mechanics that have no opencode equivalent, so they stay out of the shared `.agents/` contract.
Read this when touching a hook, adding a skill or subagent, or wondering why a guard did not fire.

- **Hooks** — `.claude/settings.json` wires `SessionStart` (git state injection),
  `PreToolUse:Bash` (destructive-command guard), and `PostToolUse:Edit|Write` (manifest lint).
  **The guards are generated, not hand-written.** `.claude/hooks/guard-destructive.sh` and
  `.opencode/plugins/guard-destructive.js` are both emitted from `.claude/hooks/guard-rules.json`
  by `.claude/hooks/gen-guards.py` — edit the rule table, then run
  `python3 .claude/hooks/gen-guards.py`. Pre-commit re-runs it with `--check`, so a hand-edit or a
  half-applied change fails the commit rather than shipping. Both strip heredoc bodies before
  matching — a heredoc body is data, not a command, and matching it blocked writing docs that
  merely quoted a guarded command.
- **The hooks are shared with frostlink.** `session-context.sh`, `validate-manifest.sh`,
  `guard-rules.json` and `gen-guards.py` are vendored copies of
  `~/dotfiles/home/claude/agent-hooks/`; push changes out with that directory's `sync-hooks.sh`.
  Repo-specific rules live in `guard-rules.json` under a `repos:` key, and `.claude/hooks/guard-repo`
  names which set this repo emits.
- **Skill symlinks** — `.claude/skills/<name>` → `.agents/skills/<name>`. A new skill needs the
  symlink added or Claude Code cannot see it. opencode reads `.agents/skills/` directly.
- **Subagent symlinks** — `.claude/agents/<name>.md` → `.agents/agents/<name>.md`.
