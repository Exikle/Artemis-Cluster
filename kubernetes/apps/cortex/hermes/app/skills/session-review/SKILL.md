---
name: session-review
description: "Review a prior AI session (transcript file or pasted text), save what matters to memini, and give next steps. Use for 'review the transcript', 'catch me up on session X', 'what landed', 'pick up where we left off', 'save what you understand to memini'. Not for plain summaries or diff review."
---

# Review a prior session

This is not a summary, because he lived the session. Give judgment, save the state, and list next steps.

## Read it fast

1. Last 200-500 lines: end state, open questions.
2. First 50-200 lines: the goal.
3. `grep -n` for: commit SHAs, error strings, "decision", "agreed", "don't", "TODO", "follow-up".
4. Read the middle only around those hits.
5. If the input is only the session journal (`.claude/session-journal.md`), read `## Current State`, the last 3-5 log entries, and any `## Open`.

## Save first (same turn as the review)

3-5 `memory_remember` calls. One fact each, `tier` set:

- State: commits, what is deployed, what is left suspended or open. (`semantic`)
- Open defects: exact object and error text. (`semantic`)
- Lessons a later session would re-derive the hard way. (`procedural`)
- Decisions and why. (`semantic`)

Do not save: diffs, transcript lines, "we discussed X", secrets. Before you save a "committed" or "applied" claim as true, make sure that the repo or cluster confirms it. If it is unverified, say so in the memory.

## Output, in this order

1. Landed cleanly: 3-6 bullets. Each cites a concrete artifact (SHA, log line, path).
2. Pushback: numbered. Each item gives what is wrong, why, and what to do instead. Order: missed or mislabelled defects, symptom fixed instead of the shared component, noted-but-not-chased smells, process problems. If the session was clean, say so. Do not invent objections.
3. Next steps: 5-7 at most, ranked by leverage. Each item gives the change, the file or object, and how he verifies it. Extras go in a "watch list" line.

Keep it shorter than the transcript. Follow `adhd-friendly-communication`.

## Rules

- Do not re-run the session's steps. Review only.
- Do not invent next steps outside what the session was doing.
- Do not praise the prior agent to soften pushback.
- Do not create or patch skills during a review. List proposed skill changes as a next step.
- If you cannot write to the repo, say so once. Give the exact new file contents as a proposal, plus what you would not change.
- If he asks "should I stop using you?", do not give an opinion. Propose a small bounded test, a fixed window, and a metric.
- Note where the transcript file is, so that a later session can find it.
