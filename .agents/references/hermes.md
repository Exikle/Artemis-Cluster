# Hermes — Artemis-Cluster

Operational reference for the Nous Research **hermes-agent** running in `cortex`. Deployed
2026-08-14, ported from [eleboucher/homelab](https://git.erwanleboucher.dev/eleboucher/homelab).
The port is finished; nothing here describes how to redo it. Verified against the live
deployment 2026-09-07 (HelmRelease `hermes.v58`, image `nousresearch/hermes-agent:v2026.8.16.2`).

**Read § Cost before changing anything about models, cron cadence or the MCP tier.** hermes is
the cluster's largest inference consumer and the OpenCode Go allowance is a hard monthly ceiling,
not a bill.

Manifests: `kubernetes/apps/cortex/hermes/`. Skills that ship from git:
`kubernetes/apps/cortex/hermes/app/skills/`.

---

## What it is

One Deployment, `strategy: Recreate`, two containers over a shared RWO PVC:

| Container    | Image                       | Role                                                        |
| ------------ | --------------------------- | ----------------------------------------------------------- |
| `app`        | `nousresearch/hermes-agent` | the agent gateway — dashboard `:9119`, health `:8642`, cron |
| `codeserver` | `ghcr.io/coder/code-server` | `:12321`, tinyauth-gated, edits `/opt/data` directly        |

Three init containers run in order:

1. `copy-agent-source` — copies `/opt/hermes` into an emptyDir. Its `cp` failure is tolerated on
   purpose: hermes-agent ships root-only playwright `.deps` files, and the script re-fails on any
   error that is not `Permission denied`.
2. `init` — writes `config.yaml` and `.env`, then three-way-syncs the git skills (below).
3. `install-tools` — downloads `gh` 2.61.0, Go 1.23.5 and Homebrew into the PVC, each guarded by
   an existence check so a restart is fast.

`$HOME` is `/opt/data`, which is the `hermes` PVC (4Gi `miroir`, `existingClaim: hermes`
from `components/kopiur/backup`). It holds the home directory, installed tooling, the skill
library, cron state and session history — that is why `Recreate` is mandatory (a RollingUpdate
deadlocks on Multi-Attach) and why the volume is backed up.

Two routes, both on `internal-gateway`:

| Hostname                | Backend port | Auth                                            |
| ----------------------- | ------------ | ----------------------------------------------- |
| `hermes.dcunha.io`      | `9119`       | pocket-id OIDC, `GATEWAY_ALLOWED_USERS: exikle` |
| `hermes-code.dcunha.io` | `12321`      | tinyauth (`components/tinyauth`)                |

code-server itself runs `--auth none`; its only gate is the tinyauth SecurityPolicy the
`components/tinyauth` component attaches to the `hermes-codeserver` route
(`HTTP_ROUTE_TARGET` in `ks.yaml`). Both routes stay on `internal-gateway` — do not attach
either to `external-gateway` or `edge-gateway`.

### Deps and wiring

| Depends on | Address                                    | Purpose                            |
| ---------- | ------------------------------------------ | ---------------------------------- |
| LiteLLM    | `litellm.cortex.svc.cluster.local:4000/v1` | all inference, `LITELLM_API_KEY`   |
| memini     | `memini.cortex.svc.cluster.local:8080`     | memory, namespace **`hermes`**     |
| SearXNG    | `searxng.cortex.svc.cluster.local:8080`    | web search                         |
| chaski     | `chaski.observability.svc.cluster.local`   | Pushover notifications from skills |
| Forgejo    | `git.dcunha.io` as **dusk-bot**            | PRs and commits                    |

`ks.yaml` `dependsOn` is `litellm-operator`, `memini`, and `security/pocket-id-operator` — the
operators, not the workloads, because the CRs they own are what hermes needs to exist.

**memini namespace is `hermes`, deliberately isolated.** The agent's memories do not mix with
`homelab/Artemis-Cluster`. See `.agents/references/memory-config.md` § Namespace Topology.

### Secrets

`hermes-config` is assembled by one ExternalSecret from **three** 1Password items:

| Env                                       | 1Password item → field                                         |
| ----------------------------------------- | -------------------------------------------------------------- |
| `LITELLM_API_KEY` / `SUMMARY_LLM_API_KEY` | `litellm-key-hermes` (its own virtual key, not the master key) |
| `MEMINI_API_KEY`                          | `memini` → `MEMINI_API_KEY`                                    |
| `HERMES_DASHBOARD_OIDC_CLIENT_SECRET`     | `hermes` → `HERMES_OIDC_CLIENT_SECRET`                         |
| `API_SERVER_KEY`                          | `hermes` → `API_SERVER_KEY`                                    |
| `FORGEJO_PAT`                             | **`dusk-bot` → `DUSK_BOT_PAT`**                                |

The secret also pulls `/opt/data/.env` content via `templateFrom` on the `hermes-configmap`
`env` key — so an edit to the ConfigMap changes the Secret, and Reloader restarts the pod.

**`FORGEJO_PAT` is dusk-bot's, not Exikle's.** It was Exikle's until 2026-08-16, which attributed
every skill-merged PR and skill-committed README to the human whose commits are otherwise
GPG-signed. dusk-bot holds admin+push on `Artemis-Cluster` and `frostlink`, and is the same
identity Renovate uses — so a hermes commit and a Renovate commit are indistinguishable by author.

---

## Model configuration

`config.yaml` lives in `hermes-configmap`. Eight `opencode-go` models are declared; **a model
LiteLLM serves but `custom_providers.litellm.models` omits is unusable by the agent.**

| Model                           | `context_length` | Alias      |
| ------------------------------- | ---------------- | ---------- |
| `opencode-go/minimax-m3`        | 1000000          | `minimax`  |
| `opencode-go/glm-5.2`           | 1048560          | `glm`      |
| `opencode-go/mimo-v2.5`         | 262144           | `mimo`     |
| `opencode-go/qwen3.6-plus`      | 262144           | `qwen`     |
| `opencode-go/qwen3.7-max`       | 262144           | `qwenmax`  |
| `opencode-go/kimi-k2.6`         | 262128           | `kimi`     |
| `opencode-go/kimi-k2.7-code`    | 262128           | `kimicode` |
| `opencode-go/deepseek-v4-flash` | 131072           | `dsv4f`    |

- **Default is `opencode-go/minimax-m3`.**
- **`model.context_length` is the compaction trigger, nothing else.** Upstream never uses it to
  truncate a request — `compression.threshold` (0.5) multiplies it to decide when to compact. It
  was `1000000` (minimax-m3's real window), which meant compaction fired at 500K tokens; it is now
  **262144**, so compaction fires at ~131K. Set it too high and a runaway session balloons before
  anything trims it; set it below the real window and you only pay for earlier compaction, never
  a provider error.
- **`auxiliary:` roles are on `minimax-m3`**, as is nothing else — `delegation` is on
  `mimo-v2.5`, the cheapest model on the account. The roles were pinned to `deepseek-v4-flash`
  until 2026-08-16, which put the least efficient model on exactly the small frequent tasks where
  its ~7,900-token overhead hurts most.
- `auxiliary.session_search` was removed 2026-09-07: upstream deleted that role (PR #27590) and
  it is not an LLM call. `web_extract` is likewise not an LLM call.
- **`app/virtualkey.yaml` gates what the key may call, and it is a second list to keep in sync.**
  It granted only `minimax-m3` and `mimo-v2.5` until 2026-09-07, so every `glm-5.2` fallback and
  every `SUMMARY_LLM_MODEL` call 403'd. It now grants all eight declared models — but **the
  automatic paths (default, fallbacks, `auxiliary`, `delegation`, `SUMMARY_LLM_MODEL`) are
  deliberately kept on `minimax-m3` and `mimo-v2.5`**; the rest exist so an interactive
  `@glm`/`@kimi` works. Nothing validates the two lists against each other and the failure is a
  403 at fallback time, when you are least watching.
- `fallback_providers` is `mimo-v2.5` only (was `glm-5.2` then `mimo-v2.5`) — glm-5.2 costs ten
  times minimax-m3 and a fallback fires exactly when the account is already under pressure.
- **No `moa` block.** A `council` preset was configured until 2026-09-07 and was always dormant:
  MoA is a virtual _provider_, so it only runs when `model.provider` is literally `moa`. Ours is
  `custom:litellm`. `moa.default_preset` names the preset the picker would use, it does not
  enable MoA. It was removed as a landmine, not as a cost saving.
- `SUMMARY_LLM_MODEL` is `opencode-go/mimo-v2.5` and is set in **env, not `config.yaml`** —
  changing the default model does not move it. It was `qwen3.6-plus`, which the virtual key does
  not grant.
- `agent.max_turns` is 40 (was 150) and `delegation` is 2 children / depth 1 (was 8 / 2, against
  an upstream default of 3 / 1). Both bound a single run's worst case.

### Model selection is measured, not assumed

**LiteLLM reported $0.000/Mtok for every opencode-go model until 2026-09-07, and that was a
reporting artifact, not the price** — real per-token costs are registered now; see § Cost. Within the account's allowance the selection criteria that remain are
accuracy and latency. Measured 2026-08-16 against the actual workload (emit the exact notification
JSON; and a tool call that must omit an unused parameter), 2 runs each:

| Model               | JSON contract | Tool call | Latency | Completion tokens |
| ------------------- | ------------- | --------- | ------- | ----------------- |
| `minimax-m3`        | 2/2           | 2/2       | 1.9s    | 129               |
| `glm-5.2`           | 2/2           | 2/2       | 5.7s    | 1007              |
| `mimo-v2.5`         | 2/2           | 2/2       | 13.1s   | 1222              |
| `deepseek-v4-flash` | 2/2           | 2/2       | 35.9s   | 7934              |
| `qwen3.6-plus`      | 2/2           | 2/2       | 35.5s   | 2444              |
| `qwen3.7-max`       | **1/2**       | 2/2       | 52.9s   | 3206              |
| `kimi-k2.6`         | **1/2**       | 2/2       | 103.3s  | 4384              |

`deepseek-v4-flash` burned 7,934 completion tokens and 36s on a task `minimax-m3` answered
correctly in 129 tokens and 1.9s — it is the least efficient option, not the most, despite the
"flash" name. `qwen3.7-max` miscounted (`fixed=1` where the answer was 2), which disqualifies it
for jobs whose entire output is counts. Re-run the bake-off before changing an assignment; do not
pick on model naming.

### kimi-k2.7-code rejects `temperature`

The provider 400s on **any** `temperature` value for that model, so every agent call failed while
a bare curl succeeded. Chart-wide `dropParams: true` does not help: LiteLLM only drops params it
knows a provider rejects, and for an OpenAI-compatible passthrough it assumes `temperature` is
supported. Fixed with a per-model `additional_drop_params: ["temperature"]`, driven by the
`dropTemperature` input in `litellmmodels.yaml`.

---

## Cost

**OpenCode Go is a $10/month subscription with a hard usage ceiling, not a bill.** The account is
metered in dollars of model value and cuts off when a window is exhausted:

| Window  | Allowance |
| ------- | --------- |
| 5 hours | $12       |
| 7 days  | $30       |
| Monthly | $60       |

Exhaustion returns `429 GoUsageLimitError` on **every** model at once — all eight models resolve
to one `opencode.ai/zen/go` workspace, which is why `fallback_providers` cannot rescue a quota
event (#1813). "You are at $60" means the allowance is spent, not that $60 was charged.

### LiteLLM's spend column was a lie until 2026-09-07

**Fixed 2026-09-07 — this section describes what was wrong and why the old numbers lie.** No
`input_cost_per_token` was registered on any `LiteLLMModel`, and LiteLLM has no built-in price map
for a custom-`apiBase` provider, so it computed **$0.00 for every opencode-go call** (#1832).
`maxBudget` and `tpmLimit` on a virtual key were therefore decorative and `rpmLimit` /
`maxParallelRequests` were the only live throttles. Prompt/completion/cache token counts were
always captured correctly.

The doc previously stated these models "bill at $0.000/Mtok". That was reading LiteLLM's
placeholder as a fact. They are ordinary paid models; `minimax-m3` is $0.30/$1.20 per Mtok with
cached reads at $0.06. Prices now come from <https://opencode.ai/docs/go/#usage-limits> and live
in the `inputCost` / `outputCost` / `cacheReadCost` inputs of `proxy/litellmmodels.yaml`
(deepseek uses the Peak rate — the off-peak window is not worth modelling). **Any spend figure
recorded before 2026-09-07 is zero and means nothing**; use `usage_audit.jsonl` for that period.

### What actually consumed the allowance

Measured 2026-09-07 from `/opt/data/cron/usage_audit.jsonl` (the per-fire token ledger, which is
the honest source — not LiteLLM's spend column):

| Metric                                 | Value                          |
| -------------------------------------- | ------------------------------ |
| `cluster-health` prompt tokens per run | **774,000 average**, 4.9M peak |
| Runs per day at `0 * * * *`            | 24                             |
| Prompt tokens per day                  | ~19M                           |
| Effective cost/day at ~69% cache reads | **~$2.60**                     |
| Implied monthly                        | **~$80** against a $60 cap     |

So the hourly audit alone overran the entire account, which is what exhausted the month on
2026-08-28 and pinned every consumer at 429 until the 2026-09-05 reset.

### The shape of a run, measured per call

A single post-fix run on 2026-09-07 (28 LLM calls, 4m48s), per-call `prompt_tokens` from
`/spend/logs`:

| Call | Prompt tokens |
| ---- | ------------- |
| 1    | 21,997        |
| 10   | 38,616        |
| 20   | 66,301        |
| 28   | 72,397        |

**Total 1,437,667 prompt tokens for $0.1175.** Two separate terms, and the second is the big one:

- **A fixed prefix, ~22,000 tokens** — system prompt, the skill, hermes's own native tool registry,
  the bundled-skill index, and the MCP tool schemas. Paid on call 1 and every call after.
- **Linear context growth, ~1,800 tokens/turn** of accumulated tool results. Because the whole
  context is resent every turn, **total cost is roughly `turns × average context`, which grows with
  the square of the turn count.** 28 turns averaging 51K is 1.44M; 14 turns averaging 35K would be
  under 0.5M.

So **turn count is the strongest lever, cadence is the second, and the fixed prefix is third** —
the reverse of what the first pass at this assumed. Cutting the MCP surface (below) took roughly
35K off the prefix, which is ~1M tokens over a 28-turn run and worth having, but it does not touch
the quadratic term.

Do not reason about a single run: the historical per-run range is **52K to 4.9M**. Judge a change
over a week of `usage_audit.jsonl`, never one sample.

### MCP tool schemas are charged on every turn

hermes mounted both the `ops` and `general` tiers, whose `tools/list` payloads measure 165KB and
81KB against `agent`'s 46KB. Measured directly:

```bash
# from inside the hermes pod, per access group
curl -s -X POST "http://litellm.cortex.svc.cluster.local:4000/<group>/mcp" \
  -H "Authorization: Bearer $LITELLM_API_KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: probe" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | wc -c
```

### The `agent` MCP access group

hermes now uses a fourth LiteLLM access group, `agent`, carrying only what its skills call:
`k8s`, `flux`, `searxng`, `victoria_logs`. Its endpoint is `/agent/mcp` and its payload is
**46KB / 52 tools** against `ops` + `general`'s 246KB / 180.

The group is additive — each server lists it alongside its existing tier
(`access_groups: ["agent", "ops"]`), so the `ops`, `general` and `media` tiers are unchanged and
Claude Code's own `.mcp.json` is unaffected. Adding a server to hermes's reach means appending
`"agent"` to that server's `access_groups` in
`kubernetes/apps/cortex/litellm/mcp/<name>/mcpserver.yaml` — **and paying its schema on every
turn of every run.** Weigh it against § Cost before doing so; `forgejo` alone is 40 tools and
`github` 44, neither of which any hermes skill calls (both skills reach Forgejo over `curl` with
`$FORGEJO_PAT`).

`allow_all_keys: true` on every server means no virtual-key change is needed to reach a new
group — access is by URL path.

### `x-opencode-session` is mandatory and LiteLLM injects it

OpenCode Go requires a stable `x-opencode-session` per conversation and **hard-rejects requests
without one**: `400 MissingSessionID — Request is missing x-opencode-session and cannot be routed
efficiently`. It is non-retryable, so it kills a whole cron fire. Enforcement widened during
2026-09-07: at 04:00 only `mimo-v2.5` (the `openai/`-prefixed `/zen/go/v1` path) rejected, and by
09:00 `minimax-m3` (the `anthropic/`-prefixed `/zen/go` path) did too. **Every model now requires
it.** For a few hours that took all hermes inference down.

Hermes cannot supply it and neither can LiteLLM forwarding:

- Hermes only emits the header when its provider or base URL matches `opencode-*` or an
  `opencode.ai` host. Ours is `custom:litellm` pointing at the in-cluster proxy, so it matches
  neither. The upstream fix (`NousResearch/hermes-agent` PR #101864) merged to `main` 2026-09-03,
  is in **no tagged release**, and would not apply to our provider shape anyway.
- `general_settings.forward_client_headers_to_llm_api` forwards a header the client never sends.
  Enabling it fixes nothing.

**So LiteLLM injects it per model**, in `proxy/litellmmodels.yaml` under `params.additional`:

```yaml
extra_headers:
    User-Agent: artemis-litellm/1.0
    x-opencode-session: artemis-<model>
```

Verified 2026-09-07: both models went 400 → 200 the moment the new proxy pod picked this up.
`User-Agent` is there because Go also asks clients to identify themselves and LiteLLM never
forwards the client's own.

**Know what this workaround is.** The id is stable per _model_, not per _conversation_, which is
what Go actually asks for — it is enough to pass the check but it gives their router one bucket
per model instead of one per session. Replace it with a real per-conversation id the moment
hermes ships PR #101864 in a tagged release **and** learns to emit for a custom provider. Do not
extend the trick anywhere else.

**Separately, this was never the caching story.** Caching already worked without the header —
measured 69% of hermes's prompt tokens and 90–94% of `minimax-m3`/`mimo-v2.5` input tokens are
cache reads, keyed server-side.

### Budgets are real controls again

`input_cost_per_token`, `output_cost_per_token` and `cache_read_input_token_cost` are now
registered on every `opencode-go` model (`proxy/litellmmodels.yaml`, from the Go price table), so
LiteLLM computes real spend instead of the placeholder $0.00 that made #1832's `maxBudget` and
`tpmLimit` inert. Verified: the hermes key's `/key/info` spend moved off zero on the first probe.

Every virtual key now carries a 30-day budget, summing to the account's $60 ceiling:

| Key            | 30d budget |
| -------------- | ---------- |
| `hermes`       | $20        |
| `opencode-cli` | $15        |
| `memini`       | $10        |
| `mcp-ops`      | $5         |
| `mcp-general`  | $5         |
| `mcp-media`    | $5         |

These are **per-consumer** caps, so one runaway job can no longer take the whole account down —
which is what happened on 2026-08-28. They are not a substitute for the reductions above; a key
that hits its budget stops working, which is a smaller outage than the account-wide 429 but still
an outage.

`maxBudget` is a **string** in the CRD. In `proxy/resourceset.yaml` the template must be
`<< inputs.maxBudget | quote >>` — writing `"<< inputs.maxBudget >>"` renders an int and the
ResourceSet fails its dry-run with `expected string, got &value.valueUnstructured{Value:20}`.

### If the allowance is tight again

In descending impact, per the per-call measurements above:

1. **Cut turns.** Cost grows with the square of the turn count. Shorten the skill's sweeps, drop
   optional steps, lower `agent.max_turns`. `cluster-health` lost its 125-line "Step 5 —
   Self-review and proposal" block on 2026-09-07 for exactly this reason: it ran every fire, added
   turns, and had produced 13 in-pod self-patches and zero commits to git.
2. **Widen the cron interval.** A linear multiplier on everything.
3. **Trim the `agent` MCP group** — worth ~35K per turn against the `ops` + `general` pairing, but
   it only moves the fixed prefix.
4. Lower `model.context_length` so a runaway compacts sooner.
5. Move a job to a cheaper model. `mimo-v2.5` is $0.14/$0.28; `glm-5.2` is $1.40/$4.40, ten times
   dearer.

**A measured budget check, so the cadence decision is arithmetic rather than a guess:** at
$0.1175/run, every-2-hours is 12 runs/day ≈ $42/month, which overruns the hermes key's $20 budget.
**Every 4 hours is 6 runs/day ≈ $21/month, and that is the cadence in use.** The measured run was a
catch-up after five consecutive failures and used 28 of its 40 turns, so it is an upper bound
rather than a typical fire — a quiet run has historically cost as little as 52K tokens. Re-measure
from `usage_audit.jsonl` after a week rather than trusting either number.

---

## Cron jobs

| Job              | Schedule      | Model                    |
| ---------------- | ------------- | ------------------------ |
| `cluster-health` | `0 */4 * * *` | `opencode-go/minimax-m3` |
| `readme-sync`    | `0 8 * * 0`   | `opencode-go/minimax-m3` |

`cluster-health` was an `interval: 60m` job until 2026-08-16. Interval schedules re-arm from
_completion_, so the run time drifted forward every hour (00:06 → 01:12 → …); the cron expression
pins it to a fixed minute, which matters when correlating a notification against an incident
timeline. It went hourly → **every four hours** on 2026-09-07 for cost (§ Cost); alertmanager
already pages in real time, so this job is a supplementary audit, not the alerting path.

`forgejo-pr-review` was **retired 2026-09-07**. It was the third-largest consumer on the account
and duplicated the human `triage-renovate` skill, which is the path actually used to merge the
Renovate queue. Its skill directory, ConfigMap and HelmRelease mounts are gone from git; the
in-pod copy under `/opt/data/skills/devops/` is inert once the cron job is removed, but the init
container no longer syncs it, so delete it by hand if you want it gone.

**Editing cron state needs the in-pod CLI, not a file edit.** `hermes cron edit <id> --schedule`,
`--model`, and `hermes cron remove <id>` write `jobs.json` with the right ownership. Hand-editing
the file over `kubectl exec` lands as uid 0 and locks the scheduler out of its own job list (see
below).

**`jobs.json` is runtime state on the PVC, not in git** (`/opt/data/cron/jobs.json`). Editing it:

- It is an object — `{"jobs": [...], "updated_at": ...}` — not a bare array.
- It is owned `hermes:hermes` and the scheduler runs as uid 1000, but `kubectl exec` lands as
  **uid 0**. Anything written that way must be `chown 1000:1000 && chmod 0664`'d immediately or
  the scheduler is locked out of its own job list.
- The dashboard API is behind pocket-id SSO (`no_cookie`), so it cannot be scripted with
  `API_SERVER_KEY` alone.
- Edit, fix ownership, then restart the deployment so the scheduler re-reads it.

```bash
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/cron/jobs.json
```

---

## Skills — install paths and the git/agent divergence trap

The agent's real skill library is **`/opt/data/skills/<category>/<name>/SKILL.md`**. That is where
its bundled skills live (97 `SKILL.md` files as of 2026-08-21) and where it keeps
`/opt/data/skills/.usage.json`, the registry carrying `use_count` / `last_used_at` / `patch_count`
per skill. The startup log prints `Syncing bundled skills into ~/.hermes/skills/ ...` — **that
string is wrong**; it actually syncs into `~/skills/`. Don't trust it, count
`find /opt/data/skills -name SKILL.md` instead.

Our three git-shipped skills land at:

| Skill            | In-pod path                                   |
| ---------------- | --------------------------------------------- |
| `cluster-health` | `/opt/data/skills/operations/cluster-health/` |
| `readme-sync`    | `/opt/data/skills/operations/readme-sync/`    |

They were originally copied to `/opt/data/.hermes/skills/<name>/`, a path the agent never reads.
Consequences, all of which actually happened: the agent ran a copy seeded once and never
refreshed from git (`forgejo-pr-review` sat at v1.0.0 in-pod for a day after v2.0.0 was
committed, still refusing to auto-merge bot PRs), and its own self-patches accumulated
unnoticed (`cluster-health` reached v1.2.1 in-pod against v1.0.0 in git).

Since 2026-08-16 the init copies to the real library paths. It does **not** copy blindly: a plain
`cp` there would let a routine pod restart silently destroy a self-patch the agent made in place.
Instead `sync_skill` does a three-way compare per skill — the incoming git copy, the live copy,
and `/opt/data/skills/.git-sync/<name>.sha` recording the git content installed last time:

| live vs git | live vs marker | Action                                                       |
| ----------- | -------------- | ------------------------------------------------------------ |
| same        | —              | already in sync; refresh marker, clear any parked copy       |
| differs     | same           | untouched since last sync → snapshot live, install git, mark |
| differs     | differs        | **locally self-patched → keep live**, park git, record drift |

So git updates flow normally, and a self-patch is never overwritten. The cost is that a diverged
skill **stops receiving git updates until reconciled** — deliberate, and made loud rather than
silent:

- `.git-sync/drift.current` is rewritten every boot; `cluster-health` reads it in its Step 2 sweep
  and reports any entry as `attention`, so a divergence shows up in Pushover within the hour.
- The incoming git version is parked at `.git-sync/incoming/<name>.SKILL.md`.
- Superseded live copies are snapshotted to `.git-sync/superseded/<ts>/` (last 10 kept), so even
  an overwrite on the "untouched" path is recoverable.

### Reconciling a drifted skill

Two cases, and the second is the common one:

1. _Git ends up byte-identical to the live copy_ (you committed exactly the self-patch and nothing
   else) — the next restart sees `live == git`, clears the drift and the parked copy, and updates
   resume. Nothing else to do.
2. _Git carries additional changes_ (you merged the self-patch **and** edited the skill) —
   committing is **not** enough. `live` still differs from the new `git`, so the guard keeps
   holding the old live copy and your edits never install. After merging, explicitly accept git's
   version by writing it over the live file, then restart:

```bash
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex get cm hermes-skill-cluster-health -o jsonpath='{.data.SKILL\.md}' > /tmp/merged.md
kubectl -n cortex exec -i "$POD" -c app -- sh -c '
  D=/opt/data/skills/operations/cluster-health
  cat > $D/SKILL.md.tmp && chown 1000:1000 $D/SKILL.md.tmp && chmod 0664 $D/SKILL.md.tmp
  mv $D/SKILL.md.tmp $D/SKILL.md' < /tmp/merged.md
kubectl -n cortex rollout restart deploy/hermes
```

Only do this once you have confirmed the merged copy is a **superset** — that it still contains
the agent's change. Diff it first; the whole point of the guard is that this step is a deliberate
human decision, not an automatic overwrite.

Verify the divergence first:

```bash
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/skills/.git-sync/drift.current
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/skills/operations/cluster-health/SKILL.md > /tmp/live.md
diff -u kubernetes/apps/cortex/hermes/app/skills/cluster-health/SKILL.md /tmp/live.md
```

Do not "fix" drift by deleting the live copy — that discards the agent's work, which is the exact
failure this machinery exists to prevent.

### Never write a file named `SKILL.md` outside a real skill

The sync guard originally parked git's copy at `<skill>/.git-incoming/SKILL.md`. Discovery is
`iter_skill_index_files(dir, "SKILL.md")` (`agent/skill_utils.py:990`), which matches the literal
filename anywhere beneath the skills root — **including dot-directories**. So parking a file
_named_ `SKILL.md` inside the tree registered a second skill under the same name, and every run
then failed with `Ambiguous skill name` and skipped the cron job entirely. The drift-parking
mechanism disabled the very skill meant to report the drift; the hourly audit was dead for ~27h
before anyone noticed.

Parks now go to `.git-sync/incoming/<name>.SKILL.md` — outside the skill tree, and not named
`SKILL.md`. That is the same naming the `superseded/` snapshots have always used, which is why
those never collided.

### `cp -n` for `references/`, plain `cp` for `scripts/`

`references/targetdown-triage.md` is an **append-only recurrence log** the skill writes to at
runtime, so init seeds it with `cp -n` (create-if-absent) and never clobbers it. Edits to that
file in git therefore do **not** propagate to a pod that already has one — to push a new version,
delete the in-pod copy and restart. The scripts directory inside the image is pure code and is
always overwritten.

### The chmod ordering trap

The init's `find /opt/data -user 1000 -type f -exec chmod 0664 {} +` runs late and strips the exec
bit off everything. Any `chmod +x` placed with the `cp` lines is silently undone; the
`find … -name '*.sh' -exec chmod 0775` line must stay **after** that blanket chmod.

### Scanner-safety is load-bearing for unattended runs

The agent's security scanner flags pipes-to-interpreter (`curl … | python3`) and inline
interpreter scripts (`python3 -c`) as HIGH and marks the command `pending_approval`. Skill
instructions must write to a file and parse it in a separate step, build JSON payloads with
`write_file` + `curl --data @file` rather than a heredoc, and use bash `date` math instead of
python for arithmetic. Note `write_file` refuses `/tmp` paths (protected) while `curl -o /tmp/...`
is fine.

### Building a Forgejo `contents` PUT payload

There is no shell path for this: heredocs are banned by the skills' own scanner rules and
`execute_code` is unavailable in cron. Use `read_file` on the base64 body and the GET response,
then `write_file` the JSON under `/opt/data/workspace` (inside `HERMES_WRITE_SAFE_ROOT`, where a
`/tmp` write would be refused). `readme-sync/SKILL.md` has carried the canonical shape since it
was written; `cluster-health` Step 5.3 was missing it, which is why its auto-commit branch could
never complete.

---

## Autonomy posture — what hermes is allowed to do unattended

Set 2026-08-18, after finding that hermes had self-patched its skills 13 times since 2026-08-16
and landed **zero** of them in git. Three independent gates were each sufficient to stop it on
their own.

### 1. Cron approvals (`approvals` in `configmap.yaml`)

`cron_mode: deny` blocked every `terminal` call the smart guardian flagged. Because the skills do
all their Forgejo and chaski work through `curl`, that killed both the self-improvement PR flow
_and_ the notification POST — the agent was silently unable to report that it was silently unable
to report. `execute_code` keys off the same setting (`tools/approval.py`), so no workaround
existed inside the pod.

Now `cron_mode: approve`, with enforcement moved to two floors that fire **before** any bypass
(`_match_user_deny_rule`, `tools/approval.py:3751`):

| Layer                           | Scope                    | Enforces in cron?                                                                                                                   |
| ------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| code-shipped hardline blocklist | `rm -rf /`, poweroff, …  | yes, always                                                                                                                         |
| `approvals.deny` fnmatch globs  | the `terminal` tool only | yes — the real control                                                                                                              |
| `approvals.smart_policy`        | guardian system prompt   | no — ESCALATE resolves to approve under `cron_mode: approve`; it still binds interactive and gateway sessions, and documents intent |
| `mcp-k8s` ClusterRole           | the MCP k8s tools        | yes — RBAC, not approvals                                                                                                           |

The split that matters: **deny globs bound the shell, RBAC bounds the cluster tools.** A glob like
`*kubectl*delete*` does not restrict `k8s_pods_delete`, and never could — that tool is gated by
the ClusterRole instead. Add a new deny glob with a leading and trailing `*`; matching is
case-insensitive over deobfuscated command variants, so quoting tricks do not sidestep it.

Current deny globs cover PR merge, force/main push, `talosctl`, `kubectl drain|cordon|delete`,
`flux uninstall|delete`, `helm uninstall`, `ceph osd`, `kubectl get secret`, `/opt/data/.env`,
and pipe-to-shell.

### 2. Two RBAC surfaces, not one — and they differ

This is the part most likely to be got wrong: hermes reaches the cluster **two ways**, under
**two different ServiceAccounts**, with materially different permissions.

| Surface                  | ServiceAccount | Reached via                      |
| ------------------------ | -------------- | -------------------------------- |
| `kubectl` inside the pod | `hermes`       | `terminal` tool, deny-glob gated |
| `k8s_*` MCP tools        | `mcp-k8s-sa`   | LiteLLM `agent` tier, RBAC gated |

**`hermes` (the pod's own SA)** — `hermes-read-all` ClusterRole (get/list/watch over core, apps,
batch, networking, storage, Flux `helm`/`kustomize`/`source`, external-secrets) plus:

- `hermes-pod-delete` — **ClusterRole**, `pods: delete`, cluster-wide
- `hermes-exec-deploy` — **Role, `cortex` only**: `pods/exec: create`, `deployments: patch,update`

So the pod can delete a pod anywhere, but can only exec or restart a Deployment **in `cortex`**.
It cannot patch Flux objects, cannot delete Jobs, and cannot write Events.

**`mcp-k8s-sa` (the MCP server)** — broader, and cluster-wide:
`pods: delete`, `pods/exec: create`, `events: create`, `jobs: delete`,
`deployments/statefulsets/daemonsets: patch,update` (restart and scale), and
`helmreleases`/`kustomizations`: `patch` (trigger a reconcile). Flux patch is safe to grant
because Flux re-derives desired state from git — the agent can ask for a reconcile but cannot
define what reconciles. It cannot create or delete workloads, and cannot touch Talos or
node-level state.

> **`mcp-k8s` no longer holds `secrets`.** The grant was removed on 2026-08-29 (see
> `cortex-mcp.md`); the ClusterRole now carries only the External Secrets CRs
> (`externalsecrets`, `secretstores`, `clustersecretstores`), which are references, not secret
> data. Verify before trusting either statement:
> `kubectl get clusterrole mcp-k8s -o jsonpath='{range .rules[*]}{.resources}{" -> "}{.verbs}{"\n"}{end}'`
>
> This block previously said the opposite and told you to treat the tier as
> credential-equivalent. It is still the most privileged tier, but not because it can read
> Secrets.
>
> The boundary is asymmetric by design, and the asymmetry is the thing to remember:
>
> | Path                   | ServiceAccount | Secret data | Bounded by                              |
> | ---------------------- | -------------- | ----------- | --------------------------------------- |
> | `terminal` → `kubectl` | `hermes`       | **no**      | `approvals.deny` `*kubectl*get*secret*` |
> | `k8s_*` MCP tools      | `mcp-k8s-sa`   | **yes**     | RBAC — `secrets: list`, cluster-wide    |
>
> The deny glob and the smart-policy ESCALATE rule bound the **shell** path only; they do not
> apply to the MCP path and never could, because approvals gate the `terminal` tool and RBAC gates
> the k8s tools. Do not read the glob as a cluster-wide Secret block — it is not one, and adding
> more globs will not make it one. The `hermes` ServiceAccount genuinely cannot read Secrets; the
> statement "hermes deliberately cannot read Secrets" is true of that SA and **false** of
> `mcp-k8s-sa`. The single control for the MCP path is the rule in
> `kubernetes/apps/cortex/litellm/mcp/k8s/rbac.yaml` (the `mcp-k8s` ClusterRole).

### 3. Skill park path

Covered above under § Never write a file named `SKILL.md` outside a real skill.

---

## Operational gotchas

**Probes.** The app container had none, so a hung gateway would sit `Running` while cron silently
stopped firing. All three probes now hit the gateway's **unauthenticated `/health` on 8642** —
the dashboard on 9119 is behind pocket-id and 302s/401s, so it is useless as a probe target.
Startup allows `60 × 10s = 10 minutes` (three init containers, one downloading `gh` and Go over
the internet) before liveness can act; liveness then needs `6 × 30s` of unresponsiveness. Do not
tighten those without re-checking init duration on a cold PVC.

**HelmRelease timeout.** `spec.timeout` was unset, inheriting Helm's 5m default. With
`strategy: Recreate`, `terminationGracePeriodSeconds: 120` and three init containers, that budget
is too tight — an upgrade timed out mid-audit and Flux rolled back to `hermes.v30`. Now `15m`
with install/upgrade remediation retries.

**`HERMES_CRON_TIMEOUT` is an inactivity timeout, not a wall-clock cap.** Per
`/opt/hermes/cron/jobs.py`, a job that keeps producing output legitimately runs past it, and `0`
disables it entirely — leaving only the 1800s stale-claim TTL to recover a tick that actually
_died_, so a hung-but-alive run could block indefinitely. It was `0`; it is now `900`. Because
`streaming.enabled: false`, a single slow LLM call is silent for its whole duration — do not
lower this to "detect" a slow model.

**`wait: false` on the Kustomization.** `ks.yaml` sets `wait: false` with no `healthChecks`, so
the Kustomization reports `Applied revision` even while the HelmRelease underneath is failing or
rolling back. Judge a hermes deploy by `flux get helmrelease hermes -n cortex`, never by the
Kustomization alone.

**`render-local-ks` cannot validate chart output.** It renders the Flux Kustomization's resources
— the HelmRelease, the ConfigMaps — not the templated chart, so probe or container changes appear
to "not render". Validate those with `helm template` against the app-template chart and the
HelmRelease's `spec.values`.

**Backups, and how an `exec` silently breaks them.** `/opt/data` is snapshotted hourly to
`atlas` by the kopiur `SnapshotPolicy` (`kubectl get snapshotpolicy -n cortex hermes`).
`LAST-VERIFIED` is empty — snapshots are not restore-verified; use the `restore-drill` skill.

**Any `kubectl exec` into `app` that WRITES lands as uid 0**, because the container runs
`runAsUser: 0`. kopia runs as uid 1000 and a single unreadable file fails the entire backup:

```
snapshot create failed (class PermissionDenied):
  Error when processing "cron/output/<job>/<ts>.md": permission denied
  Found 2 fatal error(s) while snapshotting hermes@cortex:/pvc/hermes
```

This happened on 2026-09-07 — one `hermes cron run` over exec left a root-owned `0600` transcript
and a root-owned `cache/plugin_toolset_keys.json`, and **every hourly snapshot failed for seven
hours** while nothing else in the cluster was affected. Nothing alerts on it: the `Snapshot` CRs
go `Failed` and get pruned by `failedJobsHistoryLimit`, so the only durable signal is one stale
row in `kubectl get snapshotpolicy -A` (every other policy sits under an hour).

Read-only execs (`cat`, `ls`, `find`) are safe. After any exec that wrote, either restart the pod —
the init's `chown -R 1000:1000 /opt/data` repairs it — or fix ownership by hand immediately. Verify
with:

```bash
kubectl -n cortex exec deploy/hermes -c app -- find /opt/data ! -user 1000   # expect only lost+found
kopiur snapshot now --policy hermes -n cortex
```

The repo also warns `Found too many index blobs (1368) ... run 'kopia maintenance'`. That is the
whole `atlas` repository, not hermes, and is not addressed here.

**The app container runs as root** (`runAsUser: 0`, `runAsNonRoot: false`,
`readOnlyRootFilesystem: false`) with `CHOWN`/`DAC_OVERRIDE`/`FOWNER`/`FSETID`/`SETGID`/`SETUID`
added, because it manages ownership inside its own home directory. The init containers and the
pod default both run as 1000 — only `app` is escalated. This is a genuine deviation from the repo
default security context; call it out in review rather than silently copying it elsewhere.

---

## Notification format

Every skill notification goes through chaski, which owns the layout — **the skill supplies data,
chaski supplies format**. Skills POST `{skill, status, summary, stats{}, items[], url}` and
nothing else. Template mechanics, the dispatch ordering that makes the hermes branch work, and
how to validate a template change offline: `.agents/references/observability.md`
§ chaski Notification Templates.

## Debugging runbook

```bash
flux get helmrelease hermes -n cortex                       # the real deploy verdict
kubectl -n cortex logs deploy/hermes -c app --tail=200
kubectl -n cortex logs deploy/hermes -c init --previous     # skill sync + drift decisions
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/skills/.git-sync/drift.current
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/cron/jobs.json
kubectl -n cortex exec "$POD" -c app -- find /opt/data/skills -name SKILL.md | wc -l
```

"Cron stopped firing" is almost always one of four things, in descending likelihood: a drifted or
ambiguous skill, an approval denial, `HERMES_CRON_TIMEOUT` reached, or the gateway hung with the
probes passing. Check `drift.current` first — it costs one command.
