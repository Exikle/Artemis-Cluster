# Memory & MCP Configuration

How AI agents get tools and long-term memory in this repo. Keep this current when the MCP layout
or memory system changes.

---

## Five registration files — keep them in sync

There are **five**, and only two of them live in this repo.
Adding or retiring a tier means editing every row:

| File                                                 | Client                               | Auth mechanism                                                         | In this repo?                                     |
| ---------------------------------------------------- | ------------------------------------ | ---------------------------------------------------------------------- | ------------------------------------------------- |
| `.mcp.json`                                          | Claude Code, this repo               | `headersHelper … <tier>` resolves a per-tier bearer token at call time | yes                                               |
| `opencode.json`                                      | opencode, this repo                  | `{env:MCP_<TIER>_KEY}` / `{env:MEMINI_API_KEY}` from `.env`            | yes                                               |
| `~/frostlink/.mcp.json`                              | Claude Code, frostlink repo          | same helper, same per-tier argv                                        | no — other repo                                   |
| `~/.claude/local-marketplace/dcunha-tools/.mcp.json` | Claude Code, **every other project** | same helper, same per-tier argv                                        | no — not dotfiles-managed either                  |
| Windows Zed `%APPDATA%/Zed/settings.json`            | Zed                                  | keys inlined in plaintext                                              | no — Windows filesystem, no automation reaches it |

**The tier argument is load-bearing.** `litellm-headers.mjs` maps tier → `MCP_<TIER>_KEY` →
`op://artemis/litellm/<FIELD>`, and **omitting it falls back to `MASTER_KEY`**. Omitting it
authenticates the privileged ops tier as master. If you add a registration, pass the tier.

opencode reads its tokens from the gitignored `.env`, regenerated with `just ai env` (pulls from
1Password). Claude Code never reads `.env` — its helper script fetches the token itself. A tier that
works in one client and 401s in the other almost always means `.env` is stale.

`memini` is registered directly in `opencode.json`; for Claude Code it arrives via the memini
**plugin** instead, which is why it is absent from `.mcp.json`. That asymmetry is intentional.

---

## `.mcp.json` — Claude Code MCP Servers

Repo-root file registering project-specific MCP servers for Claude Code sessions. Loaded in
addition to any global servers configured in `~/.claude.json` or via Claude Code plugins.

```json
{
    "mcpServers": {
        "litellm-general": {
            "type": "http",
            "url": "https://litellm.dcunha.io/general/mcp",
            "headersHelper": "node /home/exikle/.claude/scripts/litellm-headers.mjs general"
        },
        "litellm-media": { "...": "same shape, /media/mcp, helper arg `media`" },
        "litellm-ops": { "...": "same shape, /ops/mcp, helper arg `ops`" }
    }
}
```

**Tiers and their tools:**

`LiteLLMMCPServer` CRs are grouped into tiers by `spec.params.access_groups` — a server may
belong to more than one. The **alias** is what prefixes the tool names a client sees, so it is the
name to match on:

The tier URL is `https://litellm.dcunha.io/<tier>/mcp`, where `<tier>` is `general`, `media` or
`ops`. Which server sits in which tier is not printed here — read it:

```bash
grep -n 'alias:\|access_groups' kubernetes/apps/cortex/litellm/mcp/*/mcpserver.yaml
```

**These three are the Claude Code tiers.** A fourth group, `agent` (`/agent/mcp` — `k8s`, `flux`,
`searxng`, `victoria_logs`), exists for hermes only and is deliberately absent from every
`.mcp.json`: it is a token-budget measure, not a capability tier. Do not add it to a registration
file. See `.agents/references/cortex-mcp.md` § Access groups.

One `litellm` proxy, tiers separated by URL path + `access_groups`. Each tier authenticates with
its **own virtual key** (`op://artemis/litellm/MCP_<TIER>_KEY`), not the master key, so a leak or a
runaway is scoped to one tier. `litellm-ops` has privileged cluster access — agent clients
only, never exposed to a general-purpose chat frontend.

`context7` is the only remote server (`https://mcp.context7.com/mcp`); the rest run as
Deployments in `cortex` and resolve to `http://mcp-<name>.cortex.svc.cluster.local:<port>/mcp`.

`grafana` needs `-allowed-hosts` set: it defaults to loopback variants of `-address`, so with
`-address 0.0.0.0:8000` every request via the service FQDN is rejected `403` while the CR reconciles
clean and the pod stays `1/1 Running`. Full detail in `.agents/references/cortex-mcp.md` § grafana.

The general lesson: **`Ready=True` on the CR proves the
operator created the workload, not that litellm can speak MCP to it.** Confirm what a tier
actually exposes by listing tools in a client, and check with:

```bash
kubectl logs -n cortex deploy/litellm --tail=200 | grep run_with_session
```

Proxy config lives in `kubernetes/apps/cortex/litellm/`. Individual MCP servers live in
`kubernetes/apps/cortex/litellm/mcp/<name>/`.

**When to update**: when a new MCP server is added, an `access_group`/tier changes, or a URL moves.

---

## memini — Cross-Session Memory

`memini` provides semantic long-term memory scoped to this project. Claude Code gets it as a
**plugin** (hence its absence from `.mcp.json`); the client prefixes its tool names, so never
hardcode a full name — list the tools and match on the `memory_*` portion. opencode gets it as a
remote MCP server declared in `opencode.json`, which pins the namespace with an explicit
`X-Memini-Namespace` header.

**An explicit `X-Memini-Namespace` header beats the server-side pin, and neither client errors** —
a stale header silently splits reads and writes across two namespaces. `opencode.json` pins
`homelab/Artemis-Cluster`; the Windows Zed config still carries the flat `Artemis-Cluster`, so it
writes somewhere nothing reads.

- **Load**: call `memory_recall` / `memory_answer` / `memory_briefing` when starting work on a
  topic that may have prior history. Read the briefing's `scope_header` — if it says `default`,
  the namespace did not resolve and everything you recall is the wrong project's.
- **Save**: call `memory_remember` after a non-obvious discovery — a quirk, a failure mode, a
  workaround that would take real effort to re-derive.
- **Don't** use memini for conventions, architecture, or project context that's already
  documented in `.agents/` — that content belongs in an instruction, reference, or skill file
  instead, where it's version-controlled and reviewable.

The `memini` app itself (embeddings + storage) is deployed in-cluster at
`kubernetes/apps/cortex/memini/` — that's the service the plugin talks to, distinct from the
plugin/client side described above. It embeds via `qwen3-embedding` and reranks via
`jina-reranker`, both `llmkube` models in `cortex`; `MEMINI_BACKEND` is `postgres` (shared CNPG),
not the `MEMINI_SQLITE_PATH` that is also set but unused.

**When to update this doc**: when the memini plugin's scoping model changes, or the in-cluster
deployment moves namespace.

---

## Recall & Write-Path Tuning

The manifest carries no comments
(see `yaml-conventions.md` § No Comments in Manifests), so the reasoning for each value lives
here. Primary source: `docs/guides/tuning-recall.md` in the memini marketplace checkout.

**Diagnose before tuning.** `memini doctor` first, every time. A namespace mismatch — writes
landing in one namespace while recall reads another — is the most common cause of "memini forgot
everything", and no ranking knob can fix a pointer problem. Read set for
`homelab/Artemis-Cluster` is the repo, its `homelab` ancestor, `personal/exikle` (home), and two
links (`homelab/frostlink`, `fingerjoin`).

| Setting                         | Value    | Why                                                                                                                                                                                                                                                               |
| ------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_WRITE_EMBED_TIMEOUT`    | `20s`    | The unset default is 5s. The pod logged repeated `embed_timeout` write failures, each storing a memory with **no vector** — permanently invisible to semantic recall. Recall had 20s; the write path never did.                                                   |
| `MEMINI_RERANK_MAX_DOC_CHARS`   | `1800`   | `jina-reranker` runs llama.cpp with `uBatchSize: 1024`, and a rerank pair must fit one physical batch. At 4000 chars pairs measured 1042–1244 tokens and the backend returned HTTP 500, which memini swallows as a silent fallback to composite order.            |
| `MEMINI_RERANK_POOL`            | `25`     | Default `0` reranks only the results already being returned, so the cross-encoder can never rescue a memory that fused retrieval placed below the cut — which is most of what it is for. Started at 25, not the ~50 ceiling, because this is a CPU-only reranker. |
| `MEMINI_RERANK_MAX_BATCH_CHARS` | `120000` | The `6000` default shards a deep pool into many **serial** requests, which blows the rerank timeout far more easily than a large body does. It is an HTTP payload guard, not a context guard — each pair is scored in its own forward pass.                       |
| `MEMINI_RERANK_TIMEOUT`         | `20s`    | Headroom for the deeper pool. Must stay **below** the client ceiling (`request_timeout_ms`, currently 30000) or a slow rerank makes the client hang up first and recall returns nothing instead of degrading to composite order.                                  |
| `MEMINI_DEMOTE_AFTER`           | `0`      | Disables demotion. Many low-confidence durable memories were exposed, and the sweeper's "never recalled" clause is effectively always true here — recall runs rarely against a large store.                                                                       |

### LLM budget — the model, the token cap, and the assessment sweep

Set after the shared opencode.ai `zen/go` monthly quota was exhausted. memini was the cluster's
dominant LLM consumer and was pinned to the least efficient model available.

| Setting                     | Value                    | Why                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| --------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_LLM_MODEL`          | `opencode-go/minimax-m3` | Was `opencode-go/deepseek-v4-flash`. The 2026-08-16 bake-off in `hermes.md` measured deepseek at **7,934 completion tokens / 35.9s** on a task minimax-m3 answered correctly in **129 tokens / 1.9s** — ~60x for no accuracy gain. That result was applied to hermes and missed here.                                                                                                                                                                                                                         |
| `MEMINI_LLM_MAX_TOKENS`     | `8192`                   | Ships **with** the model swap, not after it. `0` keeps the client's built-in 4096 budget, and hidden reasoning tokens are spent inside it — minimax-m3 is `supportsReasoning: true`, so a blown budget returns `finish_reason: length` and the whole pipeline call is silently lost.                                                                                                                                                                                                                          |
| `MEMINI_ASSESS_INTERVAL`    | `6h`                     | Default `1h`. The importance-backfill sweep is the actual call-volume driver: hourly x `ASSESS_MAX_PER_RUN` rows in batches of `ASSESS_BATCH` is up to ten LLM calls an hour on top of dedup. It is a backlog drain, so a longer interval costs drain latency, not capability.                                                                                                                                                                                                                                |
| `MEMINI_ASSESS_MAX_PER_RUN` | `100`                    | Default `200`. Halves the per-tick ceiling for the same reason.                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `MEMINI_ASSESS_BATCH`       | `10`                     | Default `20`. Set 2026-09-06: `minimax-m3` returns a well-formed `{"scores":[…]}` array that is one or two entries short of a 20-item batch, and memini treats a positional length mismatch as a lost batch. A failure in the **first** batch abandons the entire pass, so at batch 20 the sweep wrote nothing at all. Not truncation — `finish_reason: stop` at ~100 completion tokens against an 8192 cap, so raising `MEMINI_LLM_MAX_TOKENS` does nothing here. At batch 10 the same 100 rows assessed 90. |
| `MEMINI_CHUNK_EMBED`        | `true`                   | Purely additive recall: long memories are also embedded in overlapping segments, so a match past `EMBED_MAX_ITEM_CHARS` is reachable instead of only the prefix. Runs on the **local** `qwen3-embedding`, so it costs no upstream quota. Built by the `BACKFILL_INTERVAL` loop, not at write time.                                                                                                                                                                                                            |

**The cap is a ceiling, not a reservation.** Raising `MEMINI_LLM_MAX_TOKENS` does not increase
spend on calls that answer briefly — it only prevents a long answer being truncated into a lost
call. Truncation is the more expensive failure, because the tokens are spent either way and the
result is discarded.

**Do not "fix" a quota outage by picking a smaller-sounding model.** All eight LiteLLM models are
served by one opencode.ai workspace on one monthly quota, so there is no cheaper tier to drop to
and no fallback that crosses a provider boundary. `minimax-m3` already _is_ the low-cost option
here; `deepseek-v4-flash` is the expensive one wearing a fast-sounding name. See
`.agents/references/hermes.md` § Model selection is measured, not assumed.

### Known-remaining items

- **`memini reembed` is no longer owed.** Checked 2026-09-06: every stored memory has a vector,
  so there is nothing for it to repair. `reembed` is a whole-store rewrite for switching embedding
  models, not a gap-filler — running it would re-embed every row on a CPU-only 0.6B embedder for
  no gain.
- **`MEMINI_RERANK_MIN_SCORE` is still `0` (off)** and is the only thing that can cut the
  confident-noise tail — a nonsense probe query returned 13 hits topping 0.93. It is
  **model-specific and must be swept**, never copied from a doc. The 500s are gone, but the
  sweep means little while a deep pool still sits near the rerank timeout (see the
  `jina-reranker` item below). It cannot be swept per request, and recall responses never
  return the rerank score, so sweep offline: score (query, candidate) pairs against `/v1/rerank`
  directly, or use the memini repo's `go run ./cmd/bench -rerank-gate`.
  [#2753](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2753)
- **`MEMINI_ASSESSED_SALIENCE_WEIGHT` is still `0`.** The assessment sweep runs and is paid for,
  but at weight 0 its score feeds only the rerank-pool reservation (`RECALL_IMPORTANCE_RESERVE`)
  — it decides which candidates the reranker sees, never how they are ordered. Raising it is the
  way to actually use what the sweep produces, but it is a lifecycle knob as well as a ranking
  one: salience feeds short-term cap eviction, briefing order and dedup survivor selection. The
  docs say bench it first, so it was left alone.
  [#2754](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2754)
- **`jina-reranker` runs `uBatchSize: 2048` and a 1-core CPU request** (2026-10-13,
  [#2755](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2755)). 2048 removed the HTTP 500s:
  a 4000-char pair now scores. `MAX_DOC_CHARS` still stays at 1800, because the binding limit is
  now CPU, not batch size. Measured on ymir: a 25-doc pool took **54s at 4000 chars and 22s at
  1800**, against a 20s `MEMINI_RERANK_TIMEOUT`. At 4000 every recall timed out and fell back to
  composite order. ymir has 4 cores shared with `qwen3-embedding` (~1.5–1.9 cores busy around the
  clock) and frigate, and at the old 100m request the reranker lost that contention. Even a
  single 200-char doc took 3.7s. Do not raise `MAX_DOC_CHARS` or `RERANK_POOL` until the reranker
  has CPU to spare. Time a pool by hand first: POST 25 docs to `/v1/rerank` through a
  port-forward.

### The client side is the bigger lever on "memory feels unused"

When tuned, recall events were far rarer than `remember` events, with zero `answer` events.
Saving is not the problem; recall is barely invoked. The knobs that matter are client behaviour
defaults served from `PUT /v1/settings/defaults`, **not** helmrelease env: `recall_limit`,
`inject_recall_min_score`, `inject_pretool_min_score`, `inject_briefing_facts`. Read the live
values with `GET /v1/settings/defaults`, which is safe and needs no write. At tuning time a 0.5
floor cut close to the median composite score. Raise **one at a time** and watch the `inject`
activity events — moving all four at once floods context and produces the opposite complaint.

**A client env var beats the served default.** The plugin resolves each knob as env, then server,
then built-in (`effectiveSetting()` in the plugin's generated client script). The hooks read
the server side from the `POST /v1/handshake` response, not from `/v1/settings/defaults`.
`~/.claude/settings.json` sets `MEMINI_INJECT_RECALL_MIN_SCORE` and
`MEMINI_INJECT_PRETOOL_MIN_SCORE` to `0.6`, so Claude Code on this machine injects at **0.6**,
while the served `0.5` applies only to clients without the env var. The 0.6 is kept on purpose
([#2758](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2758)). Change it in
`settings.json`, not through `PUT /v1/settings/defaults`, or the change will not reach this
machine.
`request_timeout_ms` (served `30000` when checked) is the ceiling `MEMINI_RERANK_TIMEOUT` must
stay under.

---

## Namespace Topology

Namespaces are hierarchical; the layout is:

```text
homelab/                    shared across both clusters
├── homelab/Artemis-Cluster this repo
└── homelab/frostlink       the Oracle Cloud cluster
personal/exikle             follows the user everywhere (MEMINI_HOME)
```

Resolution is by **server-side pin** (`GET`/`PUT /v1/pins`), so it follows across machines and
every client — hooks, MCP tools, CLI — agrees.

**Each repo has two pin keys, not one.** A remote pin alone does not cover a checkout with no
remote configured, or a probe that only ever sees a path:

| Key                                           | → namespace               |
| --------------------------------------------- | ------------------------- |
| `remote:git.dcunha.io/exikle/artemis-cluster` | `homelab/Artemis-Cluster` |
| `path:/home/exikle/Artemis-Cluster`           | `homelab/Artemis-Cluster` |
| `remote:git.dcunha.io/exikle/frostlink`       | `homelab/frostlink`       |
| `path:/home/exikle/frostlink`                 | `homelab/frostlink`       |

The remote key is **lowercased** (`artemis-cluster`) while the namespace it maps to keeps the
capital A. Do not "correct" the key to match the namespace; it is matched against a normalised
remote.

`dotfiles/home/claude/settings.json` (symlinked to `~/.claude/settings.json`) sets no
`MEMINI_NAMESPACE`. It sets `MEMINI_NAMESPACE_PREFIX` to `homelab`, `MEMINI_HOME` to
`personal/exikle` and `MEMINI_BASE_URL` to `https://memini.dcunha.io`.

**After changing a pin, run `/reload-plugins`.** The MCP `headersHelper` runs only when the
server connects, so until it reconnects the hooks and the MCP tools point at different
namespaces — memory half-works and nothing reports an error.

### How the cascade actually flows

| Direction             | What crosses                                              |
| --------------------- | --------------------------------------------------------- |
| child → parent (up)   | durable tiers, read-only, always on under `scope: "full"` |
| parent → child (down) | only via a per-call `scope: "everywhere"`                 |
| sibling → sibling     | **nothing** — this is why the explicit link still exists  |
| any write             | stays put unless `visibility:` names an ancestor          |

`homelab/Artemis-Cluster` keeps **two** explicit links, and neither is made redundant by the
shared parent — siblings inherit nothing from each other:

| src                       | dst                 | tiers that cross                  |
| ------------------------- | ------------------- | --------------------------------- |
| `homelab/Artemis-Cluster` | `homelab/frostlink` | `semantic`, `procedural` **only** |
| `homelab/Artemis-Cluster` | `fingerjoin`        | all tiers                         |

**The frostlink link is tier-restricted.** Episodic memories — the session-by-session narrative —
do not cross it. That is deliberate (one cluster's incident timeline is noise in the other), but
it means "I know we hit this on frostlink" will not surface from an Artemis session unless the
lesson was written as a durable semantic or procedural fact. If it matters to both clusters,
write it with `visibility: "homelab"` rather than relying on the link.

Links are directional: nothing flows from `homelab/frostlink` back to `homelab/Artemis-Cluster`
unless a matching link is created there too.

### Write routing — the rule

Default project visibility is right for almost everything. Reach for `visibility: "homelab"`
**only when the fact is true of both clusters and would otherwise have to be learned twice.**

| Fact                                                               | Goes to                   |
| ------------------------------------------------------------------ | ------------------------- |
| Ceph PG counts, OSD memory, `apply-ks` suspend behaviour           | `homelab/Artemis-Cluster` |
| openebs-zfs restore mechanics, the towonel edge                    | `homelab/frostlink`       |
| Canonical Forgejo remote is `Exikle` with a capital E              | `homelab`                 |
| "No Comments in Manifests" applies in both repos                   | `homelab`                 |
| The two clusters are **not** symmetric — cert-manager only Artemis | `homelab`                 |
| "prefers to confirm before merging to main"                        | `personal/exikle`         |

A good test: if the sentence names one cluster's hardware or storage layer, it is project-level.
If it names a convention, a workflow, or a difference _between_ the two, it is `homelab`.

### Known-open

- **MCP connects used to send no namespace — fixed in the wrapper, not the plugin.** Captured
  live 2026-10-13 (Claude Code 2.1.296, plugin 0.7.35): Claude Code runs the MCP
  `headersHelper` as `/bin/sh -c ~/.claude/scripts/memini-headers.sh` with the cwd set to the
  **plugin root** and no `CLAUDE_PROJECT_DIR`. The plugin's `resolveHarnessCwd()` tries
  `CLAUDE_PROJECT_DIR`, then the parent's cwd (rejected as the plugin root), then a session file
  keyed to the wrong pid. All three fail, so it emits auth-only headers and every MCP call lands
  in the server default `homelab` (`MEMINI_DEFAULT_NAMESPACE`). Hooks were never affected —
  they get `cwd` on stdin. The `claude` process one level up sits in the project dir, so
  dotfiles `home/claude/scripts/memini-headers.sh` now walks ancestors to the first cwd outside
  the plugin cache and exports it as `CLAUDE_PROJECT_DIR`
  ([#2756](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2756)). The fix takes effect on
  the next MCP connect (`/mcp` → reconnect; `/reload-plugins` does not reconnect).

    **Check the scope, do not assume it.** A recall hit whose `namespace` is `homelab` with no
    `from` field means the MCP side resolved to `homelab` itself — the fallthrough is back. The
    connect log `~/.cache/claude-cli-nodejs/<project>/mcp-logs-plugin-memini-memini/*.jsonl`
    should say "retrieved 3 headers"; 2 means no namespace was sent.

- **Junk namespaces from the old fallthrough were cleaned 2026-10-13.** `containers`,
  `dotfiles`, `memory` and `Rensaio` held 269 memories; 42 were reassigned to their real
  namespace and the rest forgotten
  ([#2757](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2757)). A namespace matching a
  directory basename is still the signature of a cwd probe landing somewhere it should not —
  check `GET /v1/namespaces` before assuming a project's memories are gone.

- **`hermes` is a real namespace, not junk.** The hermes deployment sets
  `MEMINI_NAMESPACE: hermes` explicitly (`kubernetes/apps/cortex/hermes/app/helmrelease.yaml`),
  so the agent's own memory is deliberately isolated from the repo namespaces. Do not fold it
  into `homelab/*` — that would put an unattended agent's writes into the namespace your own
  sessions read.
- **Promotion to `homelab` is incremental.** Three seed facts were promoted by hand. The rest
  arrive naturally by writing new cross-cluster lessons with `visibility: "homelab"` — there is no
  need for a bulk curation pass, and bulk-move-by-filter does not exist anyway.
