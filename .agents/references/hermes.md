# Hermes — home-infra

This is the operational reference for the Nous Research hermes-agent that runs in `cortex`. The team deployed it on
2026-08-14 and ported it from [eleboucher/homelab](https://git.erwanleboucher.dev/eleboucher/homelab).
The port is finished. Nothing here describes how to redo it. The team last reviewed this file against the v0.22
image on 2026-10-20. The image tag is in the HelmRelease
(`grep -n 'repository:' -A2 clusters/artemis/kubernetes/apps/cortex/hermes/app/helmrelease.yaml`).

Read § Cost before you change anything about models, cron cadence or the MCP tier. hermes is
the largest inference consumer in the cluster. The OpenCode Go allowance is a hard monthly ceiling,
not a bill.

The manifests are in `clusters/artemis/kubernetes/apps/cortex/hermes/`. The skills that ship from git are in
`clusters/artemis/kubernetes/apps/cortex/hermes/app/skills/`.

---

## What it is

It is one Deployment with `strategy: Recreate` and one container (`app`, `nousresearch/hermes-agent`) on an
RWO PVC. It is the agent gateway: dashboard `:9119`, Webapp `:9120`, health `:8642`, cron.

Three init containers run in order:

1. `init` resets `/opt/data/config.yaml` to the version stamp only and `/opt/data/.env` to empty (§ Config and managed scope). It deletes local skill copies that collide with a git skill, seeds the `cluster-health` state directory (§ Skills), and copies the cron scripts from git into `/opt/data/scripts/` (§ Cron jobs).
2. `install-memini` installs the memini plugin at a pinned commit (§ Deps and wiring). It does no network I/O when the plugin is already at that commit.
3. `cron-reconcile` makes the cron jobs match `app/cron/jobs.yaml` (§ Cron jobs). It has `dependsOn` for both `init` and `install-memini`, so it always runs last. app-template orders init containers with a topological sort (`dependsOn`). Containers without it fall back to name order, which is why this one declares it.

The app runs the own `/opt/hermes` of the image. v0.22 ships it root-owned and read-only on purpose:
the agent cannot edit its own interpreter, venv or dashboard. There is no copy of it and no
writable source tree. The team retired two init containers for good. `copy-agent-source` is gone because its
playwright `.deps` reason no longer exists in the image. `install-tools` is gone because `gh`, Go and
Homebrew sat on the PVC without the exec bit for months (the old `init` chmod stripped it),
and nothing used them. Extra tools come from `uvx`/`npx` or a derived image, not a runtime
download. A `pip install` into the image tree now fails by design.

`args` is plain `[gateway, run]`. v0.22 registers the gateway as an s6 service next to the
dashboard and keeps the main process alive with `sleep infinity`. With `--no-supervise`, the main
process collides with the s6-owned gateway and exits 1. The pod then lives only because the s6
shutdown hangs, so every rollout sends SIGKILL to the gateway after the 120s grace period.

`$HOME` is `/opt/data`, which is the `hermes` PVC (4Gi `miroir`, `existingClaim: hermes`
from `components/kopiur/backup`). It holds the home directory, the plugin, the skill
library, cron state and session history. That is why `Recreate` is mandatory (a RollingUpdate
deadlocks on Multi-Attach) and why the volume is backed up.

There are two routes, both on `edge-gateway` (public through towonel):

| Hostname               | Backend port | What                  | Auth                                           |
| ---------------------- | ------------ | --------------------- | ---------------------------------------------- |
| `hermes.dcunha.io`     | `9119`       | dashboard             | pocket-id OIDC, `allowedUserGroups: app-admin` |
| `hermes-app.dcunha.io` | `9120`       | Webapp (from v0.23.0) | the same pocket-id OIDC client                 |

Authorization lives in `oidcclient.yaml`. `GATEWAY_ALLOWED_USERS` gates messaging platforms only.
No messaging platform is enabled, so it does nothing for the dashboard.

The Webapp is the Desktop workspace in a browser tab. The `webapp:` block in `config.yaml` turns
it on. It needs `host: 0.0.0.0`, because the default `127.0.0.1` cannot take traffic from envoy.
A non-loopback host turns on the sign-in gate, and Hermes has no mode without sign-in. The Webapp
uses the same self-hosted OIDC provider as the dashboard (the `HERMES_DASHBOARD_OIDC_*` variables).
Its callback is `<webapp.public_url>/auth/callback`, so both callbacks are in `oidcclient.yaml`.
The route rule sets `timeouts.request: 0s`, as bjw-s-labs/home-ops does, so that envoy does not
cut long chat streams. The Webapp is single-user: a signed-in tab acts as the agent owner.

`dashboard.trusted_proxies` is the pod CIDR (`10.42.0.0/16`). The Webapp reads the same list. Without it, hermes ignores the
`X-Forwarded-Proto: https` header of the envoy pod and sees plain http. It then issues the OIDC login cookies
without `Secure` or `SameSite=None`. Envoy pod IPs change, so a CIDR is the only stable value. The
network policy (§ Network policy) now lets only the `edge-gateway` pods reach 9119 and 9120, so the wide
CIDR no longer lets an arbitrary pod spoof `X-Forwarded-*`.

### Deps and wiring

| Depends on   | Address                                         | Purpose                                |
| ------------ | ----------------------------------------------- | -------------------------------------- |
| agentgateway | `agentgateway.cortex.svc.cluster.local:4000/v1` | all inference, `AGENTGATEWAY_API_KEY`  |
| memini       | `memini.cortex.svc.cluster.local:8080`          | memory, namespace **`homelab/hermes`** |
| SearXNG      | `searxng.cortex.svc.cluster.local:8080`         | web search                             |
| chaski       | `chaski.observability.svc.cluster.local`        | Pushover notifications from skills     |
| Forgejo      | `git.dcunha.io` as **dusk-bot**                 | PRs and commits                        |

`ks.yaml` has `dependsOn` for `agentgateway-mcp`, `agentgateway-models`, `memini`, and
`security/pocket-id-operator`. These are the gateway pieces that hermes calls, and the operator whose CRs it needs.

The memini plugin reads `MEMINI_BASE_URL`, not `MEMINI_URL`. It is the `memini-hermes`
memory plugin. The `install-memini` init
container installs it onto the PVC at `/opt/data/plugins/memini` with
`hermes plugins install eleboucher/memini-hermes --ref <sha> --force --yes-deps
--no-enable`. The SHA is a plain value in the script of that container. To bump it, change the value.
The init sees a different commit and reinstalls from github, so it needs egress for that one boot.
`hermes plugins adopt` is not a substitute. It is not idempotent (it exits 1 when a provenance row
exists) and it does not pin. `hermes plugins doctor memini` reports two ERRORs (`on_pre_compress`,
`on_memory_write` hooks) even for the newest upstream release. The plugin still registers its tools
and works. `memory.provider: memini` activates it. `plugins.enabled` does not. If the variable
is missing, it silently defaults to `http://localhost:8080`, so memory looks enabled and nothing is
stored. That is how it sat broken from 2026-08-14 to 2026-10-20. After any env change, check the memini log for
`handshake: namespace resolved namespace=homelab/hermes`.

The memini namespace is `homelab/hermes`, and `MEMINI_HOME` is `personal/exikle`. The plugin sends it as `X-Memini-Home`. If it is unset, no personal leg merges into recall. The agent reads the shared `homelab` facts. Its own
memories stay in its namespace and do not mix with `homelab/home-infra`. See
`.agents/references/memory-config.md` § Namespace Topology.

### Secrets

One ExternalSecret assembles `hermes-config` from four 1Password items (`forgejo`,
`agentgateway` and `hermes` via `dataFrom`, `memini` via `data`):

| Env                                   | Source                                                                               |
| ------------------------------------- | ------------------------------------------------------------------------------------ |
| `AGENTGATEWAY_API_KEY`                | `agentgateway` → `KEY_HERMES` (the hermes tier key; MCP and model calls both use it) |
| `MEMINI_API_KEY`                      | `memini` → `MEMINI_API_KEY`                                                          |
| `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` | `hermes` → `HERMES_OIDC_CLIENT_SECRET`                                               |
| `API_SERVER_KEY`                      | `hermes` → `API_SERVER_KEY`                                                          |
| `FORGEJO_PAT`                         | **`forgejo` → `DUSK_BOT_CLUSTER_TOKEN`** (infrastructure vault)                      |

The secret also pulls the managed `.env` content (`/etc/hermes/.env`, § Config and managed scope)
via `templateFrom` on the `hermes-configmap` `env` key. So an edit to the ConfigMap changes the
Secret, and Reloader restarts the pod. `API_SERVER_KEY` is also a plain `secretKeyRef` env var on
`app`. Without it, stage2 sees no key in the container environment and appends a generated decoy
to the user `.env` on every boot.

`FORGEJO_PAT` belongs to dusk-bot, not Exikle. It was Exikle's until 2026-08-16. That attributed
every skill-merged PR and skill-committed README to the human whose other commits are
GPG-signed. dusk-bot holds admin+push on `home-infra` and `frostlink`, and is the same
identity that Renovate uses. So a hermes commit and a Renovate commit look the same by author.

---

## Config and managed scope

The whole configuration of the agent is pinned in the managed scope of Hermes, so neither the dashboard
nor the agent can change it between restarts. The source is `hermes_cli/managed_scope.py` in the image.

| Where                                    | What                                                                   | From                                        |
| ---------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------- |
| `/etc/hermes/config.yaml` (read-only)    | every setting we own: providers, model, approvals, skills, cron, ...   | `hermes-configmap` key `config.yaml`        |
| `/etc/hermes/.env` (read-only, mode 400) | `OPENAI_BASE_URL`, `API_SERVER_KEY`                                    | Secret `hermes-config` key `env` (rendered) |
| `/opt/data/config.yaml` (PVC)            | `_config_version: 53` and nothing else, rewritten by `init` every boot | `hermes-configmap` key `user.yaml`          |
| `/opt/data/.env` (PVC)                   | empty, truncated by `init` every boot                                  | -                                           |

How the layers combine: the managed file deep-merges over the user file per leaf, after
`${VAR}` expansion, so a user value cannot shadow it. Dicts merge key by key. A list (`skills.disabled`,
`approvals.deny`, `fallback_providers`) is one leaf, and the merge replaces it whole. The managed `.env` is
loaded last with override, so it wins over the user `.env` and the container environment. Hermes reads both files
from `/etc/hermes` (or `$HERMES_MANAGED_DIR`). A missing directory means no scope. Hermes ignores a managed
file that fails to parse and prints a warning (fail-open), so check `hermes doctor` after a
change.

What a pinned key does:

- `hermes config set` / `unset` on a pinned key exits 1 with "managed by your administrator".
  `hermes config set` on a pinned env name is refused the same way.
- The dashboard saves through `save_config`, which drops pinned leaves and prints a note to
  stderr instead of failing. The edit appears to succeed and the effective value does not move.
- An agent that writes `/opt/data/config.yaml` directly loses too. The managed leaf wins on the next
  load. The team verified this with a user file that carried `model.default: evil/model` and `approvals.mode: off`.
  Both still read the git values.
- A key that is not in the managed file is not pinned. Unlisted keys fall back to Hermes defaults plus
  whatever the user file says, so the agent could still set, for example, `terminal.env_passthrough`.
  `init` rewrites the user file to the stamp on every boot, which limits that to one pod lifetime.
  When an image bump adds a security-relevant key, list it in `config.yaml` too.

Why the whole config and not just the sensitive keys: the agent can write to `/opt/data`
(it has `write_file` and a shell), and a partial managed file leaves every other key editable until
the next boot. One file in git then states the whole intended configuration.

Why the user file still exists: `docker_config_migrate.py` and `hermes doctor` read the
`_config_version` stamp from the user `config.yaml` only (`config_version_stamp.py`), and stage2
seeds a full example config over a missing one. Keep `_config_version` out of the managed file.
`save_config` strips pinned leaves, so a pinned stamp would be removed from the user file.

To change a setting, edit `config.yaml` in `configmap.yaml` and land it like any manifest
change. Reloader restarts the pod. There is no hot reload. The files are `subPath` mounts, because a
directory mount over `/etc/hermes` would hide the own `image-provenance.json` and
`agent-browser-executable-path` of the image, and a `subPath` never receives ConfigMap updates. That is fine here:
the controller carries `reloader.stakater.com/auto`, and the pod references both `hermes-configmap` and `hermes-config`.
`$${VAR}` in the ConfigMap is the escape of Flux. Hermes sees `${VAR}` and
expands it from the process environment.

Secrets stay out of the ConfigMap. The managed `.env` comes from the Secret, never a ConfigMap.
Other keys (`AGENTGATEWAY_API_KEY`, `FORGEJO_PAT`, ...) reach the container as `secretKeyRef` env vars and
are not pinned. `init` empties a key that someone wrote to the user `.env` on the next boot.

To verify, run `kubectl -n cortex exec deploy/hermes -c app -- hermes doctor`. It reports `Managed scope active:
N config key(s), 2 env key(s) pinned by /etc/hermes`, `Config version up to date (v50)` and no
deprecated keys. `hermes config get model.default` returns the git value.

---

## Model configuration

`config.yaml` lives in `hermes-configmap` (§ Config and managed scope). The file declares eight `opencode-go` models. If agentgateway serves a model but `providers.agentgateway.models` omits it, the agent cannot use that model. The team
declared the provider in the v0.22 `providers:` dict. The old `custom_providers:` list is a retired store that
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

- The default is `opencode-go/minimax-m3`.
- `model.context_length` is the compaction trigger and nothing else. Upstream never uses it to
  truncate a request. It is 262144, but compaction does not fire at `compression.threshold`
  (0.5) times that. v0.22 raises the ratio to 0.75 for any window under 512K tokens, so the real
  trigger is 196,608 tokens (the team measured this by running the own functions of the compressor in the pod).
  It was `1000000` (the real window of minimax-m3) until 2026-09, which meant 500K. If you set it too high,
  a runaway session balloons before anything trims it. If you set it below the real window, you only
  pay for earlier compaction and never get a provider error. The pin also logs a startup warning that the
  provider advertises a larger window. That warning is expected. For an absolute cap, `compression.threshold_tokens`
  is the native setting, and it is not set.
- The `auxiliary:` roles are on `minimax-m3`, and nothing else is. `delegation` is on
  `mimo-v2.5`, the cheapest model on the account. The roles were pinned to `deepseek-v4-flash`
  until 2026-08-16. That put the least efficient model on exactly the small frequent tasks where
  its overhead of about 7,900 tokens hurts most.
- The team removed `auxiliary.session_search` on 2026-09-07. Upstream deleted that role (PR #27590) and
  it is not an LLM call. `web_extract` is likewise not an LLM call.
- `app/virtualkey.yaml` gates what the key can call, and it is a second list to keep in sync.
  It granted only `minimax-m3` and `mimo-v2.5` until 2026-09-07, so every `glm-5.2` fallback
  returned 403. It now grants all eight declared models. But the
  automatic paths (default, fallbacks, `auxiliary`, `delegation`) deliberately stay on `minimax-m3` and `mimo-v2.5`.
  The other models exist so that an interactive
  `@glm`/`@kimi` works. Nothing validates the two lists against each other, and the failure is a
  403 at fallback time, when you are least watching.
- `fallback_providers` is `mimo-v2.5` only (it was `glm-5.2` then `mimo-v2.5`). glm-5.2 costs ten
  times as much as minimax-m3, and a fallback fires exactly when the account is already under pressure.
- There is no `moa` block. The team configured a `council` preset until 2026-09-07, and it was always dormant.
  MoA is a virtual _provider_, so it only runs when `model.provider` is literally `moa`. Ours is
  `custom:agentgateway`. `moa.default_preset` names the preset that the picker would use. It does not
  enable MoA. The team removed it as a landmine, not as a cost saving.
- `agent.max_turns` is 40 (it was 150). `delegation` is 2 children / depth 1 (it was 8 / 2, against
  an upstream default of 3 / 1). Both bound the worst case of a single run.

### Model selection is measured, not assumed

LiteLLM reported $0.000/Mtok for every opencode-go model until 2026-09-07. That was a
reporting artifact, not the price. agentgateway now carries a real cost catalog (see § Cost). Within the allowance of the account, the selection criteria that remain are
accuracy and latency. The team measured on 2026-08-16 against the actual workload (emit the exact notification
JSON, and make a tool call that must omit an unused parameter), 2 runs each:

| Model               | JSON contract | Tool call | Latency | Completion tokens |
| ------------------- | ------------- | --------- | ------- | ----------------- |
| `minimax-m3`        | 2/2           | 2/2       | 1.9s    | 129               |
| `glm-5.2`           | 2/2           | 2/2       | 5.7s    | 1007              |
| `mimo-v2.5`         | 2/2           | 2/2       | 13.1s   | 1222              |
| `deepseek-v4-flash` | 2/2           | 2/2       | 35.9s   | 7934              |
| `qwen3.6-plus`      | 2/2           | 2/2       | 35.5s   | 2444              |
| `qwen3.7-max`       | **1/2**       | 2/2       | 52.9s   | 3206              |
| `kimi-k2.6`         | **1/2**       | 2/2       | 103.3s  | 4384              |

`deepseek-v4-flash` used 7,934 completion tokens and 36s on a task that `minimax-m3` answered
correctly in 129 tokens and 1.9s. It is the least efficient option, not the most, despite the
"flash" name. `qwen3.7-max` miscounted (`fixed=1` where the answer was 2). That disqualifies it
for jobs whose entire output is counts. Run the bake-off again before you change an assignment. Do not
pick on model naming.

### kimi-k2.7-code rejects `temperature`

The provider returns 400 on any `temperature` value other than 1, so every agent call failed while a
bare curl succeeded. agentgateway pins it. `models/agentgatewaymodel.yaml` is a standalone model
(not a member of the `agentgateway-opencode-go` ResourceSet) because its `finalTransformations`
rewrite `temperature` to `1`. If you moved it into the ResourceSet, you would lose that.

---

## Cost

OpenCode Go is a $10/month subscription with a hard usage ceiling, not a bill. The account is
metered in dollars of model value and cuts off when a window is exhausted:

| Window  | Allowance |
| ------- | --------- |
| 5 hours | $12       |
| 7 days  | $30       |
| Monthly | $60       |

Exhaustion returns `429 GoUsageLimitError` on every model at once. All eight models resolve
to one `opencode.ai/zen/go` workspace, which is why `fallback_providers` cannot rescue a quota
event (#1813). "You are at $60" means the allowance is spent, not that anyone charged $60.

### Spend figures

LiteLLM reported $0.00 for every opencode-go call until 2026-09-07 (#1832), and the team removed it on
2026-10-26. Any older spend figure means nothing. For that period, use
`/opt/data/cron/usage_audit.jsonl`, the per-fire token ledger.

agentgateway prices calls from the ConfigMap `agentgateway-model-costs` (USD per 1M tokens: input, output and `cacheRead`;
source <https://opencode.ai/docs/go/#usage-limits>, deepseek at the Peak rate). Without `cacheRead`, the gateway
billed cache reads at the full input rate, and spend read about 3x high (hermes is about 87% cache reads).
Spend is the metric `agentgateway_gen_ai_client_cost_usd_total`, labelled by `user_id`, so the spend of
one key is a query, not a lookup.

### Where the cost comes from

An hourly `cluster-health` run once averaged 774K prompt tokens, which alone was enough to overrun the $60
month. A run has two cost terms, and the second is the big one:

- A fixed prefix of about 22,000 tokens: the system prompt, the skill, the own native tool registry of hermes,
  the bundled-skill index, and the MCP tool schemas. Every call pays it.
- Linear context growth of about 1,800 tokens per turn from accumulated tool results. Every turn resends the whole context, so total cost is roughly `turns × average context`, which grows with the
  square of the turn count.

So turn count is the strongest lever, cadence is the second, and the fixed prefix is third.

Do not reason about a single run. The historical per-run range is 52K to 4.9M. Judge a change
over a week of `usage_audit.jsonl`, never one sample.

### MCP tool schemas are charged on every turn

hermes mounted both the `ops` and `general` tiers. Their `tools/list` payloads measure 165KB and
81KB, against 46KB for `agent`. The team measured it directly:

```bash
# from inside the hermes pod, after an initialize that returns a Mcp-Session-Id
curl -s -X POST "http://agentgateway.cortex.svc.cluster.local:4000/agent/mcp" \
  -H "x-api-key: $AGENTGATEWAY_API_KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | wc -c
```

### The `agent` MCP tier

hermes uses its own tier, `mcp-agent`. It carries only what the skills of hermes call: `k8s`, `flux`,
`searxng`, `victoria-logs`. Its endpoint is `/agent/mcp` (the MCP server is registered as
`ai-agent`, and the key goes in `x-api-key`). Its payload is 46KB / 52 tools, against 246KB / 180 for `ops` and
`general` together. Only the hermes key can use it.

To add a target to the reach of hermes, add it to `mcp-agent` in
`clusters/artemis/kubernetes/apps/cortex/agentgateway/mcp/agentgatewaybackend.yaml`. Then hermes pays for its schema on
every turn of every run. Weigh that against § Cost first. `forgejo` alone is 40 tools and
`github` is 44, and no hermes skill calls either (both skills reach Forgejo over `curl` with
`$FORGEJO_PAT`). The tier rules are in `cortex-mcp.md`.

### `x-opencode-session` is mandatory and agentgateway injects it

OpenCode Go requires a stable `x-opencode-session` per conversation and hard-rejects requests
without one: `400 MissingSessionID — Request is missing x-opencode-session and cannot be routed
efficiently`. The error is non-retryable, so it kills a whole cron fire. Enforcement widened during
2026-09-07. At 04:00 only `mimo-v2.5` (the `openai/`-prefixed `/zen/go/v1` path) rejected, and by
09:00 `minimax-m3` (the `anthropic/`-prefixed `/zen/go` path) did too. Every model now requires
it. For a few hours that took all hermes inference down.

Hermes cannot supply it, and neither can client-header forwarding:

- Hermes only emits the header when its provider or base URL matches `opencode-*` or an
  `opencode.ai` host. Ours is `custom:agentgateway`, which points at the in-cluster proxy, so it matches
  neither. The upstream fix (`NousResearch/hermes-agent` PR #101864) merged to `main` on 2026-09-03.
  It is in no tagged release, and it would not apply to our provider shape anyway.
- Forwarding client headers sends a header that the client never set. It fixes nothing.

So the gateway injects it per model, under `policies.headers.request.set` in
`models/resourceset.yaml` (and in `agentgatewaymodel.yaml` for kimi):

```yaml
- name: User-Agent
  value: artemis-agentgateway/1.0
- name: x-opencode-session
  value: artemis-<model>
```

`User-Agent` is there because Go also asks clients to identify themselves, and the gateway does
not forward the own header of the client.

Know what this workaround is. The id is stable per _model_, not per _conversation_, which is
what Go actually asks for. It is enough to pass the check, but it gives the router of Go one bucket
per model instead of one per session. Replace it with a real per-conversation id as soon as
hermes ships PR #101864 in a tagged release and learns to emit the header for a custom provider. Do not
extend the trick anywhere else.

Separately, this was never the caching story. Caching already worked without the header.
The team measured that 69% of the prompt tokens of hermes and 90–94% of the input tokens of `minimax-m3`/`mimo-v2.5` are
cache reads, keyed server-side.

### Per-key limits

Every key is limited to 2,000,000 tokens per hour (local, per replica). The old LiteLLM 30-day
dollar budgets per key are gone. agentgateway cannot enforce dollar budgets in Kubernetes
mode (standalone only), and the team accepted that loss. So a runaway is bounded per hour, not
per month. Watch `agentgateway_gen_ai_client_cost_usd_total` by `user_id` against the $60 ceiling.

The `memini` key can use only `opencode-go/minimax-m3` (a per-model Deny in the ResourceSet), so
a memini misconfiguration cannot reach the expensive models.

### If the allowance is tight again

These steps are in descending order of impact, per the cost breakdown above:

1. Cut turns. Cost grows with the square of the turn count. Shorten the sweeps of the skill, drop
   optional steps, lower `agent.max_turns`.
2. Widen the cron interval. It is a linear multiplier on everything.
3. Trim the `agent` MCP tier. It is worth about 35K per turn against the `ops` and `general` pairing, but
   it only moves the fixed prefix.
4. Lower `model.context_length` so a runaway compacts sooner.
5. Move a job to a cheaper model. `mimo-v2.5` is $0.14/$0.28. `glm-5.2` is $1.40/$4.40, ten times
   dearer.

A measured budget check makes the cadence decision arithmetic rather than a guess. At
$0.1175/run, every 2 hours is 12 runs/day, about $42/month, which overruns the $20 budget of the hermes key.
Every 4 hours was 6 runs/day, about $21/month. `cluster-health` is now script-first. The 30-minute fire
is a shell script (no tokens), and the agent runs only when the findings are new, or the same ones
are 4 hours old (§ Cron jobs). A quiet cluster costs nothing. The worst case is a permanent finding
that wakes the agent every 4 hours, which was the old cadence. The measured run was a catch-up after five
consecutive failures and used 28 of its 40 turns, so it is an upper bound rather than a typical
fire. A quiet run has historically cost as little as 52K tokens. Measure again from
`usage_audit.jsonl` after a week. Do not trust either number.

---

## Cron jobs

Jobs are declared in git: `app/cron/jobs.yaml`, ConfigMap `hermes-cron`. A job exists in
`jobs.json` (runtime state on the PVC) because the `cron-reconcile` init container put it there on
boot.

| Job              | Schedule       | Model                    | Script                    |
| ---------------- | -------------- | ------------------------ | ------------------------- |
| `cluster-health` | `*/30 * * * *` | `opencode-go/minimax-m3` | `cluster-health-check.sh` |

### How a job is declared

There is one entry per job, matched by `name`. Every key except `name` and `schedule` is optional. If you
leave a key out, it is not managed (the live value is kept). If you list a key, every boot forces it to the declared value.

| Key        | Meaning                                                                   |
| ---------- | ------------------------------------------------------------------------- |
| `name`     | the match key                                                             |
| `schedule` | cron expression, `every 2h`, `30m`                                        |
| `skills`   | list of skill names (`[]` clears them)                                    |
| `script`   | file under `/opt/data/scripts/`, relative path                            |
| `model`    | per-job model pin (only the CLI can set it, the agent's cron tool cannot) |
| `deliver`  | `local` (save only), or a delivery target                                 |
| `enabled`  | `false` pauses, `true` resumes (default `true`)                           |

`cron-reconcile` (`app/cron/reconcile.py`, run with the own python of the image, uid 10000, no managed
config mount needed) reads `jobs.json` read-only and writes through the CLI only. It runs `hermes cron
create` when the name is missing, `hermes cron edit <id>` for each field that differs, and `hermes cron
pause|resume` for `enabled`. A second boot changes nothing and logs `matched <name>: nothing to
change`. If `jobs.json` holds a job that the file does not name, the reconcile leaves it alone and logs `unmanaged job
left untouched`. So a job made in the dashboard survives a reboot (and is also not in git). The reconcile logs a failed
job as `ERROR ...` and the rest continue. The container still exits 0. An unparsable YAML or a
file without a top-level `jobs` list exits 2 and the pod stays in `Init`, on purpose.

To add or change a job, edit `app/cron/jobs.yaml`. Also edit `app/scripts/` or `app/skills/` if the job needs
a new script or skill. Register a new script file in the `hermes-scripts`
generator of `kustomization.yaml`. Then land it like any manifest change. Reloader restarts the pod, and the reconcile runs
before the app starts. The scheduler re-reads `jobs.json` on every tick, so nothing else is needed.
To remove a job, take it out of the file _and_ run `hermes cron remove <id>` in the pod. The
reconcile never deletes. The next boot reverts a change made with `hermes cron edit` or in the dashboard to a field that the file
lists. Check the result with `kubectl -n cortex logs deploy/hermes -c
cron-reconcile` and `hermes cron list`.

Scripts are not symlinks. The scheduler refuses a script that resolves outside `/opt/data/scripts/`,
so `init` copies each `/run/scripts/*.sh` there with mode `0755` on every boot (an edit in git
replaces the copy). `.sh` runs under bash and anything else runs under python. The shebang is ignored.

### cluster-health: script first, agent on new findings

Every 30 minutes `cluster-health-check.sh` runs with no LLM. It does what the skill used to do by
hand: alertmanager v2 alerts (Watchdog excluded), nodes not Ready or under Memory/Disk/PID pressure,
pods Pending for over 10 minutes, `up == 0` targets, and the static smartctl `pantheon` target by
name. It uses only `curl`, `sed` and `sha256sum` (no `jq`, no `kubectl`, no python) and only
endpoints that the network policy admits: alertmanager 9093, victoria-metrics 8428, chaski 8080.

| Outcome                                                         | What happens                                                                                                                                    |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| No findings                                                     | prints the summary, ends with `{"wakeAgent": false}`; posts the chaski `info` itself at most once per 4h (`last-quiet-notify` in the state dir) |
| Findings, same fingerprint as the last wake, woken under 4h ago | prints the summary, ends with `{"wakeAgent": false}`                                                                                            |
| Findings that are new, or the same ones 4h old                  | stores `<epoch> <fingerprint>` in `last-wake`, prints the summary, no gate line, so the agent wakes with the output as its context              |
| alertmanager or VictoriaMetrics unreachable                     | that is a finding (`check-failed: ...`), so it wakes the agent once per 4h                                                                      |

The state files are in `/opt/data/workspace/cluster-health/`. The fingerprint is a hash of the sorted
finding keys (alert fingerprint, node, pod, target), not of the text, so the `since` timestamps do not
change it. A finding that clears does not reset `last-wake`. A flapping alert is deduped for 4h instead
of waking the agent on each flap. The flip side is that nothing wakes when a finding clears, so the agent closes an Open
case row in `resolved-cases.md` at the next wake, not at the moment it resolves. The script writes the stamp
when it decides to wake, not when the run finishes, so the script does not retry a failed agent run for 4h.

The script gate and prompt (`cron/scheduler_prompt.py`, `cron/scheduler.py`): the gate is the last
non-empty stdout line being JSON `{"wakeAgent": false}`. Anything else wakes. On a wake, stdout
(secrets redacted) is injected as a `## Script Output` block above the skill. Empty stdout skips the
agent too. A non-zero exit or a timeout (`HERMES_CRON_SCRIPT_TIMEOUT`) injects a `Script Error` block
and wakes the agent, so the script always exits 0 when it has decided.

To run it by hand against nothing live, use `DRY_RUN=1 STATE_DIR=/tmp/ch bash /opt/data/scripts/cluster-health-check.sh`.
`DRY_RUN=1` prints the chaski payload instead of posting it. The state files still go to `STATE_DIR`,
so always point that somewhere disposable.

### Other cron facts

`cluster-health` was an `interval: 60m` job until 2026-08-16. Interval schedules re-arm from
_completion_, so the run time drifts. A cron expression pins a fixed minute. The job ran every four hours
from 2026-09-07 for cost (§ Cost). It went to a 30-minute script check with agent-on-change on
2026-10-21. Alertmanager already pages in real time, so this job is a supplementary audit, not the
alerting path.

The team retired `readme-sync` on 2026-10-20. The README section it reconciled (`## ⛵ Kubernetes` → `### Directories`) no longer exists, so every run aborted and flagged, at 645K to 1.3M prompt tokens each. It is not in `jobs.yaml`. If it still exists in `jobs.json`, remove it with `hermes cron remove <id>`.

The team retired `forgejo-pr-review` on 2026-09-07. It was the third-largest consumer on the account
and duplicated the human `triage-renovate` skill, which is the path actually used to merge the
Renovate queue. Its skill directory, ConfigMap and HelmRelease mounts are gone from git. The
in-pod copy under `/opt/data/skills/devops/` is inert once the cron job is removed, so delete it by hand if you want it gone.

`cron.catch_up_missed` is `false`. With the v0.22 default (`true`), a slot missed while the pod was
restarting fires once on start. Reloader restarts the pod on every skill or config change. With a
30-minute script cadence, a skipped slot costs nothing, and the next one is at most 30 minutes away.
The scheduler logs the skip and re-anchors to the next slot.

`jobs.json` is runtime state on the PVC (`/opt/data/cron/jobs.json`). It is an object,
`{"jobs": [...], "updated_at": ...}`, owned by uid 10000. Do not hand-edit it. Use
`hermes cron create|edit|pause|resume|remove`, which write it with the right ownership.
`kubectl exec` enters the container as uid 10000 too. The dashboard API is behind pocket-id SSO
(`no_cookie`), so you cannot script it with `API_SERVER_KEY` alone.

```bash
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app -- hermes cron list
```

---

## Skills — read-only from git

Git is the only source of the skills we own: `ls clusters/artemis/kubernetes/apps/cortex/hermes/app/skills/`. Each one is a generated ConfigMap `hermes-skill-<name>`, mounted as a directory at `/etc/hermes-skills/<name>` on `app` and `init`, read-only, and loaded through `skills.external_dirs` in `configmap.yaml`. Nothing is copied onto the PVC, so there is no drift and no orphan to clean up.

- There is no `subPath`. A `subPath` mount never receives ConfigMap updates. A skill with subdirectories places files with `items` in the `persistence` entry (`path: references/x.md`). Scripts carry `mode: 0o755`. Reloader restarts the pod when a ConfigMap changes.
- Hermes cannot change the skills. The mount is read-only, external dirs are read-only to autonomous curation, and `skills.write_approval: true` stages any skill write under `/opt/data/pending/skills/` instead of applying it. A skill change is a PR, merged by a human. See § Changing a skill.
- `skills.disabled` lists every bundled skill except the ones that a cron job names (`grep -A3 '"skills"' /opt/data/cron/jobs.json`). New bundled skills arrive enabled with each image bump. Regenerate the list from `kubectl -n cortex exec deploy/hermes -c app -- cat /opt/data/skills/.bundled_manifest` (first field before `:`).

The bundled skills still live in `/opt/data/skills/<category>/<name>/SKILL.md`, next to `.usage.json` (`use_count` / `last_used_at` / `patch_count` per skill). The startup log line `Syncing bundled skills into ~/.hermes/skills/` is wrong. It syncs into `~/skills/`.

### The anti-collision guard

v0.22 resolves the same skill name in `/opt/data/skills` and in an external dir by precedence. The local copy wins and the git copy is shadowed, with one warning in the log (`agent/skill_utils.py`). Older releases failed loudly with `Ambiguous skill name`. Now a stale local copy runs silently in place of the git skill. So on every boot `init` reads the `name:` of each mounted skill and deletes any directory under `/opt/data/skills` whose `SKILL.md` carries the same name. Before it deletes the directory, it copies any `references/*-triage.md` to `/opt/data/workspace/cluster-health/archive/<file>.full.md` with `cp -n`, so the old history survives the first boot after migration.

Discovery matches the literal filename `SKILL.md` anywhere beneath a skills root, dot-directories included (`iter_skill_index_files` in `agent/skill_utils.py`). Never write a file named `SKILL.md` outside a real skill. A copy parked under a dot-directory once registered a second skill of the same name and stopped the cluster-health audit for about 27 hours. Discovery also walks the `..data` and timestamped directories of a ConfigMap mount, but they resolve to the same file and it deduplicates them.

### cluster-health state

The skill appends to logs, so its state cannot live in the read-only skill directory. Everything it writes is under `/opt/data/workspace/cluster-health/` on the PVC: `resolved-cases.md` (the case index) and one `*-triage.md` recurrence log per alert family. Git ships only static material in the skill (`references/node-baselines.md`, `scripts/`).

The starting content of the state files is `app/seed/cluster-health/`, ConfigMap `hermes-cluster-health-seed`, mounted into `init` only. `init` copies each file with `cp -n`, so it never overwrites live state, and an edit to a seed file in git does not reach a running pod. To re-seed one, delete the live file and restart.

### Changing a skill

A human edits the files under `app/skills/` and lands the change like any manifest change (`AGENTS.md` rule 1). For hermes, the `skill-change-pr` skill opens a PR as dusk-bot through the Forgejo contents API and never merges it (the merge deny glob in § Autonomy posture blocks it).

### Scanner-safety is load-bearing for unattended runs

The security scanner of the agent flags pipes-to-interpreter (`curl … | python3`) and inline
interpreter scripts (`python3 -c`) as HIGH and marks the command `pending_approval`. Skill
instructions must write to a file and parse it in a separate step. They must build JSON payloads with
`write_file` + `curl --data @file` rather than a heredoc, and they must use bash `date` math instead of
python for arithmetic. Note that `write_file` refuses `/tmp` paths (protected), while `curl -o /tmp/...`
is fine.

### Building a Forgejo `contents` PUT payload

There is no shell path for this. The own scanner rules of the skills ban heredocs, and
`execute_code` is unavailable in cron. Use `read_file` on the base64 body and the GET response,
then use `write_file` for the JSON under `/opt/data/workspace` (inside `HERMES_WRITE_SAFE_ROOT`, where a
`/tmp` write would be refused). `skills/skill-change-pr/SKILL.md` carries the canonical shape.

---

## Autonomy posture — what hermes is allowed to do unattended

The team set this on 2026-08-18, after finding that hermes had self-patched its skills 13 times since 2026-08-16
and landed zero of them in git. Two independent gates were each enough to stop it on
their own. Skills are now read-only (§ Skills), which ends the self-patching.

### 1. Cron approvals (`approvals` in `configmap.yaml`)

`cron_mode: deny` blocked every `terminal` call that the smart guardian flagged. The skills do
all their Forgejo and chaski work through `curl`, so that killed both the self-improvement PR flow
_and_ the notification POST. The agent was silently unable to report that it was silently unable
to report. `execute_code` keys off the same setting (`tools/approval.py`), so no workaround
existed inside the pod.

Now `cron_mode: approve`, with enforcement moved to two floors that fire before any bypass
(`_match_user_deny_rule`, `tools/approval.py:3751`):

| Layer                           | Scope                    | Enforces in cron?                                                                                                                   |
| ------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| code-shipped hardline blocklist | `rm -rf /`, poweroff, …  | yes, always                                                                                                                         |
| `approvals.deny` fnmatch globs  | the `terminal` tool only | yes — the real control                                                                                                              |
| `approvals.smart_policy`        | guardian system prompt   | no — ESCALATE resolves to approve under `cron_mode: approve`; it still binds interactive and gateway sessions, and documents intent |
| `mcp-k8s` ClusterRole           | the MCP k8s tools        | yes — RBAC, not approvals                                                                                                           |

The split that matters is that deny globs bound the shell, and RBAC bounds the cluster tools. A glob like
`*kubectl*delete*` does not restrict `k8s_pods_delete`, and never could. The ClusterRole gates that tool
instead. Add a new deny glob with a leading and trailing `*`. Matching is
case-insensitive over deobfuscated command variants, so quoting tricks do not sidestep it.

The current deny globs cover PR merge, force/main push, `talosctl`, `kubectl drain|cordon|delete`,
`flux uninstall|delete`, `helm uninstall`, `ceph osd`, `kubectl get secret`, `/opt/data/.env`,
and pipe-to-shell.

### 2. RBAC — the pod holds none; the MCP path is the only one

hermes reaches the cluster one way: the k8s MCP tools, under `mcp-k8s-sa`, through the `agent` tier of agentgateway. The pod itself has no cluster access:

- It mounts no ServiceAccount token (the `automountServiceAccountToken` default of app-template is
  `false`, and nothing overrides it), and the image has no `kubectl`.
- The `hermes` ServiceAccount exists but is bound to nothing. The team removed its three roles
  (`hermes-read-all`, `hermes-pod-delete`, `hermes-exec-deploy`) on 2026-10-20. With no
  token, none of their grants could ever be exercised, cluster-wide pod delete included.
- No skill or config calls the kube API from inside the pod.
  `grep -rniE 'kubectl|serviceaccount|KUBERNETES_SERVICE' clusters/artemis/kubernetes/apps/cortex/hermes/app/skills`
  finds only prose that says not to.

To verify, run `kubectl auth can-i --list --as=system:serviceaccount:cortex:hermes -n cortex`. It shows only
the self-review and discovery rules that every account has.

`mcp-k8s-sa` (the MCP server) is broader, and cluster-wide. Everything is read-only
(`get/list/watch`) except:

- `deployments/scale`, `statefulsets/scale`, `replicasets/scale`: `get, patch, update`
- `pods`: `delete`; `jobs`: `delete`
- `pods/exec`: `create`; `events`: `create`

`helmreleases` and `kustomizations` are read-only, so the MCP path cannot trigger a Flux
reconcile. Workloads are read-only too, and scale is the only write. The team removed the patch grants on workloads and
Flux objects on 2026-08-29 (see `cortex-mcp.md`). The MCP path cannot create or delete workloads,
and it cannot touch Talos or node-level state.

> **`mcp-k8s` holds no `secrets` rule.** The team removed the grant on 2026-08-29 (see
> `cortex-mcp.md`). The ClusterRole carries only the External Secrets CRs
> (`externalsecrets`, `secretstores`, `clustersecretstores`), which are references, not secret
> data. To verify, run
> `kubectl get clusterrole mcp-k8s -o jsonpath='{range .rules[*]}{.resources}{" -> "}{.verbs}{"\n"}{end}'`
>
> `mcp-k8s-sa` is the only path to the cluster, and it cannot read Secret data. The deny globs
> and the smart-policy ESCALATE rule bound the shell only. Approvals gate the `terminal` tool
> and RBAC gates the k8s tools, so RBAC is the real control. The
> `mcp-k8s` ClusterRole is `clusters/artemis/kubernetes/apps/cortex/mcp/app/k8s/rbac.yaml`.

---

## Operational gotchas

Probes: all three prove that cron is alive, not just that the process answers. Startup and liveness
are an exec probe that needs two things. The unauthenticated `/health` of the gateway on 8642 must answer
(`curl -fsS -m 4`), and `/opt/data/cron/ticker_heartbeat` must be under 300 seconds old. That file
holds `<epoch> <pid>`, and the cron ticker rewrites it about every minute (`record_ticker_heartbeat`
in `cron/jobs.py`). So a gateway that serves HTTP while its scheduler thread is dead fails the
probe. The `/api/health` of the dashboard on 9119 is unauthenticated too and would also work, but 8642 is what
the probes always hit. Readiness stays a plain `httpGet` on `/health`. A restart fixes a stale ticker, and
pulling the pod from the Service would only take the dashboard down with it. Startup
allows `60 × 10s = 10 minutes` for the first heartbeat before liveness can act. Liveness then fails
after `3 × 30s`, with a 10s probe timeout. Boot now takes a minute or so (four init containers, no
download, no source copy), so that budget has slack. Check the init duration on a cold PVC before
you tighten it. The ticker is async (`cron_tick(sync=False)`), so a long agent run does not hold up the
heartbeat. To verify, run `kubectl -n cortex describe pod -l app.kubernetes.io/name=hermes`, which shows no
`Unhealthy` events, and `kubectl -n cortex exec deploy/hermes -c app -- cat /opt/data/cron/ticker_heartbeat`.

HelmRelease timeout: `spec.timeout` was unset, so it inherited the Helm 5m default. With
`strategy: Recreate`, `terminationGracePeriodSeconds: 120` and the init containers, that budget
is too tight. An upgrade timed out mid-audit and Flux rolled back to `hermes.v30`. Now the timeout is `15m`
with install/upgrade remediation retries.

`HERMES_CRON_TIMEOUT` is an inactivity timeout, not a wall-clock cap. Per
`/opt/hermes/cron/jobs.py`, a job that keeps producing output legitimately runs past it, and `0`
disables it entirely. That leaves only the 1800s stale-claim TTL to recover a tick that actually
_died_, so a hung-but-alive run could block indefinitely. It was `0`. It is now `900`. Because
`streaming.enabled: false`, a single slow LLM call is silent for its whole duration. Do not
lower this to "detect" a slow model.

`wait: false` on the Kustomization: `ks.yaml` sets `wait: false` with no `healthChecks`, so
the Kustomization reports `Applied revision` even while the HelmRelease underneath is failing or
rolling back. Judge a hermes deploy by `flux get helmrelease hermes -n cortex`, never by the
Kustomization alone.

`render-ks` cannot validate chart output. It renders the resources of the Flux Kustomization
(the HelmRelease, the ConfigMaps), not the templated chart, so probe or container changes appear
to "not render". Validate those with `helm template` against the app-template chart and the
`spec.values` of the HelmRelease.

Backups, and how an `exec` silently breaks them: the kopiur `SnapshotPolicy` snapshots `/opt/data` hourly to
`atlas` (`kubectl get snapshotpolicy -n cortex hermes`).
`LAST-VERIFIED` is empty, so nobody has restore-verified the snapshots. Use the `restore-drill` skill.

A `kubectl exec` into `app` runs as uid 10000, the container user, so `sh -c`, `cp` and `tee`
write files that the scheduler and the kopia mover (also uid 10000) can read. That closes the failure of
2026-09-07, when root-owned files from an exec made every hourly snapshot fail for seven hours
(kopia fails the whole snapshot on one unreadable file). To verify, and to force a snapshot:

```bash
kubectl -n cortex exec deploy/hermes -c app -- find /opt/data ! -user 10000   # expect only lost+found
kopiur snapshot now --policy hermes -n cortex
```

The repo also warns `Found too many index blobs (1368) ... run 'kopia maintenance'`. That warning is about the
whole `atlas` repository, not hermes, and this file does not address it.

### Run as uid 10000

The pod runs as `10000:10000` with `fsGroup: 10000`, `runAsNonRoot: true`, all capabilities
dropped, no privilege escalation and a read-only root filesystem. The image accepts only uid
10000 when started non-root (`docker/stage2-hook.sh`, `docker/main-wrapper.sh`: any other
non-root uid is refused), and that is the uid that its `hermes` user is built with. The writable paths are
`/opt/data` (the PVC), `/run` (s6, an emptyDir) and `/tmp` (an emptyDir). Nothing else is written.

- `S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES=1` is required. Otherwise s6-overlay refuses an
  emptyDir `/run` (mode 0777). `HERMES_UID`/`HERMES_GID` and every added capability
  are gone. The app container no longer has a `usermod`, a remap or a root `chown`.
- The stage2 hook still calls the config migrator and the dependency refresh through
  `s6-setuidgid`, which needs `CAP_SETGID`. Both fail non-root with `Warning: ... failed;
  continuing` in the boot log. That is expected. The migrator is a no-op anyway while
  `_config_version` in the `user.yaml` key of `configmap.yaml` equals the version of the image (`53` since v0.23.0; run as uid
  10000 it exits 0 and leaves the file unchanged). If an image bump raises the version, raise the
  number in `user.yaml` with it, or add a `config-migrate` init like bjw-s. The dependency refresh
  only matters for opt-in plugin dependencies after an image upgrade.
- The `init` and `install-memini` containers run as 10000 with a read-only root filesystem too.
- No container runs as root. The team removed the one-time `chown-data` init (root, `CHOWN`) that re-owned the
  PVC from uid 1000 to 10000 on 2026-10-27, once every file was `10000:10000`. If someone restores an
  old 1000-owned snapshot outside Kopiur, re-owning it needs a root step again.
  A non-root process cannot chown files it does not own, and `fsGroup` leaves the owner alone.
- Kopiur: `KOPIUR_PUID`/`KOPIUR_PGID` are `10000` in `ks.yaml`, for the `SnapshotPolicy` mover and
  the `Restore` mover (`kopiur.md` § Mover uid). A restore writes files as the mover
  uid, so restoring an older snapshot (owned by 1000) with these settings gives uid 10000 files,
  which is what the pod needs. To change the `Restore` spec, delete the `Restore` CR once so
  Flux recreates it (`kopiur.md`).

### Network policy

`networkpolicy.yaml` selects the hermes pod for ingress and egress, and it drops everything not listed. Ingress: only the `edge-gateway` envoy pods, on 9119 and 9120. Kubelet probes on 8642 come from the
node host, which Cilium always lets through. Nothing else calls 9119, 9120 or the API server on 8642.

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
route on `edge-gateway`, not only those two hosts. SNI filtering needs a `CiliumNetworkPolicy`.

There is no internet egress. Three things try the internet and degrade without it: the
models.dev catalog refresh (served from `/opt/data/models_dev_cache.json`, and every model has an
explicit `context_length`), plugin update checks, and `hermes plugins install`. The last one is
a real constraint. If you bump the memini SHA in `install-memini`, it clones from github.com and installs
dependencies from PyPI, and the init container fails (and the pod stays in `Init`) while the policy
blocks that. For a bump, add a temporary egress rule for `0.0.0.0/0` on 443 with
`just kube apply-ks cortex hermes`, bump, and take it out again.

---

## Notification format

Every skill notification goes through chaski, which owns the layout. The skill supplies data,
and chaski supplies format. Skills POST `{skill, status, summary, stats{}, items[], url}` and
nothing else. For the template mechanics, the dispatch ordering that makes the hermes branch work, and
how to validate a template change offline, see `.agents/references/observability.md`
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
`HERMES_CRON_TIMEOUT` reached, or the gateway hung with the probes passing. First search the gateway log
for `is shadowed by a higher-precedence copy`. It costs one command.
