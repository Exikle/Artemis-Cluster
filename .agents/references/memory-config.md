# Memory & MCP Configuration

How AI agents get tools and long-term memory in this repo. Keep this current when the MCP layout
or memory system changes. Verified against the live cluster and the memini server 2026-08-29.

---

## Five registration files — keep them in sync

This doc said "two" until 2026-08-29. There are **five**, and only two of them live in this repo.
Adding or retiring a tier means editing every row:

| File                                                 | Client                               | Auth mechanism                                                         | In this repo?                                     |
| ---------------------------------------------------- | ------------------------------------ | ---------------------------------------------------------------------- | ------------------------------------------------- |
| `.mcp.json`                                          | Claude Code, this repo               | `headersHelper … <tier>` resolves a per-tier bearer token at call time | yes                                               |
| `opencode.json`                                      | opencode, this repo                  | `{env:MCP_<TIER>_KEY}` / `{env:MEMINI_API_KEY}` from `.env`            | yes                                               |
| `~/frostlink/.mcp.json`                              | Claude Code, frostlink repo          | same helper, same per-tier argv                                        | no — other repo                                   |
| `~/.claude/local-marketplace/dcunha-tools/.mcp.json` | Claude Code, **every other project** | same helper, same per-tier argv                                        | no — not chezmoi-managed either                   |
| Windows Zed `%APPDATA%/Zed/settings.json`            | Zed                                  | keys inlined in plaintext                                              | no — Windows filesystem, no automation reaches it |

**The tier argument is load-bearing.** `litellm-headers.mjs` maps tier → `MCP_<TIER>_KEY` →
`op://artemis/litellm/<FIELD>`, and **omitting it falls back to `MASTER_KEY`**. frostlink and the
global marketplace registration both omitted it until 2026-08-29, so every non-Artemis project
was authenticating the privileged ops tier as master. If you add a registration, pass the tier.

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
            "headersHelper": "node /home/exikle/.claude/scripts/litellm-headers.mjs"
        },
        "litellm-media": { "...": "same shape, /media/mcp" },
        "litellm-ops": { "...": "same shape, /ops/mcp" }
    }
}
```

**Tiers and their tools:**

Eleven `LiteLLMMCPServer` CRs, each pinned to one tier by `spec.params.access_groups`. The **alias**
is what prefixes the tool names a client sees, so it is the name to match on:

| Tier              | URL                                     | alias (`access_groups`)                             |
| ----------------- | --------------------------------------- | --------------------------------------------------- |
| `litellm-general` | `https://litellm.dcunha.io/general/mcp` | `searxng`, `victoria_logs`, `context7`, `grafana`\* |
| `litellm-media`   | `https://litellm.dcunha.io/media/mcp`   | `arr`, `seerr`                                      |
| `litellm-ops`     | `https://litellm.dcunha.io/ops/mcp`     | `k8s`, `flux`, `github`, `forgejo`, `ha`            |

One `litellm` proxy, tiers separated by URL path + `access_groups`. Each tier authenticates with
its **own virtual key** (`op://artemis/litellm/MCP_<TIER>_KEY`), not the master key, so a leak or a
runaway is scoped to one tier. `litellm-ops` has privileged cluster access — agent clients
only, never exposed to a general-purpose chat frontend.

`context7` is the only remote server (`https://mcp.context7.com/mcp`); the other ten run as
Deployments in `cortex` and resolve to `http://mcp-<name>.cortex.svc.cluster.local:<port>/mcp`.

**\* `grafana` served no tools from deployment until 2026-08-29. The cause is now known and
fixed.** It was `-allowed-hosts`, which defaults to _loopback variants of `-address`_. We bind
`-address 0.0.0.0:8000` and litellm dials the service FQDN, so every request was rejected `403`
before reaching the MCP handler — while the `LiteLLMMCPServer` reconciled clean and the pod stayed
`1/1 Running`. Proven from the litellm pod: FQDN Host → 403, `Host: localhost:8000` → 200.

The general tier now exposes 39 grafana tools. Full detail in
`.agents/references/cortex-mcp.md` § grafana.

The durable lesson stands even though this instance is fixed: **`Ready=True` on the CR proves the
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

It replaced the earlier `mempalace` MCP server — there are no `mempalace.yaml` or `entities.json`
files in this repo; routing and scoping are handled by the plugin itself, not by repo-local
config.

> **Resolved 2026-08-29.** This block used to warn that `opencode.json` pinned the flat,
> pre-2026-08-22 `X-Memini-Namespace: Artemis-Cluster`. It now reads `homelab/Artemis-Cluster`
> and the two clients agree. The trap itself is still real and worth knowing: **an explicit
> header beats the server-side pin, and neither client errors** — so a stale header silently
> splits reads and writes across two namespaces. The one place still carrying the flat name is
> the Windows Zed config, which therefore writes somewhere nothing reads.

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

Tuned 2026-08-21 from a diagnosis against the live deployment. The manifest carries no comments
(see `yaml-conventions.md` § No Comments in Manifests), so the reasoning for each value lives
here. Primary source: `docs/guides/tuning-recall.md` in the memini marketplace checkout.

**All six values below re-verified against `deploy/memini -n cortex` on 2026-08-21** — the
deployment matches this table exactly, and `MEMINI_RERANK_MIN_SCORE` is genuinely still unset.

**Diagnose before tuning.** `memini doctor` first, every time. A namespace mismatch — writes
landing in one namespace while recall reads another — is the most common cause of "memini forgot
everything", and no ranking knob can fix a pointer problem. Read set for
`homelab/Artemis-Cluster` is the repo, its `homelab` ancestor, `personal/exikle` (home), and two
links (`homelab/frostlink`, `fingerjoin`).

| Setting                         | Value    | Why                                                                                                                                                                                                                                                               |
| ------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_WRITE_EMBED_TIMEOUT`    | `20s`    | The unset default is 5s. The pod logged 47 `embed_timeout` write failures in 20h, each storing a memory with **no vector** — permanently invisible to semantic recall. Recall had 20s; the write path never did.                                                  |
| `MEMINI_RERANK_MAX_DOC_CHARS`   | `1800`   | `jina-reranker` runs llama.cpp with `uBatchSize: 1024`, and a rerank pair must fit one physical batch. At 4000 chars pairs measured 1042–1244 tokens and the backend returned HTTP 500, which memini swallows as a silent fallback to composite order.            |
| `MEMINI_RERANK_POOL`            | `25`     | Default `0` reranks only the results already being returned, so the cross-encoder can never rescue a memory that fused retrieval placed below the cut — which is most of what it is for. Started at 25, not the ~50 ceiling, because this is a CPU-only reranker. |
| `MEMINI_RERANK_MAX_BATCH_CHARS` | `120000` | The `6000` default shards a deep pool into many **serial** requests, which blows the rerank timeout far more easily than a large body does. It is an HTTP payload guard, not a context guard — each pair is scored in its own forward pass.                       |
| `MEMINI_RERANK_TIMEOUT`         | `20s`    | Headroom for the deeper pool. Must stay **below** the client ceiling (`request_timeout_ms`, currently 30000) or a slow rerank makes the client hang up first and recall returns nothing instead of degrading to composite order.                                  |
| `MEMINI_DEMOTE_AFTER`           | `0`      | Disables demotion. 483 low-confidence durable memories were exposed, and the sweeper's "never recalled" clause is effectively always true here — recall has run ~63 times against 1841 memories.                                                                  |

### LLM budget — the model, the token cap, and the assessment sweep

Set 2026-08-28, after the shared opencode.ai `zen/go` monthly quota was exhausted and every
model in `cortex` began returning `429 GoUsageLimitError`. memini was the cluster's dominant
LLM consumer — 126 chat completions against hermes's 15 over the same three-hour window — and
it was pinned to the least efficient model available.

| Setting                     | Value                    | Why                                                                                                                                                                                                                                                                                                |
| --------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_LLM_MODEL`          | `opencode-go/minimax-m3` | Was `opencode-go/deepseek-v4-flash`. The 2026-08-16 bake-off in `hermes.md` measured deepseek at **7,934 completion tokens / 35.9s** on a task minimax-m3 answered correctly in **129 tokens / 1.9s** — ~60x for no accuracy gain. That result was applied to hermes and missed here.              |
| `MEMINI_LLM_MAX_TOKENS`     | `8192`                   | Ships **with** the model swap, not after it. `0` keeps the client's built-in 4096 budget, and hidden reasoning tokens are spent inside it — minimax-m3 is `supportsReasoning: true`, so a blown budget returns `finish_reason: length` and the whole pipeline call is silently lost.               |
| `MEMINI_ASSESS_INTERVAL`    | `6h`                     | Default `1h`. The importance-backfill sweep is the actual call-volume driver: hourly x `ASSESS_MAX_PER_RUN` rows in batches of `ASSESS_BATCH` (20) is up to ten LLM calls an hour on top of dedup. It is a backlog drain, so a longer interval costs drain latency, not capability.                |
| `MEMINI_ASSESS_MAX_PER_RUN` | `100`                    | Default `200`. Halves the per-tick ceiling for the same reason.                                                                                                                                                                                                                                    |
| `MEMINI_CHUNK_EMBED`        | `true`                   | Purely additive recall: long memories are also embedded in overlapping segments, so a match past `EMBED_MAX_ITEM_CHARS` is reachable instead of only the prefix. Runs on the **local** `qwen3-embedding`, so it costs no upstream quota. Built by the `BACKFILL_INTERVAL` loop, not at write time. |

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

- **`memini reembed` is owed.** Memories already written without a vector do not repair
  themselves. Run it once `MEMINI_WRITE_EMBED_TIMEOUT` is live. It is slow against a CPU-only
  0.6B embedder — schedule it, do not run it interactively.
- **`MEMINI_RERANK_MIN_SCORE` is still `0` (off)** and is the only thing that can cut the
  confident-noise tail — a nonsense probe query returned 13 hits topping 0.93. It is
  **model-specific and must be swept**, never copied from a doc, and the sweep is meaningless
  until the rerank 500s are gone.
- **`MEMINI_ASSESSED_SALIENCE_WEIGHT` is still `0`.** The assessment sweep runs and is paid for,
  but at weight 0 its score feeds only the rerank-pool reservation (`RECALL_IMPORTANCE_RESERVE`)
  — it decides which candidates the reranker sees, never how they are ordered. Raising it is the
  way to actually use what the sweep produces, but it is a lifecycle knob as well as a ranking
  one: salience feeds short-term cap eviction, briefing order and dedup survivor selection. The
  docs say bench it first, so it was left alone.
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

All four confirmed still at those values on 2026-08-21 (`GET /v1/settings/defaults`, which is
safe to read and needs no write). `request_timeout_ms` is `30000` — the ceiling
`MEMINI_RERANK_TIMEOUT` must stay under.

---

## Namespace Topology

Restructured 2026-08-22, verified against `GET /v1/pins` and `GET /v1/namespaces` the same day.
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

A pin beats `MEMINI_NAMESPACE`, which is set to `homelab` in
`dotfiles/home/claude/settings.json` (symlinked to `~/.claude/settings.json`) purely as a floor
for sessions that resolve to nothing. `MEMINI_HOME` is `personal/exikle` and
`MEMINI_BASE_URL` is `https://memini.dcunha.io`, both from the same file.

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

- **The `default` fallthrough is NOT mitigated.** The MCP `headersHelper` resolves only at
  connect, and when its cwd probes all fail it emits auth-only headers with no namespace, so the
  server falls through to `MEMINI_DEFAULT_NAMESPACE`, which is literally `default` on the
  deployment. Diagnosed from 796 handshakes and from the stranded pool being 100%
  semantic/procedural with zero episodic — a signature only the MCP surface can produce.

    `MEMINI_NAMESPACE=homelab` was believed to catch it. **It does not.** Observed 2026-08-21: a
    session whose cwd was `/home/exikle/frostlink` — a path with a pin — resolved to
    `Scope: default ← personal/exikle(5)`. The floor did not apply, and nothing errored; recall
    simply returned the wrong project's memories with full confidence.

    **Check the scope line, do not assume it.** `memory_briefing` prints `scope_header`; if it says
    `default`, stop and fix the pin before writing anything. Subagent and hook contexts are the
    most likely to miss the env floor.

    Root cause still needs a `MEMINI_DEBUG=1` capture at connect and the 0.7.15 → 0.7.18 plugin
    upgrade.

- **`GET /v1/namespaces` shows the fallthrough's fingerprints.** Alongside the intended
  namespaces it lists `containers`, `dotfiles`, `memory`, `Rensaio` and `tool-results` — the last
  is a scratch directory name, which is only reachable by a cwd probe landing somewhere it should
  not have. Treat any namespace that matches a directory basename as junk, and check before
  assuming a project's memories are gone: they may be in one of these.

- **`hermes` is a real namespace, not junk.** The hermes deployment sets
  `MEMINI_NAMESPACE: hermes` explicitly (`kubernetes/apps/cortex/hermes/app/helmrelease.yaml`),
  so the agent's own memory is deliberately isolated from the repo namespaces. Do not fold it
  into `homelab/*` — that would put an unattended agent's writes into the namespace your own
  sessions read.
- **Promotion to `homelab` is incremental.** Three seed facts were promoted by hand. The rest
  arrive naturally by writing new cross-cluster lessons with `visibility: "homelab"` — there is no
  need for a bulk curation pass, and bulk-move-by-filter does not exist anyway.
