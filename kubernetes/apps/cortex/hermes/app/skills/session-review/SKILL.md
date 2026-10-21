---
name: session-review
description: "Review a prior AI session (transcript file or pasted text), save what matters to memini, and give next steps. Use for 'review the transcript', 'catch me up on session X', 'what landed', 'pick up where we left off', 'save what you understand to memini'. Not for plain summaries or diff review."
---

# Review a prior session

Not a summary. He lived the session. Give judgment, save the state, list next steps.

## Read it fast

1. Last 200-500 lines: end state, open questions.
2. First 50-200 lines: the goal.
3. `grep -n` for: commit SHAs, error strings, "decision", "agreed", "don't", "TODO", "follow-up".
4. Read the middle only around those hits.
5. Session journal only (`.claude/session-journal.md`)? Read `## Current State`, the last 3-5 log entries, any `## Open`.

## Save first (same turn as the review)

3-5 `memory_remember` calls. One fact each, `tier` set:

- State: commits, what is deployed, what is left suspended or open. (`semantic`)
- Open defects: exact object and error text. (`semantic`)
- Lessons a later session would re-derive the hard way. (`procedural`)
- Decisions and why. (`semantic`)

Do not save: diffs, transcript lines, "we discussed X", secrets. Verify "committed/applied" claims against the repo or cluster before saving them as true. If unverified, say so in the memory.

## Output, in this order

1. **Landed cleanly.** 3-6 bullets. Each cites a concrete artifact (SHA, log line, path).
2. **Pushback.** Numbered. Each: what is wrong, why, what to do instead. Order: missed or mislabelled defects, symptom fixed instead of the shared component, noted-but-not-chased smells, process problems. If the session was clean, say so. Do not invent objections.
3. **Next steps.** 5-7 max, ranked by leverage. Each: the change, the file or object, how he verifies it. Extras go in a "watch list" line.

Keep it shorter than the transcript. Follow `adhd-friendly-communication`.

## Rules

- Do not re-run the session's steps. Review only.
- Do not invent next steps outside what the session was doing.
- Do not praise the prior agent to soften pushback.
- Do not create or patch skills during a review. List proposed skill changes as a next step.
- Cannot write to the repo? Say so once. Give exact new file contents as a proposal, plus what you would not change.
- Asked "should I stop using you?": do not give an opinion. Propose a small bounded test, a fixed window and a metric.
- Note where the transcript file lives so a later session can find it.
