# Hermes — Artemis-Cluster

Operational reference for the Nous Research **hermes-agent** running in `cortex`. Deployed
2026-08-14, ported from [eleboucher/homelab](https://git.erwanleboucher.dev/eleboucher/homelab).
The port is finished; nothing here describes how to redo it. Last reviewed against the v0.22
image on 2026-10-20. The image tag is in the HelmRelease
(`grep -n 'repository:' -A2 kubernetes/apps/cortex/hermes/app/helmrelease.yaml`).

**Read § Cost before changing anything about models, cron cadence or the MCP tier.** hermes is
the cluster's largest inference consumer and the OpenCode Go allowance is a hard monthly ceiling,
not a bill.

Manifests: `kubernetes/apps/cortex/hermes/`. Skills that ship from git:
`kubernetes/apps/cortex/hermes/app/skills/`.

---

## What it is

One Deployment, `strategy: Recreate`, one container (`app`, `nousresearch/hermes-agent`) on an
RWO PVC. It is the agent gateway: dashboard `:9119`, health `:8642`, cron.

Four init containers run in order:

1. `chown-data` — re-owns `/opt/data` to `10000:10000`, only for entries that are not already. It is the one container that runs as root (§ Run as uid 10000).
2. `init` — resets `/opt/data/config.yaml` to the version stamp only and `/opt/data/.env` to empty (§ Config and managed scope), deletes local skill copies that collide with a git skill, seeds the `cluster-health` state directory (§ Skills), and copies the cron scripts from git into `/opt/data/scripts/` (§ Cron jobs).
3. `install-memini` — installs the memini plugin at a pinned commit (§ Deps and wiring). It does no network I/O when the plugin is already at that commit.
4. `cron-reconcile` — makes the cron jobs match `app/cron/jobs.yaml` (§ Cron jobs). It `dependsOn` both `init` and `install-memini`, so it always runs last; app-template orders init containers with a topological sort (`dependsOn`), and containers without it fall back to name order, which is why this one declares it.

The app runs the image's own `/opt/hermes`, which v0.22 ships root-owned and read-only on purpose:
the agent cannot edit its own interpreter, venv or dashboard. There is no copy of it and no
writable source tree. Two retired init containers are gone for good: `copy-agent-source` (its
playwright `.deps` reason no longer exists in the image) and `install-tools` (`gh`, Go and
Homebrew sat on the PVC without the exec bit for months, because the old `init` chmod stripped it,
and nothing used them). Extra tools come from `uvx`/`npx` or a derived image, not a runtime
download; `pip install` into the image tree now fails by design.

`args` is plain `[gateway, run]`. v0.22 registers the gateway as an s6 service next to the
dashboard and keeps the main process alive with `sleep infinity`. `--no-supervise` makes the main
process collide with the s6-owned gateway and exit 1, and the pod then lives only because the s6
shutdown hangs, so every rollout SIGKILLs the gateway after the 120s grace period.

`$HOME` is `/opt/data`, which is the `hermes` PVC (4Gi `miroir`, `existingClaim: hermes`
from `components/kopiur/backup`). It holds the home directory, the plugin, the skill
library, cron state and session history — that is why `Recreate` is mandatory (a RollingUpdate
deadlocks on Multi-Attach) and why the volume is backed up.

One route, on `edge-gateway` (public through towonel):

| Hostname           | Backend port | Auth                                           |
| ------------------ | ------------ | ---------------------------------------------- |
| `hermes.dcunha.io` | `9119`       | pocket-id OIDC, `allowedUserGroups: app-admin` |

Authorisation lives in `oidcclient.yaml`. `GATEWAY_ALLOWED_USERS` gates messaging platforms only,
and none are enabled, so it does nothing for the dashboard.

`dashboard.trusted_proxies` is the pod CIDR (`10.42.0.0/16`). Without it hermes ignores the
envoy pod's `X-Forwarded-Proto: https`, sees plain http, and issues the OIDC login cookies
without `Secure` or `SameSite=None`. Envoy pod IPs change, so a CIDR is the only stable value. The
network policy (§ Network policy) now lets only the `edge-gateway` pods reach 9119, so the wide
CIDR no longer lets an arbitrary pod spoof `X-Forwarded-*`.

### Deps and wiring

| Depends on   | Address                                         | Purpose                                |
| ------------ | ----------------------------------------------- | -------------------------------------- |
| agentgateway | `agentgateway.cortex.svc.cluster.local:4000/v1` | all inference, `AGENTGATEWAY_API_KEY`  |
| memini       | `memini.cortex.svc.cluster.local:8080`          | memory, namespace **`homelab/hermes`** |
| SearXNG      | `searxng.cortex.svc.cluster.local:8080`         | web search                             |
| chaski       | `chaski.observability.svc.cluster.local`        | Pushover notifications from skills     |
| Forgejo      | `git.dcunha.io` as **dusk-bot**                 | PRs and commits                        |

`ks.yaml` `dependsOn` is `agentgateway-mcp`, `agentgateway-models`, `memini`, and
`security/pocket-id-operator` — the gateway pieces hermes calls, and the operator whose CRs it needs.

**The memini plugin reads `MEMINI_BASE_URL`, not `MEMINI_URL`.** It is the `memini-hermes`
memory plugin, installed onto the PVC at `/opt/data/plugins/memini` by the `install-memini` init
container with `hermes plugins install eleboucher/memini-hermes --ref <sha> --force --yes-deps
--no-enable`. The SHA is a plain value in that container's script. To bump it, change the value;
the init sees a different commit, reinstalls from github, and needs egress for that one boot.
`hermes plugins adopt` is not a substitute: it is not idempotent (exits 1 when a provenance row
exists) and does not pin. `hermes plugins doctor memini` reports two ERRORs (`on_pre_compress`,
`on_memory_write` hooks) even for upstream's newest release; the plugin still registers its tools
and works. `memory.provider: memini` is what activates it; `plugins.enabled` does not. With the variable
missing it silently defaults to `http://localhost:8080`, so memory looks enabled and nothing is
stored — that is how it sat broken from 2026-08-14 to 2026-10-20. Check memini's log for
`handshake: namespace resolved namespace=homelab/hermes` after any env change.

**memini namespace is `homelab/hermes`**, and `MEMINI_HOME` is `personal/exikle`: the plugin sends it as `X-Memini-Home`, and unset means no personal leg merges into recall. The agent reads the shared `homelab` facts; its own
memories stay in its namespace and do not mix with `homelab/Artemis-Cluster`. See
`.agents/references/memory-config.md` § Namespace Topology.

### Secrets

`hermes-config` is assembled by one ExternalSecret from **four** 1Password items (`forgejo`,
`agentgateway` and `hermes` via `dataFrom`, `memini` via `data`):

| Env                                   | Source                                                                               |
| ------------------------------------- | ------------------------------------------------------------------------------------ |
| `AGENTGATEWAY_API_KEY`                | `agentgateway` → `KEY_HERMES` (the hermes tier key; MCP and model calls both use it) |
| `MEMINI_API_KEY`                      | `memini` → `MEMINI_API_KEY`                                                          |
| `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` | `hermes` → `HERMES_OIDC_CLIENT_SECRET`                                               |
| `API_SERVER_KEY`                      | `hermes` → `API_SERVER_KEY`                                                          |
| `FORGEJO_PAT`                         | **`forgejo` → `DUSK_BOT_CLUSTER_TOKEN`** (infrastructure vault)                      |

The secret also pulls the managed `.env` content (`/etc/hermes/.env`, § Config and managed scope)
via `templateFrom` on the `hermes-configmap` `env` key — so an edit to the ConfigMap changes the
Secret, and Reloader restarts the pod. `API_SERVER_KEY` is also a plain `secretKeyRef` env var on
`app`: without it stage2 sees no key in the container environment and appends a generated decoy
to the user `.env` on every boot.

**`FORGEJO_PAT` is dusk-bot's, not Exikle's.** It was Exikle's until 2026-08-16, which attributed
every skill-merged PR and skill-committed README to the human whose commits are otherwise
GPG-signed. dusk-bot holds admin+push on `Artemis-Cluster` and `frostlink`, and is the same
identity Renovate uses — so a hermes commit and a Renovate commit are indistinguishable by author.

---

## Config and managed scope

The agent's whole configuration is **pinned in Hermes's managed scope**, so neither the dashboard
nor the agent can change it between restarts. Source: `hermes_cli/managed_scope.py` in the image.

| Where                                    | What                                                                   | From                                        |
| ---------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------- |
| `/etc/hermes/config.yaml` (read-only)    | every setting we own: providers, model, approvals, skills, cron, ...   | `hermes-configmap` key `config.yaml`        |
| `/etc/hermes/.env` (read-only, mode 400) | `OPENAI_BASE_URL`, `API_SERVER_KEY`                                    | Secret `hermes-config` key `env` (rendered) |
| `/opt/data/config.yaml` (PVC)            | `_config_version: 51` and nothing else, rewritten by `init` every boot | `hermes-configmap` key `user.yaml`          |
| `/opt/data/.env` (PVC)                   | empty, truncated by `init` every boot                                  | -                                           |

**How the layers combine.** The managed file deep-merges over the user file per leaf, after
`${VAR}` expansion, so a user value cannot shadow it. Dicts merge key by key; a list (`skills.disabled`,
`approvals.deny`, `fallback_providers`) is one leaf and is replaced whole. The managed `.env` is
loaded last with override, so it beats the user `.env` and the container environment. Both files are
read from `/etc/hermes` (or `$HERMES_MANAGED_DIR`); a missing directory means no scope, and a managed
file that fails to parse is ignored with a warning (fail-open, so check `hermes doctor` after a
change).

**What a pinned key does.**

- `hermes config set` / `unset` on a pinned key exits 1 with "managed by your administrator".
  `hermes config set` on a pinned env name is refused the same way.
- The dashboard saves through `save_config`, which **drops** pinned leaves and prints a note to
  stderr instead of failing. The edit appears to succeed and the effective value does not move.
- An agent that writes `/opt/data/config.yaml` directly loses too: the managed leaf wins on the next
  load. Verified with a user file carrying `model.default: evil/model` and `approvals.mode: off`;
  both still read the git values.
- **A key not in the managed file is not pinned.** Unlisted keys fall back to Hermes defaults plus
  whatever the user file says, so the agent could still set, say, `terminal.env_passthrough`.
  `init` rewrites the user file to the stamp on every boot, which bounds that to one pod lifetime.
  When an image bump adds a security-relevant key, list it in `config.yaml` too.

**Why the whole config and not just the sensitive keys.** The agent can write to `/opt/data`
(it has `write_file` and a shell), and a partial managed file leaves every other key editable until
the next boot. One file in git then states the whole intended configuration.

**Why the user file still exists.** `docker_config_migrate.py` and `hermes doctor` read the
`_config_version` stamp from the **user** `config.yaml` only (`config_version_stamp.py`), and stage2
seeds a full example config over a missing one. Keep `_config_version` out of the managed file:
`save_config` strips pinned leaves, so a pinned stamp would be removed from the user file.

**How to change a setting.** Edit `config.yaml` in `configmap.yaml` and land it like any manifest
change. Reloader restarts the pod; there is no hot reload. The files are `subPath` mounts, because a
directory mount over `/etc/hermes` would hide the image's own `image-provenance.json` and
`agent-browser-executable-path`, and a `subPath` never receives ConfigMap updates. That is fine here:
the controller carries `reloader.stakater.com/auto`, and both `hermes-configmap` and `hermes-config`
are referenced by the pod. `$${VAR}` in the ConfigMap is Flux's escape; Hermes sees `${VAR}` and
expands it from the process environment.

**Secrets stay out of the ConfigMap.** The managed `.env` comes from the Secret, never a ConfigMap.
Other keys (`AGENTGATEWAY_API_KEY`, `FORGEJO_PAT`, ...) reach the container as `secretKeyRef` env vars and
are not pinned. A key written to the user `.env` is emptied by `init` on the next boot.

**Verify:** `kubectl -n cortex exec deploy/hermes -c app -- hermes doctor` reports `Managed scope active:
N config key(s), 2 env key(s) pinned by /etc/hermes`, `Config version up to date (v50)` and no
deprecated keys. `hermes config get model.default` returns the git value.

---

## Model configuration

`config.yaml` lives in `hermes-configmap` (§ Config and managed scope). Eight `opencode-go` models are declared; **a model
agentgateway serves but `providers.agentgateway.models` omits is unusable by the agent.** The provider is
declared in the v0.22 `providers:` dict; the old `custom_providers:` list is a retired store that
`hermes doctor` warns about. `custom:agentgateway` in `model`, aliases, fallbacks and `auxiliary`
resolves to the dict key `agentgateway`.

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
  truncate a request. It is **262144**, but compaction does not fire at `compression.threshold`
  (0.5) times that. v0.22 raises the ratio to 0.75 for any window under 512K tokens, so the real
  trigger is **196,608** tokens (measured by running the compressor's own functions in the pod).
  It was `1000000` (minimax-m3's real window) until 2026-09, which meant 500K. Set it too high and
  a runaway session balloons before anything trims it; set it below the real window and you only
  pay for earlier compaction, never a provider error. The pin also logs a startup warning that the
  provider advertises a larger window; it is expected. For an absolute cap, `compression.threshold_tokens`
  is the native knob and is not set.
- **`auxiliary:` roles are on `minimax-m3`**, as is nothing else — `delegation` is on
  `mimo-v2.5`, the cheapest model on the account. The roles were pinned to `deepseek-v4-flash`
  until 2026-08-16, which put the least efficient model on exactly the small frequent tasks where
  its ~7,900-token overhead hurts most.
- `auxiliary.session_search` was removed 2026-09-07: upstream deleted that role (PR #27590) and
  it is not an LLM call. `web_extract` is likewise not an LLM call.
- **`app/virtualkey.yaml` gates what the key may call, and it is a second list to keep in sync.**
  It granted only `minimax-m3` and `mimo-v2.5` until 2026-09-07, so every `glm-5.2` fallback
  403'd. It now grants all eight declared models — but **the
  automatic paths (default, fallbacks, `auxiliary`, `delegation`) are
  deliberately kept on `minimax-m3` and `mimo-v2.5`**; the rest exist so an interactive
  `@glm`/`@kimi` works. Nothing validates the two lists against each other and the failure is a
  403 at fallback time, when you are least watching.
- `fallback_providers` is `mimo-v2.5` only (was `glm-5.2` then `mimo-v2.5`) — glm-5.2 costs ten
  times minimax-m3 and a fallback fires exactly when the account is already under pressure.
- **No `moa` block.** A `council` preset was configured until 2026-09-07 and was always dormant:
  MoA is a virtual _provider_, so it only runs when `model.provider` is literally `moa`. Ours is
  `custom:agentgateway`. `moa.default_preset` names the preset the picker would use, it does not
  enable MoA. It was removed as a landmine, not as a cost saving.
- `agent.max_turns` is 40 (was 150) and `delegation` is 2 children / depth 1 (was 8 / 2, against
  an upstream default of 3 / 1). Both bound a single run's worst case.

### Model selection is measured, not assumed

**LiteLLM reported $0.000/Mtok for every opencode-go model until 2026-09-07, and that was a
reporting artifact, not the price** — agentgateway now carries a real cost catalog; see § Cost. Within the account's allowance the selection criteria that remain are
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

The provider 400s on any `temperature` value other than 1, so every agent call failed while a
bare curl succeeded. agentgateway pins it: `models/agentgatewaymodel.yaml` is a standalone model
(not a member of the `agentgateway-opencode-go` ResourceSet) because its `finalTransformations`
rewrite `temperature` to `1`. Moving it into the ResourceSet would lose that.

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

### Spend figures

LiteLLM reported $0.00 for every opencode-go call until 2026-09-07 (#1832) and was removed on
2026-10-26; any older spend figure means nothing. For that period use
`/opt/data/cron/usage_audit.jsonl`, the per-fire token ledger.

agentgateway prices calls from the ConfigMap `agentgateway-model-costs` (USD per 1M tokens,
input/output; source <https://opencode.ai/docs/go/#usage-limits>, deepseek at the Peak rate).
Spend is the metric `agentgateway_gen_ai_client_cost_usd_total`, labelled by `user_id`, so one
key's spend is a query, not a lookup.

### Where the cost comes from

An hourly `cluster-health` run once averaged 774K prompt tokens, enough alone to overrun the $60
month. A run has two cost terms, and the second is the big one:

- **A fixed prefix, ~22,000 tokens** — system prompt, the skill, hermes's own native tool registry,
  the bundled-skill index, and the MCP tool schemas. Paid on every call.
- **Linear context growth, ~1,800 tokens/turn** of accumulated tool results. The whole context is
  resent every turn, so **total cost is roughly `turns × average context`, which grows with the
  square of the turn count.**

So **turn count is the strongest lever, cadence is the second, and the fixed prefix is third.**

Do not reason about a single run: the historical per-run range is **52K to 4.9M**. Judge a change
over a week of `usage_audit.jsonl`, never one sample.

### MCP tool schemas are charged on every turn

hermes mounted both the `ops` and `general` tiers, whose `tools/list` payloads measure 165KB and
81KB against `agent`'s 46KB. Measured directly:

```bash
# from inside the hermes pod, after an initialize that returns a Mcp-Session-Id
curl -s -X POST "http://agentgateway.cortex.svc.cluster.local:4000/agent/mcp" \
  -H "x-api-key: $AGENTGATEWAY_API_KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | wc -c
```

### The `agent` MCP tier

hermes uses its own tier, `mcp-agent`, carrying only what its skills call: `k8s`, `flux`,
`searxng`, `victoria-logs`. Its endpoint is `/agent/mcp` (the MCP server is registered as
`ai-agent`, key sent as `x-api-key`) and its payload is **46KB / 52 tools** against `ops` +
`general`'s 246KB / 180. Only the hermes key may use it.

Adding a target to hermes's reach means adding it to `mcp-agent` in
`kubernetes/apps/cortex/agentgateway/mcp/agentgatewaybackend.yaml` — **and paying its schema on
every turn of every run.** Weigh it against § Cost before doing so; `forgejo` alone is 40 tools and
`github` 44, neither of which any hermes skill calls (both skills reach Forgejo over `curl` with
`$FORGEJO_PAT`). The tier rules are in `cortex-mcp.md`.

### `x-opencode-session` is mandatory and agentgateway injects it

OpenCode Go requires a stable `x-opencode-session` per conversation and **hard-rejects requests
without one**: `400 MissingSessionID — Request is missing x-opencode-session and cannot be routed
efficiently`. It is non-retryable, so it kills a whole cron fire. Enforcement widened during
2026-09-07: at 04:00 only `mimo-v2.5` (the `openai/`-prefixed `/zen/go/v1` path) rejected, and by
09:00 `minimax-m3` (the `anthropic/`-prefixed `/zen/go` path) did too. **Every model now requires
it.** For a few hours that took all hermes inference down.

Hermes cannot supply it and neither can client-header forwarding:

- Hermes only emits the header when its provider or base URL matches `opencode-*` or an
  `opencode.ai` host. Ours is `custom:agentgateway` pointing at the in-cluster proxy, so it matches
  neither. The upstream fix (`NousResearch/hermes-agent` PR #101864) merged to `main` 2026-09-03,
  is in **no tagged release**, and would not apply to our provider shape anyway.
- Forwarding client headers sends a header the client never set. It fixes nothing.

**So the gateway injects it per model**, under `policies.headers.request.set` in
`models/resourceset.yaml` (and in `agentgatewaymodel.yaml` for kimi):

```yaml
- name: User-Agent
  value: artemis-agentgateway/1.0
- name: x-opencode-session
  value: artemis-<model>
```

`User-Agent` is there because Go also asks clients to identify themselves and the gateway does
not forward the client's own.

**Know what this workaround is.** The id is stable per _model_, not per _conversation_, which is
what Go actually asks for — it is enough to pass the check but it gives their router one bucket
per model instead of one per session. Replace it with a real per-conversation id the moment
hermes ships PR #101864 in a tagged release **and** learns to emit for a custom provider. Do not
extend the trick anywhere else.

**Separately, this was never the caching story.** Caching already worked without the header —
measured 69% of hermes's prompt tokens and 90–94% of `minimax-m3`/`mimo-v2.5` input tokens are
cache reads, keyed server-side.

### Per-key limits

Every key is limited to 2,000,000 tokens per hour (local, per replica). The old LiteLLM 30-day
dollar budgets per key are **gone**: agentgateway cannot enforce dollar budgets in Kubernetes
mode (standalone only), and that loss is accepted. A runaway is therefore bounded per hour, not
per month; watch `agentgateway_gen_ai_client_cost_usd_total` by `user_id` against the $60 ceiling.

The `memini` key may use only `opencode-go/minimax-m3` (a per-model Deny in the ResourceSet), so
a memini misconfiguration cannot reach the expensive models.

### If the allowance is tight again

In descending impact, per the cost breakdown above:

1. **Cut turns.** Cost grows with the square of the turn count. Shorten the skill's sweeps, drop
   optional steps, lower `agent.max_turns`.
2. **Widen the cron interval.** A linear multiplier on everything.
3. **Trim the `agent` MCP tier** — worth ~35K per turn against the `ops` + `general` pairing, but
   it only moves the fixed prefix.
4. Lower `model.context_length` so a runaway compacts sooner.
5. Move a job to a cheaper model. `mimo-v2.5` is $0.14/$0.28; `glm-5.2` is $1.40/$4.40, ten times
   dearer.

**A measured budget check, so the cadence decision is arithmetic rather than a guess:** at
$0.1175/run, every-2-hours is 12 runs/day ≈ $42/month, which overruns the hermes key's $20 budget.
**Every 4 hours was 6 runs/day ≈ $21/month.** `cluster-health` is now script-first: the 30-minute fire
is a shell script (no tokens), and the agent runs only when the findings are new, or the same ones
are 4 hours old (§ Cron jobs). A quiet cluster costs nothing; the worst case is a permanent finding
waking the agent every 4 hours, the old cadence. The measured run was a catch-up after five
consecutive failures and used 28 of its 40 turns, so it is an upper bound rather than a typical
fire — a quiet run has historically cost as little as 52K tokens. Re-measure from
`usage_audit.jsonl` after a week rather than trusting either number.

---

## Cron jobs

Jobs are declared in git: `app/cron/jobs.yaml`, ConfigMap `hermes-cron`. A job exists in
`jobs.json` (runtime state on the PVC) because the `cron-reconcile` init container put it there on
boot.

| Job              | Schedule       | Model                    | Script                    |
| ---------------- | -------------- | ------------------------ | ------------------------- |
| `cluster-health` | `*/30 * * * *` | `opencode-go/minimax-m3` | `cluster-health-check.sh` |

### How a job is declared

One entry per job, matched by `name`. Every key but `name` and `schedule` is optional, and a key you
leave out is not managed (the live value is kept); a key you list is forced to the declared value on
every boot.

| Key        | Meaning                                                                   |
| ---------- | ------------------------------------------------------------------------- |
| `name`     | the match key                                                             |
| `schedule` | cron expression, `every 2h`, `30m`                                        |
| `skills`   | list of skill names (`[]` clears them)                                    |
| `script`   | file under `/opt/data/scripts/`, relative path                            |
| `model`    | per-job model pin (only the CLI can set it, the agent's cron tool cannot) |
| `deliver`  | `local` (save only), or a delivery target                                 |
| `enabled`  | `false` pauses, `true` resumes (default `true`)                           |

`cron-reconcile` (`app/cron/reconcile.py`, run with the image's own python, uid 10000, no managed
config mount needed) reads `jobs.json` read-only and writes through the CLI only: `hermes cron
create` when the name is missing, `hermes cron edit <id>` for each field that differs, `hermes cron
pause|resume` for `enabled`. A second boot changes nothing and logs `matched <name>: nothing to
change`. A job in `jobs.json` that the file does not name is left alone and logged as `unmanaged job
left untouched`, so a job made in the dashboard survives a reboot (and is also not in git). A failed
job is logged `ERROR ...` and the rest continue; the container still exits 0. An unparsable YAML or a
file without a top-level `jobs` list exits 2 and the pod stays in `Init`, on purpose.

**To add or change a job:** edit `app/cron/jobs.yaml` (and `app/scripts/` or `app/skills/` if it needs
a new script or skill; register a new script file in `kustomization.yaml`'s `hermes-scripts`
generator), then land it like any manifest change. Reloader restarts the pod and the reconcile runs
before the app starts. The scheduler re-reads `jobs.json` on every tick, so nothing else is needed.
**To remove a job:** take it out of the file _and_ run `hermes cron remove <id>` in the pod; the
reconcile never deletes. A change made with `hermes cron edit` or in the dashboard to a field the file
lists is reverted at the next boot. Check the result with `kubectl -n cortex logs deploy/hermes -c
cron-reconcile` and `hermes cron list`.

Scripts are not symlinks: the scheduler refuses a script that resolves outside `/opt/data/scripts/`,
so `init` copies each `/run/scripts/*.sh` there with mode `0755` on every boot (an edit in git
replaces the copy). `.sh` runs under bash, anything else under python; the shebang is ignored.

### cluster-health: script first, agent on new findings

Every 30 minutes `cluster-health-check.sh` runs with no LLM. It does what the skill used to do by
hand: alertmanager v2 alerts (Watchdog excluded), nodes not Ready or under Memory/Disk/PID pressure,
pods Pending for over 10 minutes, `up == 0` targets, and the static smartctl `pantheon` target by
name. It uses only `curl`, `sed` and `sha256sum` (no `jq`, no `kubectl`, no python) and only
endpoints the network policy admits: alertmanager 9093, victoria-metrics 8428, chaski 8080.

| Outcome                                                         | What happens                                                                                                                                    |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| No findings                                                     | prints the summary, ends with `{"wakeAgent": false}`; posts the chaski `info` itself at most once per 4h (`last-quiet-notify` in the state dir) |
| Findings, same fingerprint as the last wake, woken under 4h ago | prints the summary, ends with `{"wakeAgent": false}`                                                                                            |
| Findings that are new, or the same ones 4h old                  | stores `<epoch> <fingerprint>` in `last-wake`, prints the summary, no gate line, so the agent wakes with the output as its context              |
| alertmanager or VictoriaMetrics unreachable                     | that is a finding (`check-failed: ...`), so it wakes the agent once per 4h                                                                      |

The state files are in `/opt/data/workspace/cluster-health/`. The fingerprint is a hash of the sorted
finding keys (alert fingerprint, node, pod, target), not of the text, so the `since` timestamps do not
change it. A finding that clears does not reset `last-wake`: a flapping alert is deduped for 4h instead
of waking the agent each flap. The flip side is that nothing wakes when a finding clears, so an Open
case row in `resolved-cases.md` is closed at the next wake, not at the moment it resolves. The stamp
is written when the script decides to wake, not when the run finishes, so a failed agent run is not
retried for 4h.

Script gate and prompt (`cron/scheduler_prompt.py`, `cron/scheduler.py`): the gate is the **last
non-empty stdout line** being JSON `{"wakeAgent": false}`; anything else wakes. On a wake, stdout
(secrets redacted) is injected as a `## Script Output` block above the skill. Empty stdout skips the
agent too. A non-zero exit or a timeout (`HERMES_CRON_SCRIPT_TIMEOUT`) injects a `Script Error` block
and wakes the agent, so the script always exits 0 when it decided.

Run it by hand against nothing live: `DRY_RUN=1 STATE_DIR=/tmp/ch bash /opt/data/scripts/cluster-health-check.sh`.
`DRY_RUN=1` prints the chaski payload instead of posting it; the state files still go to `STATE_DIR`,
so always point that somewhere disposable.

### Other cron facts

`cluster-health` was an `interval: 60m` job until 2026-08-16. Interval schedules re-arm from
_completion_, so the run time drifts; a cron expression pins a fixed minute. It was every four hours
from 2026-09-07 for cost (§ Cost) and went to a 30-minute script check with agent-on-change on
2026-10-21. Alertmanager already pages in real time, so this job is a supplementary audit, not the
alerting path.

`readme-sync` was **retired 2026-10-20**: the README section it reconciled (`## ⛵ Kubernetes` → `### Directories`) no longer exists, so every run aborted and flagged, at 645K to 1.3M prompt tokens each. It is not in `jobs.yaml`; if it still exists in `jobs.json`, remove it with `hermes cron remove <id>`.

`forgejo-pr-review` was **retired 2026-09-07**. It was the third-largest consumer on the account
and duplicated the human `triage-renovate` skill, which is the path actually used to merge the
Renovate queue. Its skill directory, ConfigMap and HelmRelease mounts are gone from git; the
in-pod copy under `/opt/data/skills/devops/` is inert once the cron job is removed, so delete it by hand if you want it gone.

`cron.catch_up_missed` is `false`. With the v0.22 default (`true`) a slot missed while the pod was
restarting fires once on start. Reloader restarts the pod on every skill or config change; with a
30-minute script cadence a skipped slot costs nothing, and the next one is at most 30 minutes away.
The scheduler logs the skip and re-anchors to the next slot.

**`jobs.json` is runtime state on the PVC** (`/opt/data/cron/jobs.json`), an object —
`{"jobs": [...], "updated_at": ...}` — owned by uid 10000. Do not hand-edit it: use
`hermes cron create|edit|pause|resume|remove`, which write it with the right ownership, and
`kubectl exec` enters the container as uid 10000 too. The dashboard API is behind pocket-id SSO
(`no_cookie`), so it cannot be scripted with `API_SERVER_KEY` alone.

```bash
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app -- hermes cron list
```

---

## Skills — read-only from git

Git is the only source of the skills we own: `ls kubernetes/apps/cortex/hermes/app/skills/`. Each one is a generated ConfigMap `hermes-skill-<name>`, mounted as a directory at `/etc/hermes-skills/<name>` on `app` and `init`, read-only, and loaded through `skills.external_dirs` in `configmap.yaml`. Nothing is copied onto the PVC, so there is no drift and no orphan to clean up.

- **No `subPath`.** A `subPath` mount never receives ConfigMap updates. A skill with subdirectories places files with `items` in the `persistence` entry (`path: references/x.md`); scripts carry `mode: 0o755`. Reloader restarts the pod when a ConfigMap changes.
- **Hermes cannot change them.** The mount is read-only, external dirs are read-only to autonomous curation, and `skills.write_approval: true` stages any skill write under `/opt/data/pending/skills/` instead of applying it. A skill change is a PR, merged by a human — see § Changing a skill.
- **`skills.disabled` lists every bundled skill** except the ones a cron job names (`grep -A3 '"skills"' /opt/data/cron/jobs.json`). New bundled skills arrive enabled with each image bump: regenerate the list from `kubectl -n cortex exec deploy/hermes -c app -- cat /opt/data/skills/.bundled_manifest` (first field before `:`).

The bundled skills still live in `/opt/data/skills/<category>/<name>/SKILL.md`, next to `.usage.json` (`use_count` / `last_used_at` / `patch_count` per skill). The startup log's `Syncing bundled skills into ~/.hermes/skills/` is wrong; it syncs into `~/skills/`.

### The anti-collision guard

v0.22 resolves the same skill name in `/opt/data/skills` and in an external dir by precedence: the local copy wins and the git copy is shadowed, with one warning in the log (`agent/skill_utils.py`). Older releases failed loudly with `Ambiguous skill name`; now a stale local copy runs silently in place of the git skill. So on every boot `init` reads the `name:` of each mounted skill and deletes any directory under `/opt/data/skills` whose `SKILL.md` carries the same name. Before deleting it copies any `references/*-triage.md` to `/opt/data/workspace/cluster-health/archive/<file>.full.md` with `cp -n`, so the old history survives the first boot after migration.

Discovery matches the literal filename `SKILL.md` anywhere beneath a skills root, dot-directories included (`iter_skill_index_files` in `agent/skill_utils.py`). Never write a file named `SKILL.md` outside a real skill: a copy parked under a dot-directory once registered a second skill of the same name and stopped the cluster-health audit for ~27 hours. The `..data` and timestamped directories of a ConfigMap mount are walked too, but they resolve to the same file and are deduplicated.

### cluster-health state

The skill appends to logs, so its state cannot live in the read-only skill directory. Everything it writes is under `/opt/data/workspace/cluster-health/` on the PVC: `resolved-cases.md` (the case index) and one `*-triage.md` recurrence log per alert family. Git ships only static material in the skill (`references/node-baselines.md`, `scripts/`).

The starting content of the state files is `app/seed/cluster-health/`, ConfigMap `hermes-cluster-health-seed`, mounted into `init` only. `init` copies each file with `cp -n`, so live state is never overwritten and an edit to a seed file in git does not reach a running pod. To re-seed one, delete the live file and restart.

### Changing a skill

For a human: edit the files under `app/skills/` and land it like any manifest change (`AGENTS.md` rule 1). For hermes: the `skill-change-pr` skill opens a PR as dusk-bot through the Forgejo contents API and never merges it (the merge deny glob in § Autonomy posture blocks it).

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
`/tmp` write would be refused). `skills/skill-change-pr/SKILL.md` carries the canonical shape.

---

## Autonomy posture — what hermes is allowed to do unattended

Set 2026-08-18, after finding that hermes had self-patched its skills 13 times since 2026-08-16
and landed **zero** of them in git. Two independent gates were each sufficient to stop it on
their own; skills are now read-only (§ Skills), which ends the self-patching.

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

### 2. RBAC — the pod holds none; the MCP path is the only one

hermes reaches the cluster **one way**: the k8s MCP tools, under `mcp-k8s-sa`, through the agentgateway
`agent` tier. The pod itself has no cluster access:

- It mounts no ServiceAccount token (app-template's `automountServiceAccountToken` default is
  `false`, and nothing overrides it), and the image has no `kubectl`.
- The `hermes` ServiceAccount exists but is bound to nothing. Its three roles
  (`hermes-read-all`, `hermes-pod-delete`, `hermes-exec-deploy`) were removed 2026-10-20: with no
  token, none of their grants — cluster-wide pod delete included — could ever be exercised.
- No skill or config calls the kube API from inside the pod.
  `grep -rniE 'kubectl|serviceaccount|KUBERNETES_SERVICE' kubernetes/apps/cortex/hermes/app/skills`
  finds only prose that says not to.

Verify: `kubectl auth can-i --list --as=system:serviceaccount:cortex:hermes -n cortex` shows only
the self-review and discovery rules every account has.

**`mcp-k8s-sa` (the MCP server)** — broader, and cluster-wide. Everything is read-only
(`get/list/watch`) except:

- `deployments/scale`, `statefulsets/scale`, `replicasets/scale`: `get, patch, update`
- `pods`: `delete`; `jobs`: `delete`
- `pods/exec`: `create`; `events`: `create`

`helmreleases` and `kustomizations` are read-only, so the MCP path cannot trigger a Flux
reconcile. Workloads are read-only too: scale is the only write. The patch grants on workloads and
Flux objects were removed 2026-08-29 (see `cortex-mcp.md`). It cannot create or delete workloads,
and cannot touch Talos or node-level state.

> **`mcp-k8s` holds no `secrets` rule.** The grant was removed on 2026-08-29 (see
> `cortex-mcp.md`); the ClusterRole carries only the External Secrets CRs
> (`externalsecrets`, `secretstores`, `clustersecretstores`), which are references, not secret
> data. Verify:
> `kubectl get clusterrole mcp-k8s -o jsonpath='{range .rules[*]}{.resources}{" -> "}{.verbs}{"\n"}{end}'`
>
> `mcp-k8s-sa` is the only path to the cluster, and it cannot read Secret data. The deny globs
> and the smart-policy ESCALATE rule bound the **shell** only; approvals gate the `terminal` tool
> and RBAC gates the k8s tools, so RBAC is the real control. The
> `mcp-k8s` ClusterRole is `kubernetes/apps/cortex/mcp/app/k8s/rbac.yaml`.

---

## Operational gotchas

**Probes.** All three prove cron is alive, not just that the process answers. Startup and liveness
are an exec probe that needs two things: the gateway's unauthenticated `/health` on 8642 answers
(`curl -fsS -m 4`), **and** `/opt/data/cron/ticker_heartbeat` is under 300 seconds old. That file
holds `<epoch> <pid>` and the cron ticker rewrites it about every minute (`record_ticker_heartbeat`
in `cron/jobs.py`), so a gateway that serves HTTP while its scheduler thread is dead fails the
probe. The dashboard's `/api/health` on 9119 is unauthenticated too and would also work; 8642 is what
the probes always hit. Readiness stays a plain `httpGet` on `/health`: a stale ticker is fixed by a
restart, and pulling the pod from the Service would only take the dashboard down with it. Startup
allows `60 × 10s = 10 minutes` for the first heartbeat before liveness can act; liveness then fails
after `3 × 30s`, with a 10s probe timeout. Boot is now a minute or so (four init containers, no
download, no source copy), so that budget has slack. Re-check init duration on a cold PVC before
tightening it. The ticker is async (`cron_tick(sync=False)`), so a long agent run does not hold up the
heartbeat. Verify: `kubectl -n cortex describe pod -l app.kubernetes.io/name=hermes` shows no
`Unhealthy` events, and `kubectl -n cortex exec deploy/hermes -c app -- cat /opt/data/cron/ticker_heartbeat`.

**HelmRelease timeout.** `spec.timeout` was unset, inheriting Helm's 5m default. With
`strategy: Recreate`, `terminationGracePeriodSeconds: 120` and the init containers, that budget
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

**`render-ks` cannot validate chart output.** It renders the Flux Kustomization's resources
— the HelmRelease, the ConfigMaps — not the templated chart, so probe or container changes appear
to "not render". Validate those with `helm template` against the app-template chart and the
HelmRelease's `spec.values`.

**Backups, and how an `exec` silently breaks them.** `/opt/data` is snapshotted hourly to
`atlas` by the kopiur `SnapshotPolicy` (`kubectl get snapshotpolicy -n cortex hermes`).
`LAST-VERIFIED` is empty — snapshots are not restore-verified; use the `restore-drill` skill.

**A `kubectl exec` into `app` runs as uid 10000**, the container user, so `sh -c`, `cp` and `tee`
write files the scheduler and the kopia mover (also uid 10000) can read. That closes the failure of
2026-09-07, when root-owned files from an exec made every hourly snapshot fail for seven hours
(kopia fails the whole snapshot on one unreadable file). Verify, and force a snapshot:

```bash
kubectl -n cortex exec deploy/hermes -c app -- find /opt/data ! -user 10000   # expect only lost+found
kopiur snapshot now --policy hermes -n cortex
```

The repo also warns `Found too many index blobs (1368) ... run 'kopia maintenance'`. That is the
whole `atlas` repository, not hermes, and is not addressed here.

### Run as uid 10000

The pod runs as `10000:10000` with `fsGroup: 10000`, `runAsNonRoot: true`, all capabilities
dropped, no privilege escalation and a read-only root filesystem. The image accepts only uid
10000 when started non-root (`docker/stage2-hook.sh`, `docker/main-wrapper.sh`: any other
non-root uid is refused), and that is the uid its `hermes` user is built with. Writable paths are
`/opt/data` (the PVC), `/run` (s6, an emptyDir) and `/tmp` (an emptyDir); nothing else is written.

- `S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES=1` is required: s6-overlay refuses an
  emptyDir `/run` (mode 0777) otherwise. `HERMES_UID`/`HERMES_GID` and every added capability
  are gone — there is no `usermod`, no remap and no root `chown` in the app container any more.
- The stage2 hook still calls the config migrator and the dependency refresh through
  `s6-setuidgid`, which needs `CAP_SETGID`. Both fail non-root with `Warning: ... failed;
  continuing` in the boot log. That is expected. The migrator is a no-op anyway while
  `_config_version` in the `user.yaml` key of `configmap.yaml` equals the image's (`51`; run as uid
  10000 it exits 0 and leaves the file unchanged). If an image bump raises the version, raise the
  number in `user.yaml` with it, or add a `config-migrate` init like bjw-s's. The dependency refresh
  only matters for opt-in plugin dependencies after an image upgrade.
- The `init` and `install-memini` containers run as 10000 with a read-only root filesystem too.
- **`chown-data` is the single root container** (`runAsUser: 0`, capabilities `CHOWN` and
  `DAC_READ_SEARCH` only, read-only root, no escalation). The PVC was written by uid 1000 until
  S9 and a non-root process cannot chown files it does not own; `fsGroup` only widens group
  access and leaves the owner, which `git` ("dubious ownership" on the plugin checkout) and
  `chmod` on those files would trip over. It chowns only entries that are not already
  `10000:10000` and skips `lost+found`, so every boot after the first is a quick `find` and
  nothing else. Once the volume has booted once as 10000 it has no further job: delete the container,
  its `persistence.data.advancedMounts` entry and the `dependsOn` on `init` in a follow-up.
  Its row is in `pod-security-exceptions.md`.
- Kopiur: `KOPIUR_PUID`/`KOPIUR_PGID` are `10000` in `ks.yaml`, for the `SnapshotPolicy` mover and
  the `Restore` mover (`kopiur.md` § Mover uid). A restore writes files as the mover
  uid, so restoring an older snapshot (owned by 1000) with these settings gives uid 10000 files,
  which is what the pod needs. Changing the `Restore` spec means deleting the `Restore` CR once so
  Flux recreates it (`kopiur.md`).

### Network policy

`networkpolicy.yaml` selects the hermes pod for ingress and egress; everything not listed is
dropped. Ingress: only the `edge-gateway` envoy pods, on 9119. Kubelet probes on 8642 come from the
node host, which Cilium always lets through. Nothing else calls 9119 or the API server on 8642.

| Egress                         | Port  | Why                                                                       |
| ------------------------------ | ----- | ------------------------------------------------------------------------- |
| kube-dns                       | 53    | all name resolution                                                       |
| `agentgateway`                 | 4000  | every model call, and the `agent` MCP tier (k8s, flux, searxng, victoria) |
| `memini`                       | 8080  | memory plugin                                                             |
| `searxng`                      | 8080  | `web.search_backend`                                                      |
| `chaski` (observability)       | 8080  | skills POST their notification summaries                                  |
| `alertmanager` (observability) | 9093  | cluster-health pulls firing alerts                                        |
| `victoria-metrics` (observ.)   | 8428  | cluster-health and `targetdown-check.sh` PromQL                           |
| `vmagent` (observability)      | 8429  | `targetdown-check.sh` scrape-target health                                |
| `edge-gateway` envoy pods      | 10443 | `git.dcunha.io` (PRs as dusk-bot) and `id.dcunha.io` (dashboard OIDC)     |

`git.dcunha.io` and `id.dcunha.io` resolve to the edge-gateway LoadBalancer (`10.10.99.90`).
Cilium translates that address to the envoy pods before it checks policy, so the rule names the
pods and their container port (10443), not the address. The cost is that the rule admits every
route on `edge-gateway`, not only those two hosts; SNI filtering needs a `CiliumNetworkPolicy`.

**There is no internet egress.** Three things try the internet and degrade without it: the
models.dev catalog refresh (served from `/opt/data/models_dev_cache.json`, every model has an
explicit `context_length`), plugin update checks, and `hermes plugins install`. The last one is
a real constraint: bumping the memini SHA in `install-memini` clones from github.com and installs
dependencies from PyPI, and the init container fails (and the pod stays in `Init`) while the policy
blocks that. For a bump, add a temporary egress rule for `0.0.0.0/0` on 443 with
`just kube apply-ks cortex hermes`, bump, and take it out again.

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
kubectl -n cortex logs deploy/hermes -c init --previous     # stale-skill guard and seeding
kubectl -n cortex logs deploy/hermes -c cron-reconcile --previous   # job matched, edited or errored
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/cron/jobs.json
kubectl -n cortex exec "$POD" -c app -- ls /etc/hermes-skills /opt/data/workspace/cluster-health
```

"Cron stopped firing" is almost always one of four things, in descending likelihood: a skill
shadowed by a stale local copy (the run succeeds with the wrong skill), an approval denial,
`HERMES_CRON_TIMEOUT` reached, or the gateway hung with the probes passing. Search the gateway log
for `is shadowed by a higher-precedence copy` first — it costs one command.
