# Memory & MCP Configuration

This file describes how AI agents get tools and long-term memory in this repo. Update it when the MCP layout
or the memory system changes.

---

## Six registration files — keep them in sync

There are six registration files. Only two of them live in this repo.
When you add or retire a tier, edit every row:

| File                                                 | Client                           | Auth mechanism                                                         | In this repo?                                     |
| ---------------------------------------------------- | -------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------- |
| `.mcp.json`                                          | Claude Code, this repo           | `headersHelper … <tier>` returns `{"x-api-key": …}` at call time       | yes                                               |
| `opencode.json`                                      | opencode, this repo              | `x-api-key: {env:MCP_<TIER>_KEY}` / `{env:MEMINI_API_KEY}` from `.env` | yes                                               |
| `~/frostlink/.mcp.json`                              | Claude Code, frostlink repo      | same helper, same per-tier argv                                        | no, other repo                                    |
| `~/.claude/local-marketplace/dcunha-tools/.mcp.json` | Claude Code, every other project | same helper, same per-tier argv                                        | no, not dotfiles-managed either                   |
| User scope in `~/.claude.json`                       | Claude Code, any directory       | same helper; added with `claude mcp add-json -s user …`                | no, machine-local state, no automation reaches it |
| Windows Zed `%APPDATA%/Zed/settings.json`            | Zed                              | keys inlined in plaintext                                              | no, Windows filesystem, no automation reaches it  |

Server names are `ai-ops` and `ai-general` everywhere. Claude Code renders their tools as
`mcp__ai-<tier>__<target>_<tool>`.

The tier argument is required. `~/.claude/scripts/ai-headers.mjs` (dotfiles) requires
`ops` or `general` as argv, reads `op://artemis/agentgateway/KEY_<TIER>` and returns
`{"x-api-key": …}`. There is no fallback key. If you omit the tier, the script fails. It does not
authenticate as something broader. When you add a registration, pass the tier.

opencode reads its keys from the gitignored `.env`. Run `just ai env` to regenerate it (it pulls from
1Password). The command writes `MCP_OPS_KEY`, `MCP_GENERAL_KEY` and `AGENTGATEWAY_API_KEY` (the model
key, used by `scripts/eval-instructions.py` against `https://ai.dcunha.io/v1`). Claude Code never
reads `.env`. Its helper script fetches the key itself. If a tier works in one client and
returns 401 in the other, `.env` is almost always stale.

`memini` is registered directly in `opencode.json`. Claude Code gets it from the memini
plugin instead, so it is absent from `.mcp.json`. This difference is intentional.

---

## `.mcp.json` — Claude Code MCP Servers

This file sits at the repo root. It registers project-specific MCP servers for Claude Code sessions. Claude Code loads it in
addition to any servers configured at user scope in `~/.claude.json` or through Claude Code plugins.

```json
{
    "mcpServers": {
        "ai-general": {
            "type": "http",
            "url": "https://ai.dcunha.io/general/mcp",
            "headersHelper": "node /home/exikle/.claude/scripts/ai-headers.mjs general"
        },
        "ai-ops": { "...": "same shape, /ops/mcp, helper arg `ops`" }
    }
}
```

Tiers and their tools: the tier URL is `https://ai.dcunha.io/<tier>/mcp`, where `<tier>` is
`general` or `ops`. This file does not list which target sits in which tier. Read it with this command:

```bash
grep -n -B1 'name:' clusters/artemis/kubernetes/apps/cortex/agentgateway/mcp/agentgatewaybackend.yaml
```

The media tools (arr, seerr) are in `ai-general`. There is no separate media tier.

These two are the Claude Code tiers. A third tier, `ai-agent` (`/agent/mcp`, with flux, k8s, searxng,
and victoria-logs), exists for hermes only. It is deliberately absent from every registration file.
It is a token-budget measure, not a capability tier. Do not add it to a registration file. See
`.agents/references/cortex-mcp.md`.

Each tier authenticates with its own API key (1Password item `agentgateway`, fields
`KEY_OPS` / `KEY_GENERAL`). A leak or a runaway key affects only one tier, and the gateway
rejects a key on the path of the wrong tier. `ai-ops` has privileged cluster access. Use it in agent clients
only, and never expose it to a general-purpose chat frontend. The auth rules, and the reason the key must be
an `x-api-key` header and never `Authorization`, are in `cortex-mcp.md`.

`context7` is the only remote server (`https://mcp.context7.com/mcp`). The other servers run as
Deployments in `cortex` (`cortex-mcp.md` § Layout).

The general lesson is that a healthy pod proves the workload started. It does not prove that the gateway can speak
MCP to it. The gateway skips a target that is down without a message (`failureMode: FailOpen`), so the tier
lists fewer tools. To see what a tier
exposes, list the tools in a client. To check the proxy side, run this command:

```bash
kubectl logs -n cortex -l app.kubernetes.io/name=agentgateway --tail=200
```

The gateway configuration is in `clusters/artemis/kubernetes/apps/cortex/agentgateway/`. The individual MCP servers are in
`clusters/artemis/kubernetes/apps/cortex/mcp/app/<name>/`.

When to update this section: when someone adds a new MCP server, a tier changes, or a URL moves.

---

## memini — Cross-Session Memory

`memini` gives semantic long-term memory that is scoped to this project. Claude Code gets it as a
plugin, so it is absent from `.mcp.json`. The client adds a prefix to the tool names, so never
hardcode a full name. List the tools and match on the `memory_*` part. opencode gets it as a
remote MCP server declared in `opencode.json`. That file pins the namespace with an explicit
`X-Memini-Namespace` header.

An explicit `X-Memini-Namespace` header wins over the server-side pin, and neither client reports an error.
A stale header silently splits reads and writes across two namespaces. `opencode.json` pins
`homelab/Artemis-Cluster`. The Windows Zed config still carries the flat `home-infra`, so it
writes to a place that nothing reads.

- Load: call `memory_recall`, `memory_answer`, or `memory_briefing` when you start work on a
  topic that can have prior history. Read the `scope_header` of the briefing. If it says `default`,
  the namespace did not resolve, and everything you recall belongs to the wrong project.
- Save: call `memory_remember` after a non-obvious discovery. Examples are a quirk, a failure mode, or a
  workaround that would take real effort to work out again.
- Do not use memini for conventions, architecture, or project context that
  is already documented in `.agents/`. That content belongs in an instruction, reference, or skill file
  instead, where it is version-controlled and reviewable.

The `memini` app itself (embeddings and storage) runs in the cluster at
`clusters/artemis/kubernetes/apps/cortex/memini/`. That is the service the plugin talks to. It is separate from the
plugin and client side described above. It embeds with `qwen3-embedding` and reranks with
`jina-reranker`. Both are `llmkube` models in `cortex`. `MEMINI_BACKEND` is `postgres` (shared CNPG).
`MEMINI_SQLITE_PATH` is also set but unused.

When to update this doc: when the scoping model of the memini plugin changes, or the in-cluster
deployment moves namespace.

---

## Recall & Write-Path Tuning

The manifest carries no comments
(see `yaml-conventions.md` § No Comments in Manifests), so the reasoning for each value lives
here. The primary source is `docs/guides/tuning-recall.md` in the memini marketplace checkout.

Diagnose before you tune. Always run `memini doctor` first. A namespace mismatch is the most common cause of "memini forgot
everything". In a mismatch, writes land in one namespace while recall reads another. No ranking setting can fix a pointer problem. The read set for
`homelab/Artemis-Cluster` is the repo, its `homelab` ancestor, `personal/exikle` (home), and two
links (`homelab/frostlink`, `fingerjoin`).

| Setting                         | Value    | Why                                                                                                                                                                                                                                                                                          |
| ------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_WRITE_EMBED_TIMEOUT`    | `20s`    | The unset default is 5s. The pod logged repeated `embed_timeout` write failures. Each one stored a memory with no vector, so semantic recall can never find it. Recall had 20s. The write path never did.                                                                                    |
| `MEMINI_RERANK_MAX_DOC_CHARS`   | `1800`   | `jina-reranker` runs llama.cpp with `uBatchSize: 1024`, and a rerank pair must fit one physical batch. At 4000 chars, pairs measured 1042–1244 tokens and the backend returned HTTP 500. memini hides that error and falls back to composite order.                                          |
| `MEMINI_RERANK_POOL`            | `25`     | The default `0` reranks only the results that already go to the caller. So the cross-encoder can never rescue a memory that fused retrieval placed below the cut, which is most of what it is for. The value started at 25, not the ceiling of about 50, because the reranker uses CPU only. |
| `MEMINI_RERANK_MAX_BATCH_CHARS` | `120000` | The `6000` default splits a deep pool into many serial requests. These requests exceed the rerank timeout far more easily than a large body does. The setting is an HTTP payload guard, not a context guard. Each pair is scored in its own forward pass.                                    |
| `MEMINI_RERANK_TIMEOUT`         | `20s`    | This gives headroom for the deeper pool. It must stay below the client ceiling (`request_timeout_ms`, currently 30000). Otherwise a slow rerank makes the client hang up first, and recall returns nothing instead of falling back to composite order.                                       |
| `MEMINI_DEMOTE_AFTER`           | `0`      | This disables demotion. Many low-confidence durable memories were exposed. The "never recalled" clause of the sweeper is almost always true here, because recall runs rarely against a large store.                                                                                          |

### LLM budget — the model, the token cap, and the assessment sweep

The team set these values after the shared opencode.ai `zen/go` monthly quota ran out. memini was the biggest LLM consumer in the cluster, and it used the least efficient model available.

| Setting                     | Value                    | Why                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_LLM_MODEL`          | `opencode-go/minimax-m3` | It was `opencode-go/deepseek-v4-flash`. The 2026-08-16 bake-off in `hermes.md` measured deepseek at 7,934 completion tokens / 35.9s on a task that minimax-m3 answered correctly in 129 tokens / 1.9s. That is about 60x the cost for no gain in accuracy. The team applied that result to hermes and missed it here.                                                                                                                                                                                                                                |
| `MEMINI_LLM_MAX_TOKENS`     | `8192`                   | It ships with the model swap, not after it. The value `0` keeps the built-in 4096 budget of the client, and hidden reasoning tokens use that budget. minimax-m3 is `supportsReasoning: true`. So a blown budget returns `finish_reason: length`, and the whole pipeline call is silently lost.                                                                                                                                                                                                                                                       |
| `MEMINI_ASSESS_INTERVAL`    | `6h`                     | The default is `1h`. The importance-backfill sweep drives the call volume. Hourly runs of `ASSESS_MAX_PER_RUN` rows in batches of `ASSESS_BATCH` make up to ten LLM calls an hour on top of dedup. The sweep drains a backlog, so a longer interval costs drain latency, not capability.                                                                                                                                                                                                                                                             |
| `MEMINI_ASSESS_MAX_PER_RUN` | `100`                    | The default is `200`. This halves the per-tick ceiling for the same reason.                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `MEMINI_ASSESS_BATCH`       | `10`                     | The default is `20`. The team set this on 2026-09-06. `minimax-m3` returns a well-formed `{"scores":[…]}` array that is one or two entries short of a 20-item batch, and memini treats a positional length mismatch as a lost batch. A failure in the first batch abandons the entire pass, so at batch 20 the sweep wrote nothing at all. This is not truncation: `finish_reason: stop` came at about 100 completion tokens against an 8192 cap, so a higher `MEMINI_LLM_MAX_TOKENS` does nothing here. At batch 10, the same 100 rows assessed 90. |
| `MEMINI_CHUNK_EMBED`        | `true`                   | This only adds to recall. Long memories are also embedded in overlapping segments, so a match past `EMBED_MAX_ITEM_CHARS` can be found, not only the prefix. It runs on the local `qwen3-embedding`, so it costs no upstream quota. The `BACKFILL_INTERVAL` loop builds the segments, not the write path.                                                                                                                                                                                                                                            |

The cap is a ceiling, not a reservation. A higher `MEMINI_LLM_MAX_TOKENS` does not increase
spend on calls that answer briefly. It only stops a long answer from being cut off into a lost
call. Truncation is the more expensive failure, because the tokens are spent either way and the
result is discarded.

Do not "fix" a quota outage by picking a smaller-sounding model. One opencode.ai workspace serves all the agentgateway models on one monthly quota. So there is no cheaper tier to drop to,
and no fallback that crosses a provider boundary. `minimax-m3` is already the low-cost option
here. `deepseek-v4-flash` is the expensive one with a fast-sounding name. See
`.agents/references/hermes.md` § Model selection is measured, not assumed.

### Known-remaining items

- `memini reembed` is no longer owed. The team checked on 2026-09-06 that every stored memory has a vector,
  so there is nothing for it to repair. `reembed` rewrites the whole store when you switch embedding
  models. It does not fill gaps. If you ran it, it would re-embed every row on a CPU-only 0.6B embedder for
  no gain.
- `MEMINI_RERANK_MIN_SCORE` is still `0` (off). It is the only setting that can cut the
  tail of confident noise. A nonsense probe query returned 13 hits that topped 0.93. The right value is
  model-specific and you must sweep for it. Never copy it from a doc. The 500s are gone, but the
  sweep means little while a deep pool still sits near the rerank timeout (see the
  `jina-reranker` item below). You cannot sweep it per request, and recall responses never
  return the rerank score. So sweep offline: score (query, candidate) pairs against `/v1/rerank`
  directly, or use `go run ./cmd/bench -rerank-gate` from the memini repo.
  [#2753](https://git.dcunha.io/Exikle/home-infra/issues/2753)
- `MEMINI_ASSESSED_SALIENCE_WEIGHT` is still `0`. The assessment sweep runs and costs money,
  but at weight 0 its score feeds only the rerank-pool reservation (`RECALL_IMPORTANCE_RESERVE`).
  The score decides which candidates the reranker sees. It never decides how they are ordered. To use what the sweep produces, raise the weight. But it is a lifecycle setting as well as a ranking
  one: salience feeds short-term cap eviction, briefing order and dedup survivor selection. The
  docs say to bench it first, so the team left it alone.
  [#2754](https://git.dcunha.io/Exikle/home-infra/issues/2754)
- `jina-reranker` runs `uBatchSize: 2048` and a 1-core CPU request (2026-10-13,
  [#2755](https://git.dcunha.io/Exikle/home-infra/issues/2755)). The value 2048 removed the HTTP 500s:
  a 4000-char pair now scores. `MAX_DOC_CHARS` still stays at 1800, because CPU is now the binding limit,
  not batch size. Measured on ymir: a 25-doc pool took 54s at 4000 chars and 22s at
  1800, against a 20s `MEMINI_RERANK_TIMEOUT`. At 4000, every recall timed out and fell back to
  composite order. ymir has 4 cores shared with `qwen3-embedding` (about 1.5–1.9 cores busy around the
  clock) and frigate. At the old 100m request, the reranker lost that contention. Even a
  single 200-char doc took 3.7s. Do not raise `MAX_DOC_CHARS` or `RERANK_POOL` until the reranker
  has CPU to spare. First time a pool by hand: POST 25 docs to `/v1/rerank` through a
  port-forward.

### The client side is the bigger lever on "memory feels unused"

When the team tuned memini, recall events were far rarer than `remember` events, with zero `answer` events.
Saving is not the problem. Recall is barely invoked. The settings that matter are client behavior
defaults that the server serves from `PUT /v1/settings/defaults`, not helmrelease env: `recall_limit`,
`inject_recall_min_score`, `inject_pretool_min_score`, `inject_briefing_facts`. To read the live
values, use `GET /v1/settings/defaults`. It is safe and needs no write. At tuning time, a 0.5
floor cut close to the median composite score. Raise one setting at a time and watch the `inject`
activity events. If you move all four at once, you flood the context and get the opposite complaint.

A client env var wins over the served default. The plugin resolves each setting as env, then server,
then built-in (`effectiveSetting()` in the generated client script of the plugin). The hooks read
the server side from the `POST /v1/handshake` response, not from `/v1/settings/defaults`.
`~/.claude/settings.json` sets `MEMINI_INJECT_RECALL_MIN_SCORE` and
`MEMINI_INJECT_PRETOOL_MIN_SCORE` to `0.6`. So Claude Code on this machine injects at 0.6,
and the served `0.5` applies only to clients without the env var. The team keeps the 0.6 on purpose
([#2758](https://git.dcunha.io/Exikle/home-infra/issues/2758)). Change it in
`settings.json`, not through `PUT /v1/settings/defaults`. Otherwise the change does not reach this
machine.
`request_timeout_ms` (served `30000` when checked) is the ceiling that `MEMINI_RERANK_TIMEOUT` must
stay under.

---

## Namespace Topology

Namespaces are hierarchical. The layout is:

```text
homelab/                    shared across the infrastructure repos
├── homelab/Artemis-Cluster this repo
├── homelab/frostlink       the Oracle Cloud cluster
├── homelab/hermes          the hermes agent (set by MEMINI_NAMESPACE, not a pin)
└── homelab/<repo>          any other repo that runs servers or the network, pinned by hand
personal/exikle             follows the user everywhere (MEMINI_HOME)
personal/<repo>             every other repo — the default for an unpinned repo
```

Resolution uses a server-side pin (`GET`/`PUT /v1/pins`). So it follows across machines and
every client (hooks, MCP tools, CLI) agrees.

Each repo has two pin keys, not one. A remote pin alone does not cover a checkout with no
remote configured, or a probe that only ever sees a path:

| Key                                           | → namespace               |
| --------------------------------------------- | ------------------------- |
| `remote:git.dcunha.io/exikle/artemis-cluster` | `homelab/Artemis-Cluster` |
| `path:/home/exikle/home-infra`                | `homelab/Artemis-Cluster` |
| `remote:git.dcunha.io/exikle/frostlink`       | `homelab/frostlink`       |
| `path:/home/exikle/frostlink`                 | `homelab/frostlink`       |

The remote key is lowercased (`artemis-cluster`), while the namespace it maps to keeps the
capital A. Do not "correct" the key to match the namespace. The system matches it against a normalized
remote.

`dotfiles/home/claude/settings.json` (symlinked to `~/.claude/settings.json`) sets no
`MEMINI_NAMESPACE`. It sets `MEMINI_NAMESPACE_PREFIX` to `personal`, `MEMINI_HOME` to
`personal/exikle` and `MEMINI_BASE_URL` to `https://memini.dcunha.io`.

After you change a pin, run `/reload-plugins`. The MCP `headersHelper` runs only when the
server connects. Until it reconnects, the hooks and the MCP tools point at different
namespaces. Memory half-works and nothing reports an error.

### How the cascade actually flows

| Direction             | What crosses                                              |
| --------------------- | --------------------------------------------------------- |
| child → parent (up)   | durable tiers, read-only, always on under `scope: "full"` |
| parent → child (down) | only via a per-call `scope: "everywhere"`                 |
| sibling → sibling     | nothing, which is why the explicit link still exists      |
| any write             | stays put unless `visibility:` names an ancestor          |

`homelab/Artemis-Cluster` keeps explicit links to sibling repos. The shared parent makes none of them redundant,
because siblings inherit nothing from each other. To list the links, use `GET /v1/links`
(`X-Memini-Namespace: homelab/Artemis-Cluster`). A namespace move repoints a link to it. A
re-pin does not. So after you move a repo to a new namespace, re-create its link.

The frostlink link is tier-restricted. Episodic memories (the session-by-session narrative)
do not cross it. This is deliberate, because the incident timeline of one cluster is noise in the other. But
it means that "I know we hit this on frostlink" does not surface from an Artemis session unless someone wrote the
lesson as a durable semantic or procedural fact. If the lesson matters to both clusters,
write it with `visibility: "homelab"`. Do not rely on the link.

Links are directional. Nothing flows from `homelab/frostlink` back to `homelab/Artemis-Cluster`
unless you create a matching link there too.

### Write routing — the rule

The default project visibility is right for almost everything. Use `visibility: "homelab"`
only when the fact is true of both clusters and you would otherwise have to learn it twice.

| Fact                                                           | Goes to                   |
| -------------------------------------------------------------- | ------------------------- |
| Ceph PG counts, OSD memory, `apply-ks` suspend behaviour       | `homelab/Artemis-Cluster` |
| openebs-zfs restore mechanics, the towonel edge                | `homelab/frostlink`       |
| Canonical Forgejo remote is `Exikle` with a capital E          | `homelab`                 |
| "No Comments in Manifests" applies in both repos               | `homelab`                 |
| The two clusters are not symmetric — cert-manager only Artemis | `homelab`                 |
| "prefers to confirm before merging to main"                    | `personal/exikle`         |

A good test: if the sentence names the hardware or storage layer of one cluster, it is project-level.
If it names a convention, a workflow, or a difference between the two, it is `homelab`.

### Known-open

- MCP connects used to send no namespace. The team fixed this in the wrapper, not the plugin. The team captured it
  live on 2026-10-13 (Claude Code 2.1.296, plugin 0.7.35). Claude Code runs the MCP
  `headersHelper` as `/bin/sh -c ~/.claude/scripts/memini-headers.sh`, with the cwd set to the
  plugin root and no `CLAUDE_PROJECT_DIR`. The `resolveHarnessCwd()` function of the plugin tries
  `CLAUDE_PROJECT_DIR`, then the cwd of the parent (rejected as the plugin root), then a session file
  keyed to the wrong pid. All three fail, so it emits auth-only headers, and every MCP call lands
  in the server default `homelab` (`MEMINI_DEFAULT_NAMESPACE`). Hooks were never affected,
  because they get `cwd` on stdin. The `claude` process one level up sits in the project dir.
  So dotfiles `home/claude/scripts/memini-headers.sh` now walks ancestors to the first cwd outside
  the plugin cache and exports it as `CLAUDE_PROJECT_DIR`
  ([#2756](https://git.dcunha.io/Exikle/home-infra/issues/2756)). The fix takes effect on
  the next MCP connect (`/mcp` → reconnect; `/reload-plugins` does not reconnect).

    Check the scope. Do not assume it. A recall hit whose `namespace` is `homelab` with no
    `from` field means the MCP side resolved to `homelab` itself, so the fallthrough is back. The
    connect log `~/.cache/claude-cli-nodejs/<project>/mcp-logs-plugin-memini-memini/*.jsonl`
    must say "retrieved 3 headers". If it says 2, the client sent no namespace.

- The team cleaned the junk namespaces from the old fallthrough on 2026-10-13. `containers`,
  `dotfiles`, `memory` and `Rensaio` held 269 memories. The team reassigned 42 to their real
  namespace and forgot the rest
  ([#2757](https://git.dcunha.io/Exikle/home-infra/issues/2757)). A namespace that matches a
  directory basename is still the sign of a cwd probe that landed the wrong place.
  Check `GET /v1/namespaces` before you assume the memories of a project are gone.

- The deployment sets `homelab/hermes`, not a pin. The hermes HelmRelease sets
  `MEMINI_NAMESPACE: homelab/hermes` (`clusters/artemis/kubernetes/apps/cortex/hermes/app/helmrelease.yaml`).
  The team moved it from a top-level `hermes` on 2026-10-20 so the agent reads the shared `homelab` facts.
  Its own writes stay in `homelab/hermes`. Only a `visibility: "homelab"` write reaches the
  parent that your sessions read.
- Promotion to `homelab` is incremental. The team promoted three seed facts by hand. The rest
  arrive naturally when you write new cross-cluster lessons with `visibility: "homelab"`. There is no
  need for a bulk curation pass, and bulk-move-by-filter does not exist anyway.
