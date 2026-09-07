# Issue Tracking — Artemis-Cluster

**Work that is parked, blocked, or deferred becomes a Forgejo issue. It does not live only in
the session journal.**

The journal records what happened in a session. The issue tracker records what is still owed.
Those are different jobs, and the journal is the wrong place for the second one:

- `.claude/session-journal.md` is **gitignored and machine-local** — it does not survive a fresh
  clone, is invisible to any other machine, and no other agent or person can query it.
- It is **rewritten by a PreCompact hook**. On 2026-08-27 that hook cut it from 352,902 to 26,576
  bytes and destroyed every August entry, unrecoverably. Parked items recorded only as journal
  bullets were lost with it.
- A bullet cannot express a dependency, carry labels, or be filtered.

## When to file

File an issue the moment work is consciously **not** being finished:

| Situation                                | Label            |
| ---------------------------------------- | ---------------- |
| Known, deliberately not being worked on  | `status/parked`  |
| Cannot proceed until a dependency clears | `status/blocked` |

An issue with no `status/*` label is being actively worked. There is no `status/in-progress` —
it was on one issue in 55, and the board column already says the same thing.

If a real dependency exists, say what it is and make it a checklist item. `status/blocked` with
no stated blocker is just `status/parked` wearing a hat.

**Do not file** for: anything finished within the session, machine-local state (journal
formatting, scratch files), or a preference with no work attached. Those stay in the journal, or
in memini if they are a durable lesson.

## Labels are the state; the Project board is only a view

Forgejo **Projects has no REST API**. `/repos/{owner}/{repo}/projects`, `/orgs/{owner}/projects`
and `/projects` all return 404, `project` appears nowhere in the swagger spec, and the `-ops`
tier's Forgejo tools expose nothing for it either — the MCP wraps that same API. Column
automation does not exist either: a column has a title, a colour, and an optional "default"
flag, nothing more (forgejo/forgejo#773, open since 2023).

Consequences that matter:

- **No agent can read or write the board.** Never treat a card's column as the state of anything.
- **Labels are the only machine-readable truth.** Set them correctly even when the board looks right.
- Adding an issue to a board and moving its card are manual, human, web-UI actions.

Per-repo boards, not org-level. `frostlink` gets its own once the Artemis pilot proves out
(tracked as an issue in Artemis).

## Label taxonomy

Four axes, all queryable via the API. `.forgejo/labels.yaml` is the source of truth — the
labels-sync workflow **prunes**, so a label removed from that file is deleted server-side and
stripped from every issue and PR carrying it.

| Namespace   | Values                                                                                                                               | Notes                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| `kind/`     | `bug`, `feature`, `chore`, `debt`                                                                                                    | what sort of work it is                                                            |
| `status/`   | `parked`, `blocked`                                                                                                                  | absence means active                                                               |
| `area/`     | `agents`, `backup`, `ci`, `flux`, `home-automation`, `infra`, `kubernetes`, `media`, `network`, `observability`, `renovate`, `talos` | auto-applied on PRs by `.forgejo/labeler.yaml`; run `list_labels` for the live set |
| `priority/` | `high`                                                                                                                               | a flag, not a scale — absence means normal                                         |

`priority/` is one label on purpose. It carried `high`/`medium`/`low` until 2026-09-06, and
`medium` landed on 55% of labelled issues — the default value of a three-point scale carries no
information. `low` was indistinguishable from `status/parked`. **Parked does not mean
unimportant**: a parked item can still be `priority/high`.

Do not reuse `type/*` — Renovate owns it, on PRs only. There is no `renovate/*` namespace and no
`hold`/`hold/upstream`; use `status/blocked` for anything held on an upstream fix, our work or
Renovate's.

`area/*` is where the gaps show up. Two were added on 2026-08-28 (`area/agents` for
`.claude`/`.agents`/hooks work, `area/backup` for kopiur and restores) because the taxonomy had
nowhere to put real work. Add another rather than forcing a bad fit — but add it to
`.forgejo/labels.yaml`, and give it a glob in `.forgejo/labeler.yaml` if PRs should get it too.

`area/kubernetes` matches 81% of PRs and is deliberately kept: it is the fallback for app
namespaces with no glob of their own. It is not a useful filter on its own.

## Filing one

Use the `-ops` tier's Forgejo tools where they fit. Tool names carry a server prefix that changes
when the gateway is rewired — list the tools and match on the suffix rather than hardcoding a
fully-qualified name.

The REST API takes label **IDs**, not names, and those IDs differ per repo — always resolve them
rather than hardcoding:

```bash
TOKEN=$(op read 'op://artemis/forgejo/FORGEJO_ADMIN_TOKEN')
API=https://git.dcunha.io/api/v1
REPO=Exikle/Artemis-Cluster

# name -> id
curl -s "$API/repos/$REPO/labels?limit=100" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | "\(.id)\t\(.name)"' | sort -k2

# add labels to an existing issue
curl -s -X POST "$API/repos/$REPO/issues/<N>/labels" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"labels":[<id>,<id>]}'
```

Write the body so the next reader does not have to re-derive the investigation: state the
evidence, what was already ruled out, and the order of work. `#1700` is the model — it records
two corrections to its own first diagnosis specifically so nobody repeats them.

## Journal and tracker together

Both, not either:

- **Journal** — the narrative. What was done this session, what was applied live, what the user
  confirmed, what is left suspended. Session-scoped and disposable.
- **Issue** — the durable obligation. Survives the session, the machine, and the PreCompact hook.
- **memini** — the non-obvious lesson, so the next session does not re-derive it.

When a session parks something, the journal entry says so **and** names the issue number. When
an issue is filed, its number goes in the journal entry that created it. A journal bullet
describing parked work with no issue number is a bug in the process.
