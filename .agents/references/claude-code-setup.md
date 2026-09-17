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
- **A rule may carry a scoped `exempt` pattern.** `kubectl-delete-critical` has one: a command
  containing `I_HAVE_A_KOPIUR_SNAPSHOT` opts out of _that rule only_, so a planned PVC recreation
  can run without a blanket hole. Every other rule — `talosctl reset/wipe` included — still fires,
  which is why this is a per-rule `exempt` and not an entry in the global `always_allow`. The
  procedure it exists for is `.agents/skills/recreate-pvc/SKILL.md`; the marker is not a
  general-purpose override and means nothing without a verified snapshot. Note the rule matches the
  bare word `pvc`, so it also fires on unrelated objects _named_ `pvc-…` (a MiroirVolume, say).
- **The hooks are shared with frostlink.** `session-context.sh`, `validate-manifest.sh`,
  `guard-rules.json` and `gen-guards.py` are vendored copies of
  `~/dotfiles/home/claude/agent-hooks/`; push changes out with that directory's `sync-hooks.sh`.
  Repo-specific rules live in `guard-rules.json` under a `repos:` key, and `.claude/hooks/guard-repo`
  names which set this repo emits.
- **Skill symlinks** — `.claude/skills/<name>` → `.agents/skills/<name>`. A new skill needs the
  symlink added or Claude Code cannot see it. opencode reads `.agents/skills/` directly.
- **Subagent symlinks** — `.claude/agents/<name>.md` → `.agents/agents/<name>.md`.
- **Path-scoped rules** — `.claude/rules/<name>.md` is a symlink to a file in
  `.agents/instructions/` that carries `paths:` frontmatter. Claude Code loads it only when it
  touches a matching file, so `cluster-conventions.md` (`kubernetes/**`) and `yaml-conventions.md`
  (`kubernetes/**/*.yaml`) stay out of the always-loaded set. A rule in `.claude/rules/` **without**
  `paths:` loads every session, which is the same cost as an `@import` — so an instruction file is
  wired exactly one way, never both. **opencode has no equivalent**: `opencode.json` globs
  `.agents/instructions/*.md` and loads all five unconditionally, frontmatter and all.
- **`just ai lint-agents`** (`scripts/check-agent-config.py`) audits all of the above — missing or
  dangling symlinks, skills and subagents without `name:`/`description:`/`mode:`, dangling
  `@imports`, an instruction file wired twice or not at all, a reference doc absent from the
  AGENTS.md index, an index row naming a file that does not exist, and an `opencode.json`
  instructions glob that matches nothing. It runs in lefthook on any `.agents/`, `.claude/`,
  `AGENTS.md`, `CLAUDE.md` or `opencode.json` change. Each of its nine checks was mutation-tested
  — broken deliberately, confirmed to fire — because a checker that crashes also exits non-zero
  and would otherwise look like a working gate.
- **`just ai eval`** (`scripts/eval-instructions.py`) is the behavioural counterpart to
  `lint-agents`: the lint proves a file is _wired_, the eval proves the wiring carries meaning. It
  assembles the real context an agent gets — CLAUDE.md with `@` imports expanded recursively, plus
  the `paths:`-scoped rules matching a case's declared file — asks the questions in
  `.agents/evals/*.yaml`, and scores the replies. **`--ab <ref>`** runs the same suite against a git
  ref and reports regressions, which is the only honest way to back a claim like "I cut 238 lines
  and nothing important went missing". It costs tokens, so it is on demand and never in a hook.
  `--show-context` dumps what it built; `--show-replies` prints the reply behind each failure.

    Two traps it is built around. The implementation this was modelled on
    (ionfury/homelab `instruction-eval`) never loads a CLAUDE.md at all — it primes the model with
    a paraphrase that already contains the answers, so every constraint probe passes for the wrong
    reason; this one refuses to run if the assembled context is under 6KB. And scoring `forbidden`
    by naive substring is wrong, because a correct answer usually has to name the thing to rule it
    out ("SOPS is fully removed", "no `git add .`") — the scorer only counts an _affirmative_ use,
    checking for negation on both sides of the match. `scripts/test-eval-scorer.py` pins both
    directions offline and runs in lefthook.

    **A single run is noisy** — three cases flipped between two runs of the same unchanged
    suite. `--runs N` takes a strict majority of N samples (an even split fails); raise it for
    any `--ab` you intend to act on. One FAIL at `--runs 1` is a prompt to read the reply with
    `--show-replies`, not a verdict.
