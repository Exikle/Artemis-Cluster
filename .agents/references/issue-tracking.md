# Issue Tracking — Artemis-Cluster

Work that is parked, blocked, or deferred becomes a Forgejo issue. It does not live only in the
session journal.

The journal records what happened in a session. The issue tracker records what is still owed.
Those are different jobs, and the journal is the wrong place for the second one:

- `.claude/session-journal.md` is gitignored and machine-local. It does not survive a fresh
  clone, no other machine can see it, and no other agent or person can query it.
- A PreCompact hook rewrites it, and that hook has destroyed entries unrecoverably. Parked
  items recorded only as journal bullets were lost with it.
- A bullet cannot express a dependency, carry labels, or be filtered.

## When to file

File an issue at the moment you consciously decide not to finish the work:

| Situation                                | Label            |
| ---------------------------------------- | ---------------- |
| Known, deliberately not being worked on  | `status/parked`  |
| Cannot proceed until a dependency clears | `status/blocked` |

An issue with no `status/*` label is in active work. There is no `status/in-progress`, because
the board column already says the same thing.

If a real dependency exists, say what it is and make it a checklist item. `status/blocked` with
no stated blocker is just `status/parked` wearing a hat.

Do not file an issue for anything finished within the session, for machine-local state (journal
formatting, scratch files), or for a preference with no work attached. Those stay in the journal,
or in memini if they are a durable lesson.

## Labels are the state; the Project board is only a view

Forgejo Projects has no REST API. `/repos/{owner}/{repo}/projects`, `/orgs/{owner}/projects`
and `/projects` all return 404, and `project` appears nowhere in the swagger spec. The Forgejo
tools of the `-ops` tier expose nothing for it either, because the MCP wraps that same API.
Column automation does not exist either. A column has a title, a colour, and an optional
"default" flag, and nothing more (forgejo/forgejo#773, open since 2023).

These consequences matter:

- No agent can read or write the board. Never treat the column of a card as the state of anything.
- Labels are the only machine-readable truth. Set them correctly even when the board looks right.
- Adding an issue to a board and moving its card are manual actions that a human does in the web UI.

Per-repo boards, not org-level. `frostlink` gets its own once the Artemis pilot proves out
([#2759](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2759)).

## Label taxonomy

There are four axes, all queryable via the API. `.forgejo/labels.yaml` is the source of truth.
The labels-sync workflow prunes, so a label that you remove from that file is deleted
server-side and stripped from every issue and PR that carries it.

| Namespace   | Notes                                                                                       |
| ----------- | ------------------------------------------------------------------------------------------- |
| `kind/`     | what sort of work it is                                                                     |
| `status/`   | `parked`, `blocked`. No label means active                                                  |
| `area/`     | `.forgejo/labeler.yaml` applies it to PRs automatically. Run `list_labels` for the live set |
| `priority/` | `high` only. It is a flag, not a scale. No label means normal                               |

Values: `grep 'name:' .forgejo/labels.yaml`.

`priority/` is one label on purpose. It once carried `high`, `medium` and `low`. But `medium` was
the default and carried no information, and `low` was indistinguishable from `status/parked`.
Parked does not mean unimportant. A parked item can still be `priority/high`.

Do not reuse `type/*`. Renovate owns it, on PRs only. There is no `renovate/*` namespace and no
`hold` or `hold/upstream`. Use `status/blocked` for anything held on an upstream fix, on our
work, or on the work of Renovate.

`area/*` is where the gaps show up. Add another label rather than force a bad fit. Add it to
`.forgejo/labels.yaml`, and give it a glob in `.forgejo/labeler.yaml` if PRs must get it too.

`area/kubernetes` is deliberately the fallback for app namespaces with no glob of their own. It
matches most PRs, so it is not a useful filter on its own.

## Filing one

Use the Forgejo tools of the `-ops` tier where they fit. Tool names carry a server prefix that
changes when the gateway is rewired. List the tools and match on the suffix. Do not hardcode a
fully-qualified name.

The REST API takes label IDs, not names, and those IDs differ per repo. Always resolve them
and do not hardcode them:

```bash
TOKEN=$(op read 'op://infrastructure/forgejo/EXIKLE_CLI_TOKEN')
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

Write the body so that the next reader does not have to re-derive the investigation. State the
evidence, what you already ruled out, and the order of work. `#1700` is the model. It records
two corrections to its own first diagnosis, so that nobody repeats them.

## Journal and tracker together

Use both, not either:

- The journal is the narrative. It records what you did this session, what you applied live, what
  the user confirmed, and what is left suspended. It is session-scoped and disposable.
- The issue is the durable obligation. It survives the session, the machine, and the PreCompact
  hook.
- memini holds the non-obvious lesson, so that the next session does not re-derive it.

When a session parks something, the journal entry says so and names the issue number. When you
file an issue, put its number in the journal entry that created it. A journal bullet that
describes parked work with no issue number is a bug in the process.
