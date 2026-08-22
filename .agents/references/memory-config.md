# Memory & MCP Configuration

How AI agents get tools and long-term memory in this repo. Keep this current when the MCP layout or memory system changes.

---

## Two registration files — keep them in sync

MCP servers are declared **twice**, once per client. Adding or retiring a tier means editing both:

| File            | Client      | Auth mechanism                                                |
| --------------- | ----------- | ------------------------------------------------------------- |
| `.mcp.json`     | Claude Code | `headersHelper` script resolves the bearer token at call time |
| `opencode.json` | opencode    | `{env:LITELLM_API_KEY}` / `{env:MEMINI_API_KEY}` from `.env`  |

opencode reads its tokens from the gitignored `.env`, regenerated with `just ai env` (pulls from
1Password). Claude Code never reads `.env` — its helper script fetches the token itself. A tier that
works in one client and 401s in the other almost always means `.env` is stale.

`memini` is registered directly in `opencode.json`; for Claude Code it arrives via the memini
**plugin** instead, which is why it is absent from `.mcp.json`. That asymmetry is intentional.

---

## `.mcp.json` — Claude Code MCP Servers

Repo-root file registering project-specific MCP servers for Claude Code sessions. Loaded in addition to any global servers configured in `~/.claude.json` or via Claude Code plugins.

```json
{
    "mcpServers": {
        "litellm-general": {
            "type": "http",
            "url": "https://litellm.dcunha.io/general/mcp",
            "headersHelper": "node /home/exikle/.claude/scripts/litellm-headers.mjs"
        },
        "litellm-media": { "...": "same shape, /media/mcp" },
        "litellm-ops": { "...": "same shape, /ops/mcp" }
    }
}
```

**Tiers and their tools:**

| Tier              | URL                                     | Tools available                             |
| ----------------- | --------------------------------------- | ------------------------------------------- |
| `litellm-general` | `https://litellm.dcunha.io/general/mcp` | SearXNG, Grafana, VictoriaLogs, context7    |
| `litellm-media`   | `https://litellm.dcunha.io/media/mcp`   | Sonarr, Radarr, Prowlarr, seerr             |
| `litellm-ops`     | `https://litellm.dcunha.io/ops/mcp`     | Kubernetes, GitHub, Forgejo, Home Assistant |

One `litellm` proxy, tiers separated by URL path + each `LiteLLMMCPServer`'s `access_groups`. All requests require `Authorization: Bearer <master_key>`. `litellm-ops` has privileged cluster access — agent clients only, never exposed to a general-purpose chat frontend.

Proxy config lives in `kubernetes/apps/cortex/litellm/`. Individual MCP servers live in `kubernetes/apps/cortex/mcp/<name>-mcp/`.

**When to update**: when a new MCP server is added, an `access_group`/tier changes, or a URL moves.

---

## memini — Cross-Session Memory

`memini` provides semantic long-term memory scoped to this project. Claude Code gets it as a plugin (hence its absence from `.mcp.json`), with tools under the memini plugin's memory tools (the client prefixes them — never hardcode the full name, list the tools and match on the `memory_*` portion); opencode gets it as a remote MCP server declared in `opencode.json`, pinned to the `Artemis-Cluster` namespace via the `X-Memini-Namespace` header. It replaced the earlier `mempalace` MCP server — there are no `mempalace.yaml` or `entities.json` files in this repo; routing and scoping are handled by the plugin itself, not by repo-local config.

- **Load**: call `memory_recall` / `memory_answer` / `memory_briefing` when starting work on a topic that may have prior history.
- **Save**: call `memory_remember` after a non-obvious discovery — a quirk, a failure mode, a workaround that would take real effort to re-derive.
- **Don't** use memini for conventions, architecture, or project context that's already documented in `.agents/` — that content belongs in an instruction, reference, or skill file instead, where it's version-controlled and reviewable.

The `memini` app itself (embeddings + storage) is deployed in-cluster at `kubernetes/apps/cortex/memini/` — that's the service the plugin talks to, distinct from the plugin/client side described above.

**When to update this doc**: when the memini plugin's scoping model changes, or the in-cluster deployment moves namespace.

---

## Recall & Write-Path Tuning

Tuned 2026-08-21 from a diagnosis against the live deployment. The manifest carries no comments
(see `yaml-conventions.md` § No Comments in Manifests), so the reasoning for each value lives
here. Primary source: `docs/guides/tuning-recall.md` in the memini marketplace checkout.

**Diagnose before tuning.** `memini doctor` first, every time. A namespace mismatch — writes
landing in one namespace while recall reads another — is the most common cause of "memini forgot
everything", and no ranking knob can fix a pointer problem. Doctor was clean on 2026-08-21:
namespace resolves to `Artemis-Cluster` by git remote in the repo, read set is the repo plus
`personal/exikle` (home) plus `fingerjoin`/`frostlink` (links).

| Setting                         | Value    | Why                                                                                                                                                                                                                                                               |
| ------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_WRITE_EMBED_TIMEOUT`    | `20s`    | The unset default is 5s. The pod logged 47 `embed_timeout` write failures in 20h, each storing a memory with **no vector** — permanently invisible to semantic recall. Recall had 20s; the write path never did.                                                  |
| `MEMINI_RERANK_MAX_DOC_CHARS`   | `1800`   | `jina-reranker` runs llama.cpp with `uBatchSize: 1024`, and a rerank pair must fit one physical batch. At 4000 chars pairs measured 1042–1244 tokens and the backend returned HTTP 500, which memini swallows as a silent fallback to composite order.            |
| `MEMINI_RERANK_POOL`            | `25`     | Default `0` reranks only the results already being returned, so the cross-encoder can never rescue a memory that fused retrieval placed below the cut — which is most of what it is for. Started at 25, not the ~50 ceiling, because this is a CPU-only reranker. |
| `MEMINI_RERANK_MAX_BATCH_CHARS` | `120000` | The `6000` default shards a deep pool into many **serial** requests, which blows the rerank timeout far more easily than a large body does. It is an HTTP payload guard, not a context guard — each pair is scored in its own forward pass.                       |
| `MEMINI_RERANK_TIMEOUT`         | `20s`    | Headroom for the deeper pool. Must stay **below** the client ceiling (`request_timeout_ms`, currently 30000) or a slow rerank makes the client hang up first and recall returns nothing instead of degrading to composite order.                                  |
| `MEMINI_DEMOTE_AFTER`           | `0`      | Disables demotion. 483 low-confidence durable memories were exposed, and the sweeper's "never recalled" clause is effectively always true here — recall has run ~63 times against 1841 memories.                                                                  |

### Known-remaining items

- **`memini reembed` is owed.** Memories already written without a vector do not repair
  themselves. Run it once `MEMINI_WRITE_EMBED_TIMEOUT` is live. It is slow against a CPU-only
  0.6B embedder — schedule it, do not run it interactively.
- **`MEMINI_RERANK_MIN_SCORE` is still `0` (off)** and is the only thing that can cut the
  confident-noise tail — a nonsense probe query returned 13 hits topping 0.93. It is
  **model-specific and must be swept**, never copied from a doc, and the sweep is meaningless
  until the rerank 500s are gone.
- **Alternative to truncating documents**: raising `uBatchSize` to 2048 in
  `kubernetes/apps/cortex/llmkube/models/jina-reranker.yaml` would let `MAX_DOC_CHARS` stay at
  4000 and give the cross-encoder the whole memory to judge — strictly better ranking quality,
  at the cost of reranker RAM. Not taken here because it needs memory watched while it settles.

### The client side is the bigger lever on "memory feels unused"

Activity shows **63 recall events all-time against 200+ `remember` events in a day**, and zero
`answer` events. Saving is not the problem; recall is barely invoked. The knobs that matter are
client behaviour defaults served from `PUT /v1/settings/defaults`, **not** helmrelease env:
`recall_limit` (3), `inject_recall_min_score` (0.5), `inject_pretool_min_score` (0.5),
`inject_briefing_facts` (5). Served composite p50 is 0.671, so a 0.5 floor cuts close to the
median. Raise **one at a time** and watch the `inject` activity events — moving all four at once
floods context and produces the opposite complaint.
