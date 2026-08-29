# Hermes — Artemis-Cluster

Operational reference for the Nous Research **hermes-agent** running in `cortex`. Deployed
2026-08-14, ported from [eleboucher/homelab](https://git.erwanleboucher.dev/eleboucher/homelab).
The port is finished; nothing here describes how to redo it. Verified against the live
deployment 2026-08-21 (HelmRelease `hermes.v48`, image `nousresearch/hermes-agent:v2026.8.16.2`).

Manifests: `kubernetes/apps/cortex/hermes/`. Skills that ship from git:
`kubernetes/apps/cortex/hermes/app/skills/`.

---

## What it is

One Deployment, `strategy: Recreate`, two containers over a shared RWO PVC:

| Container    | Image                       | Role                                                        |
| ------------ | --------------------------- | ----------------------------------------------------------- |
| `app`        | `nousresearch/hermes-agent` | the agent gateway — dashboard `:9119`, health `:8642`, cron |
| `codeserver` | `ghcr.io/coder/code-server` | `:12321`, `--auth none`, edits `/opt/data` directly         |

Three init containers run in order:

1. `copy-agent-source` — copies `/opt/hermes` into an emptyDir. Its `cp` failure is tolerated on
   purpose: hermes-agent ships root-only playwright `.deps` files, and the script re-fails on any
   error that is not `Permission denied`.
2. `init` — writes `config.yaml` and `.env`, then three-way-syncs the git skills (below).
3. `install-tools` — downloads `gh` 2.61.0, Go 1.23.5 and Homebrew into the PVC, each guarded by
   an existence check so a restart is fast.

`$HOME` is `/opt/data`, which is the `hermes` PVC (20Gi `ceph-block`, `existingClaim: hermes`
from `components/kopiur/backup`). It holds the home directory, installed tooling, the skill
library, cron state and session history — that is why `Recreate` is mandatory (a RollingUpdate
deadlocks on Multi-Attach) and why the volume is backed up.

Two routes, both on `internal-gateway`:

| Hostname                | Backend port | Auth                                            |
| ----------------------- | ------------ | ----------------------------------------------- |
| `hermes.dcunha.io`      | `9119`       | pocket-id OIDC, `GATEWAY_ALLOWED_USERS: exikle` |
| `hermes-code.dcunha.io` | `12321`      | **none** — code-server runs `--auth none`       |

`hermes-code.dcunha.io` is unauthenticated by design and is safe only because it never leaves
the internal gateway. Do not attach it to `external-gateway` or `edge-gateway`.

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

| Env                                       | 1Password item → field                 |
| ----------------------------------------- | -------------------------------------- |
| `LITELLM_API_KEY` / `SUMMARY_LLM_API_KEY` | `litellm` → `MASTER_KEY`               |
| `MEMINI_API_KEY`                          | `memini` → `MEMINI_API_KEY`            |
| `HERMES_DASHBOARD_OIDC_CLIENT_SECRET`     | `hermes` → `HERMES_OIDC_CLIENT_SECRET` |
| `API_SERVER_KEY`                          | `hermes` → `API_SERVER_KEY`            |
| `FORGEJO_PAT`                             | **`dusk-bot` → `DUSK_BOT_PAT`**        |

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

- **Default is `opencode-go/minimax-m3`** with `model.context_length: 1000000`.
- **`model.context_length` must match the model actually selected.** Leave a smaller model's
  window in place and hermes sizes compaction against a window it does not have.
- **All eleven `auxiliary:` roles are on `minimax-m3`**, as is `delegation` — approval,
  compression, web_extract, session_search, vision, goal_judge, title_generation,
  profile_describer, triage_specifier, kanban_decomposer, curator. They were pinned to
  `deepseek-v4-flash` until 2026-08-16, which put the least efficient model on exactly the small
  frequent tasks where its ~7,900-token overhead hurts most.
- `fallback_providers` is `glm-5.2` then `mimo-v2.5`.
- `moa.presets.council` fans out to minimax-m3 / glm-5.2 / mimo-v2.5 and aggregates with
  minimax-m3.
- `SUMMARY_LLM_MODEL` is `opencode-go/qwen3.6-plus` and is set in **env, not `config.yaml`** —
  changing the default model does not move it.

### Model selection is measured, not assumed

Every opencode-go model bills at **$0.000/Mtok**, so cost is not a selection criterion — accuracy
and latency are. Measured 2026-08-16 against the actual workload (emit the exact notification
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

## Cron jobs

| Job                 | Schedule    | Model                    |
| ------------------- | ----------- | ------------------------ |
| `cluster-health`    | `0 * * * *` | `opencode-go/minimax-m3` |
| `forgejo-pr-review` | `0 9 * * *` | `opencode-go/glm-5.2`    |
| `readme-sync`       | `0 8 * * 0` | `opencode-go/glm-5.2`    |

`cluster-health` was an `interval: 60m` job until 2026-08-16. Interval schedules re-arm from
_completion_, so the run time drifted forward every hour (00:06 → 01:12 → …); the cron expression
pins it to the top of the hour, which matters when correlating a notification against an incident
timeline.

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

| Skill               | In-pod path                                   |
| ------------------- | --------------------------------------------- |
| `cluster-health`    | `/opt/data/skills/operations/cluster-health/` |
| `forgejo-pr-review` | `/opt/data/skills/devops/forgejo-pr-review/`  |
| `readme-sync`       | `/opt/data/skills/operations/readme-sync/`    |

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
delete the in-pod copy and restart. `scripts/*.sh` is pure code and is always overwritten.

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
| `k8s_*` MCP tools        | `mcp-k8s-sa`   | LiteLLM `ops` tier, RBAC gated   |

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

> **`mcp-k8s` holds `secrets: list`, and that is intended.** In Kubernetes RBAC, `list` on secrets
> returns the secret **data**, not just names — there is no "names only" verb, so the grant is
> read-every-credential or nothing. hermes is meant to have it. **Treat the `ops` MCP tier as
> credential-equivalent** and scope access to it accordingly: anyone or anything that can call
> `ops` can read every Secret in the cluster.
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

**Backups.** `/opt/data` is snapshotted hourly to `atlas` by the kopiur `SnapshotPolicy`
(`kubectl get snapshotpolicy -n cortex hermes`). `LAST-VERIFIED` is empty — snapshots are not
restore-verified; use the `restore-drill` skill for that.

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
