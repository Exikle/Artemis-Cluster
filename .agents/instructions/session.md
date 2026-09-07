# Session Journal — Artemis-Cluster

The journal format, the trigger list for when to write an entry, the entry template, and the
`## Current State` convention are defined once in the global agent context (`~/.claude/CLAUDE.md`,
symlinked to `~/.config/opencode/AGENTS.md`). They are not repeated here.

This file records only what is specific to this repo.

## Repo specifics

- The journal is `.claude/session-journal.md`. It is **gitignored** — it never leaves this machine,
  so it can hold detail that would be inappropriate in a public commit message.
- A `PreCompact` hook trims old entries automatically. Do not manually prune for length.
- A `Stop` hook checks that commits made during a session are reflected in the journal, and will
  block on exit if they are not. If it reports commits you did not make, verify with
  `git log` before writing — it counts every commit in the window, including the user's own.
- Because there is no staging cluster, the WHY behind a live-cluster change matters more than
  usual. Record what was applied with `just kube apply-ks`, what the user confirmed, and anything
  left suspended.

## Parked work goes to the tracker, not here

The journal is gitignored, machine-local, and rewritten by a PreCompact hook — on 2026-08-27 that
hook destroyed every August entry. Anything consciously left unfinished must become a Forgejo
issue with `kind/*`, `area/*` and, where they apply, `status/*` and `priority/high` labels; the
journal entry then names the issue number. See `issue-tracking.md`.

## memini — lessons

Load and save rules are in the global context. The repo-specific split:

- **memini** gets non-obvious operational discoveries — a quirk, a failure mode, a workaround that
  would cost real time to re-derive.
- **`.agents/`** gets conventions, architecture, and policy. Anything a future agent should read
  _before_ starting work belongs in an instruction, reference, or skill file, where it is
  version-controlled and reviewable — not in semantic memory.
