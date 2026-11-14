# Claude Code setup — home-infra

These mechanics have no opencode equivalent, so they stay out of the shared `.agents/` contract.
Read this file when you touch a hook, add a skill or subagent, or wonder why a guard did not fire.

- Hooks: `.claude/settings.json` wires `SessionStart` (git state injection),
  `PreToolUse:Bash` (destructive-command guard), and `PostToolUse:Edit|Write|MultiEdit` (manifest lint).
  The guards are generated, not hand-written.
  `.claude/hooks/guard-destructive.sh` and
  `.opencode/plugins/guard-destructive.js` are both emitted from `.claude/hooks/guard-rules.json`
  by `.claude/hooks/gen-guards.py`. Edit the rule table, then run
  `python3 .claude/hooks/gen-guards.py`. Pre-commit re-runs it with `--check`, so a hand-edit or a
  half-applied change fails the commit and does not ship. Both guards strip heredoc bodies before
  they match. A heredoc body is data, not a command. Matching it blocked the writing of docs that
  merely quoted a guarded command.
- A rule can carry a scoped `exempt` pattern. `kubectl-delete-critical` has one. A command that
  contains `I_HAVE_A_KOPIUR_SNAPSHOT` opts out of _that rule only_, so a planned PVC recreation
  can run without a blanket hole. Every other rule still fires, `talosctl reset/wipe` included.
  That is why this is a per-rule `exempt` and not an entry in the global `always_allow`. The
  procedure that it exists for is `.agents/skills/recreate-pvc/SKILL.md`. The marker is not a
  general-purpose override, and it means nothing without a verified snapshot. The rule matches the
  bare word `pvc`, so it also fires on unrelated objects _named_ `pvc-…` (a MiroirVolume, for
  example).
- The hooks are shared with frostlink. `session-context.sh`, `validate-manifest.sh`,
  `guard-rules.json` and `gen-guards.py` are vendored copies of
  `~/dotfiles/home/claude/agent-hooks/`. Push changes out with the `sync-hooks.sh` of that
  directory. Repo-specific rules carry a per-rule `"repos": [...]` field in `guard-rules.json`,
  and `.claude/hooks/guard-repo` names which set this repo emits.
- Skill symlinks: `.claude/skills/<name>` → `.agents/skills/<name>`. A new skill needs the
  symlink, or Claude Code cannot see it. opencode reads `.agents/skills/` directly.
- Subagent symlinks: `.claude/agents/<name>.md` → `.agents/agents/<name>.md`.
- Path-scoped rules: `.claude/rules/<name>.md` is a symlink to a file in
  `.agents/instructions/` that carries `paths:` frontmatter. Claude Code loads it only when it
  touches a matching file, so `cluster-conventions.md` (`clusters/artemis/kubernetes/**`) and `yaml-conventions.md`
  (`clusters/artemis/kubernetes/**/*.yaml`) stay out of the always-loaded set. A rule in `.claude/rules/` without
  `paths:` loads every session, which costs the same as an `@import`. So you wire an instruction
  file exactly one way, never both. opencode has no equivalent: `opencode.json` globs
  `.agents/instructions/*.md` and loads all five unconditionally, frontmatter and all.
- `just ai lint-agents` (`scripts/check-agent-config.py`) audits all of the above. It finds
  invalid frontmatter YAML, missing or dangling symlinks, skills and subagents without
  `name:`/`description:`/`mode:`, dangling `@imports`, an instruction file wired twice or not at
  all, a reference doc absent from the AGENTS.md index, an index row that names a file that does
  not exist, and an `opencode.json` instructions glob that matches nothing. It runs in the hk
  pre-commit hook on any `.agents/`, `.claude/`, `AGENTS.md`, `CLAUDE.md` or `opencode.json`
  change. The original check functions were mutation-tested. Someone broke them deliberately and
  confirmed that they fire. The frontmatter-YAML check has not been mutation-tested. The
  mutation test matters because a checker that crashes also exits non-zero and would otherwise
  look like a working gate.
- `just ai eval` (`scripts/eval-instructions.py`) is the behavioural counterpart to
  `lint-agents`. The lint proves that a file is _wired_. The eval proves that the wiring carries
  meaning. It assembles the real context that an agent gets: CLAUDE.md with `@` imports expanded
  recursively, plus the `paths:`-scoped rules that match the declared file of a case. It asks the
  questions in `.agents/evals/*.yaml` and scores the replies. `--ab <ref>` runs the same suite
  against a git ref and reports regressions. That is the only honest way to back a claim that a
  cut lost nothing important. The eval costs tokens, so it runs on demand and never in a hook.
  `--show-context` dumps what it built. `--show-replies` prints the reply behind each failure.

    The eval is built around two traps. The implementation that it was modelled on
    (ionfury/homelab `instruction-eval`) never loads a CLAUDE.md at all. It primes the model with
    a paraphrase that already contains the answers, so every constraint probe passes for the wrong
    reason. This eval refuses to run if the assembled context is under 6KB. The second trap is
    scoring `forbidden` by naive substring. That is wrong, because a correct answer usually has to
    name the thing to rule it out ("SOPS is fully removed", "no `git add .`"). The scorer counts
    only an _affirmative_ use, and it checks for negation on both sides of the match.
    `scripts/test-eval-scorer.py` pins both directions offline and runs in the hk pre-commit hook.

    A single run is noisy. Cases flip between runs of the same unchanged suite. `--runs N` takes a
    strict majority of N samples (an even split fails). Raise it for any `--ab` that you intend to
    act on. One FAIL at `--runs 1` is a prompt to read the reply with `--show-replies`, not a
    verdict.
