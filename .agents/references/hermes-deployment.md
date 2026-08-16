# Hermes Deployment — Handoff

Plan for bringing the Nous Research **hermes-agent** into Artemis, adapted from
[eleboucher/homelab](https://git.erwanleboucher.dev/eleboucher/homelab/src/branch/main/kubernetes/apps/ai/hermes).
Written 2026-08-13 as a plan; **hermes has been deployed since 2026-08-14** and this file
is now the live reference. Sections describing the original port are kept for provenance —
where they disagree with the sections below, the later ones win.

**The default model is `opencode-go/minimax-m3`** as of 2026-08-16, chosen on measured
results (see [Model selection is measured, not assumed](#model-selection-is-measured-not-assumed)).
It was `deepseek-v4-flash` originally; that model burns ~60x the completion tokens for the
same answer.

---

## What Hermes is

A long-running agent gateway: one Deployment holding the agent plus a `code-server`
sidecar over a shared `/opt/data` PVC, talking to LiteLLM for inference and memini
for memory. It is stateful in practice — the PVC holds its home directory, installed
tooling, skills, and session state — so it wants `strategy: Recreate` and a real
backup, not an ephemeral volume.

## Prerequisites — all already satisfied

| Dependency    | Artemis equivalent                      | State     |
| ------------- | --------------------------------------- | --------- |
| LiteLLM       | `litellm.cortex.svc.cluster.local:4000` | running   |
| memini        | `memini.cortex.svc.cluster.local:8080`  | running   |
| SearXNG       | `searxng.cortex.svc.cluster.local:8080` | running   |
| OIDC provider | pocket-id + `pocket-id-operator`        | running   |
| Backups       | `kopiur` components                     | available |
| Secrets       | 1Password via `onepassword-connect`     | running   |

Eight opencode-go models exist as `LiteLLMModel` resources in `cortex`, all declared in
hermes' `config.yaml`: `deepseek-v4-flash`, `minimax-m3`, `glm-5.2`, `mimo-v2.5`,
`qwen3.6-plus`, `qwen3.7-max`, `kimi-k2.6`, `kimi-k2.7-code`. A model missing from
`custom_providers.litellm.models` is unusable by the agent even though LiteLLM serves it.

## Adaptations from upstream

Upstream targets a different cluster. These are the substitutions:

| Upstream                          | Artemis                                 | Notes                                                                                                                        |
| --------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| namespace `ai`                    | `cortex`                                | our AI namespace                                                                                                             |
| `kanidm` (OIDC)                   | `pocket-id`                             | see [OIDC](#oidc) — this is the biggest change                                                                               |
| `miroir` dependency               | drop it                                 | image-mirror service we do not run                                                                                           |
| `components/oidc`                 | **does not exist here**                 | we have no shared OIDC component; write the `PocketIDOIDCClient` directly, as `media/autobrr` and `observability/grafana` do |
| `components/kopiur/hot`           | `components/kopiur/backup`              | our component layout differs — check `kubernetes/components/kopiur/`                                                         |
| `ClusterSecretStore: onepassword` | `onepassword-connect`                   |                                                                                                                              |
| `envoy-internal` gateway          | `internal-gateway` (ns `network`)       |                                                                                                                              |
| `litellm.ai:4000`                 | `litellm.cortex.svc.cluster.local:4000` | never use short cross-namespace names                                                                                        |
| `memini.ai:8080`                  | `memini.cortex.svc.cluster.local:8080`  |                                                                                                                              |
| `searxng.selfhosted:8080`         | `searxng.cortex.svc.cluster.local:8080` |                                                                                                                              |
| `*.erwanleboucher.dev`            | `*.dcunha.io`                           |                                                                                                                              |
| `TZ: Europe/Paris`                | **omit entirely**                       | k8tz handles timezone cluster-wide; setting `TZ` violates repo convention                                                    |

## Layout

Follows the canonical app structure in `.agents/instructions/cluster-conventions.md`:

```text
kubernetes/apps/cortex/hermes/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml      # app-template 5.0.1, its own — never shared
    ├── externalsecret.yaml
    ├── configmap.yaml          # hermes config.yaml
    ├── oidcclient.yaml         # PocketIDOIDCClient
    └── helmrelease.yaml
```

Then add `- ./hermes/ks.yaml` to `kubernetes/apps/cortex/kustomization.yaml` in
alphabetical position.

### ks.yaml

Drop `miroir` and `kanidm` from `dependsOn`; keep `litellm`. Add the kopiur
component per our layout. Substitutions to carry over:

```yaml
postBuild:
    substitute:
        APP: hermes
        APP_NAMESPACE: cortex
        KOPIUR_CAPACITY: 20Gi
        SUBDOMAIN: hermes
```

`OIDC_CALLBACK` / `OIDC_DISPLAY_NAME` are consumed by Erwan's `components/oidc`,
which we do not have — drop them and put the values in `oidcclient.yaml` instead.

## Model configuration

`config.yaml` in the ConfigMap. Shape as below; the `default` shown here is the original
port's — the current default is `minimax-m3`, see the measured table further down:

```yaml
custom_providers:
    - name: litellm
      base_url: http://litellm.cortex.svc.cluster.local:4000/v1
      key_env: LITELLM_API_KEY
      models:
          opencode-go/deepseek-v4-flash:
              context_length: 131072
          opencode-go/minimax-m3:
              context_length: 1000000
          opencode-go/glm-5.2:
              context_length: 1048560
          opencode-go/mimo-v2.5:
              context_length: 262144
          opencode-go/qwen3.6-plus:
              context_length: 262144
model:
    default: opencode-go/deepseek-v4-flash
    provider: custom:litellm
    context_length: 131072
```

**Mind the context length.** Upstream's default carries 1,000,000 tokens;
deepseek-v4-flash has 131,072. The `model.context_length` value must match the
model actually selected, or Hermes will size compaction against a window it does
not have. The larger models stay available as aliases for work that needs them.

Upstream also pins each `auxiliary:` role (approval, compression, web_extract,
vision, curator, …) to a specific model, several to `minimax-m3`. Decide
deliberately whether those follow the new default or stay on the larger models —
the cheap ones (`title_generation`, `goal_judge`, `triage_specifier`) are already
on deepseek-v4-flash upstream.

## OIDC

The largest adaptation. Erwan uses kanidm and reads `client-id` / `client-secret`
from a `kanidm-hermes-oidc` secret. We use pocket-id, where the operator creates
the client and writes the secret. Follow `kubernetes/apps/media/autobrr/app/oidcclient.yaml`:

```yaml
apiVersion: pocketid.internal/v1alpha1
kind: PocketIDOIDCClient
metadata:
    name: hermes
spec:
    clientID: hermes
    callbackUrls:
        - https://hermes.dcunha.io/auth/callback
    launchUrl: https://hermes.dcunha.io/
    allowedUserGroups:
        - name: app-admin
          namespace: security
    secret:
        enabled: true
        storeClientSecret: true
```

Then point the dashboard env at pocket-id's issuer instead of kanidm's, and read
the client id/secret from the operator-created secret rather than `kanidm-hermes-oidc`.

## Storage and backup

`persistence.data` uses `existingClaim: hermes` — provided by the kopiur component
via `KOPIUR_CAPACITY`. 20Gi matches upstream and is sensible: the `install-tools`
init container installs Go, `gh`, and Homebrew into the volume.

There is a **stray `kopiur-cache-hermes-populate` PVC (5Gi, ceph-block) already in
`cortex`** with no owning app — presumably from an earlier abandoned attempt.
Work out whether the new deployment should adopt or replace it before applying,
so you do not end up with two.

## Things to get right

- **Three init containers run in order**: `copy-agent-source` (copies the agent into
  an emptyDir), `init` (materialises config + skills), `install-tools` (Go/gh/brew
  into the PVC). The tolerated `cp` failure in `copy-agent-source` is deliberate —
  hermes-agent ships root-only playwright `.deps` files.
- **The app container runs as root** (`runAsUser: 0`, `readOnlyRootFilesystem: false`)
  with added capabilities, because it manages its own home directory. This is a
  genuine deviation from our default security context — call it out in review
  rather than silently copying it.
- **`strategy: Recreate`** — required, RWO PVC shared by app and codeserver.
  A RollingUpdate deadlocks on Multi-Attach; we hit exactly that with the embedder.
- **`terminationGracePeriodSeconds: 120`** — the agent needs time to finish.
- **No `TZ`** — k8tz injects it. Setting it fails our conventions.
- **Two routes**: dashboard (`9119`) and code-server (`12321`), both internal-only.
  Keep code-server on the internal gateway; it runs with `--auth none`.
- **RBAC** is a broad read-only ClusterRole (pods, nodes, deployments, jobs,
  ingresses, storage). Read-only, but review the scope before applying.

## Deployment order

1. Write the manifests; validate offline with `just kube render-local-ks cortex hermes`
2. Resolve the stray `kopiur-cache-hermes-populate` PVC
3. Create the 1Password `hermes` item (`GH_TOKEN`, `DISCORD_WEBHOOK` if used)
4. Suspend `artemis-cluster` **and** the `hermes` Kustomization
5. `just kube apply-ks cortex hermes`
6. Verify: agent starts, dashboard loads via OIDC, a test prompt routes through
   LiteLLM to deepseek-v4-flash, memini reachable at namespace `hermes`
7. Commit, push, **wait for CI to publish the OCI artifact**, then resume — resuming
   before the artifact lands makes Flux revert to the previous revision
8. `just kube sync ocirepo`

## Reference

Upstream files worth reading in full before starting:

```
kubernetes/apps/ai/hermes/ks.yaml
kubernetes/apps/ai/hermes/app/{helmrelease,configmap,externalsecret,ocirepository}.yaml
kubernetes/apps/ai/hermes/app/skills/
```

Fetch with:

```bash
curl -s https://git.erwanleboucher.dev/api/v1/repos/eleboucher/homelab/contents/kubernetes/apps/ai/hermes
curl -s https://git.erwanleboucher.dev/eleboucher/homelab/raw/branch/main/kubernetes/apps/ai/hermes/app/helmrelease.yaml
```

`hermes-matrix` is a separate app (Matrix bridge) and is **not** required for
hermes itself. Treat it as a later, optional addition.

## Cron skills — install paths and the git/agent divergence trap

The agent's real skill library is **`/opt/data/skills/<category>/<name>/SKILL.md`**
(`$HOME` is `/opt/data`). That is where its ~72 bundled skills live and where it keeps
`/opt/data/skills/.usage.json`, the registry carrying `use_count` / `last_used_at` /
`patch_count` per skill. The startup log prints `Syncing bundled skills into
~/.hermes/skills/ ...` — **that string is wrong**; it actually syncs into `~/skills/`.
Don't trust it, count `find /opt/data/skills -name SKILL.md` instead.

Our three cron skills (`cluster-health`, `forgejo-pr-review`, `readme-sync`) were
originally copied by the `init` container to `/opt/data/.hermes/skills/<name>/`, a path
the agent never reads. Consequences of that, all of which actually happened:

- The skills the agent ran were the ones sitting in `/opt/data/skills/`, seeded once and
  then **never refreshed from git** — `forgejo-pr-review` sat at v1.0.0 in the pod for a
  day after v2.0.0 was committed, still refusing to auto-merge bot PRs.
- Because init never overwrote them, the agent's own self-patches survived and
  accumulated: `cluster-health` reached v1.2.1 in-pod against v1.0.0 in git.

Since 2026-08-16 the init copies to the real library paths. It does **not** copy blindly:
a plain `cp` there would let a routine pod restart silently destroy a self-patch the agent
had made in place, which is the agent breaking its own work with no trace. Instead
`sync_skill` does a three-way compare per skill — the incoming git copy, the live copy,
and `/opt/data/skills/.git-sync/<name>.sha` recording the git content installed last time:

| live vs git | live vs marker | Action                                                       |
| ----------- | -------------- | ------------------------------------------------------------ |
| same        | —              | already in sync; refresh marker, clear any parked copy       |
| differs     | same           | untouched since last sync → snapshot live, install git, mark |
| differs     | differs        | **locally self-patched → keep live**, park git, record drift |

So git updates flow normally, and a self-patch is never overwritten. The cost is that a
diverged skill **stops receiving git updates until reconciled** — deliberate, and made
loud rather than silent:

- `.git-sync/drift.current` is rewritten every boot; `cluster-health` reads it in its Step 2
  sweep and reports any entry as `attention`, so a divergence shows up in Pushover within
  the hour instead of lurking.
- The incoming git version is parked at `<skill>/.git-incoming/SKILL.md` for diffing.
- Superseded live copies are snapshotted to `.git-sync/superseded/<ts>/` (last 10 kept), so
  even an overwrite on the "untouched" path is recoverable.

**Reconciling a drifted skill** has two cases, and the second is the common one:

1. _Git ends up byte-identical to the live copy_ (you committed exactly the self-patch and
   nothing else) — the next restart sees `live == git`, clears the drift and the parked
   copy, and updates resume. Nothing else to do.
2. _Git carries additional changes_ (you merged the self-patch **and** edited the skill) —
   committing is **not** enough. `live` still differs from the new `git`, so the guard keeps
   holding the old live copy and your edits never install. After merging, explicitly accept
   git's version by writing it over the live file, then restart:

```bash
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex get cm hermes-skill-cluster-health -o jsonpath='{.data.SKILL\.md}' > /tmp/merged.md
kubectl -n cortex exec -i "$POD" -c app -- sh -c '
  D=/opt/data/skills/operations/cluster-health
  cat > $D/SKILL.md.tmp && chown 1000:1000 $D/SKILL.md.tmp && chmod 0664 $D/SKILL.md.tmp
  mv $D/SKILL.md.tmp $D/SKILL.md' < /tmp/merged.md
kubectl -n cortex rollout restart deploy/hermes
```

Only do this once you have confirmed the merged copy is a **superset** — that it still
contains the agent's change. Diff it first; the whole point of the guard is that this step
is a deliberate human decision, not an automatic overwrite.

Verify the divergence first:

```bash
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/skills/.git-sync/drift.current
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/skills/operations/cluster-health/SKILL.md > /tmp/live.md
diff -u kubernetes/apps/cortex/hermes/app/skills/cluster-health/SKILL.md /tmp/live.md
```

Do not "fix" drift by deleting the live copy — that discards the agent's work, which is the
exact failure this machinery exists to prevent.

### Why `cp -n` for references/, plain `cp` for scripts/

`references/targetdown-triage.md` is an **append-only recurrence log** the skill writes to
at runtime, so init seeds it with `cp -n` (create-if-absent) and never clobbers it. Edits
to that file in git therefore do **not** propagate to a pod that already has one — to push
a new version, delete the in-pod copy and restart. `scripts/*.sh` is pure code and is
always overwritten.

### The chmod ordering trap

The init's `find /opt/data -user 1000 -type f -exec chmod 0664 {} +` runs late and strips
the exec bit off everything. Any `chmod +x` placed with the `cp` lines is silently undone;
the `find … -name '*.sh' -exec chmod 0775` line must stay **after** that blanket chmod.

### Scanner-safety is load-bearing for unattended runs

The agent's security scanner flags pipes-to-interpreter (`curl … | python3`) and inline
interpreter scripts (`python3 -c`) as HIGH and marks the command `pending_approval`, which
**stalls cron runs** (`approvals.cron_mode: deny`). Skill instructions must write to a file
and parse it in a separate step, build JSON payloads with `write_file` + `curl --data @file`
rather than a heredoc, and use bash `date` math instead of python for arithmetic. Note
`write_file` refuses `/tmp` paths (protected) while `curl -o /tmp/...` is fine.

## Cron jobs — models and schedules

`jobs.json` is **runtime state on the PVC, not in git** (`/opt/data/cron/jobs.json`). It is
owned `hermes:hermes` and the scheduler runs as uid 1000, but `kubectl exec` lands as
**uid 0** — so anything written that way must be `chown 1000:1000 && chmod 0664`'d
immediately or the scheduler is locked out of its own job list. The dashboard API is behind
pocket-id SSO (`no_cookie`), so it cannot be scripted with the `API_SERVER_KEY` alone.
Edit the file, fix ownership, then restart the deployment so the scheduler re-reads it.

| Job                 | Schedule    | Model                    |
| ------------------- | ----------- | ------------------------ |
| `cluster-health`    | `0 * * * *` | `opencode-go/minimax-m3` |
| `forgejo-pr-review` | `0 9 * * *` | `opencode-go/glm-5.2`    |
| `readme-sync`       | `0 8 * * 0` | `opencode-go/glm-5.2`    |

`cluster-health` was an `interval: 60m` job until 2026-08-16. Interval schedules re-arm from
_completion_, so the run time drifted forward every hour (00:06 → 01:12 → …); the cron
expression pins it to the top of the hour, which matters when correlating a notification
against an incident timeline.

### Model selection is measured, not assumed

Every opencode-go model bills at **$0.000/Mtok**, so cost is not a selection criterion —
accuracy and latency are. Measured 2026-08-16 against the actual workload (emit the exact
notification JSON; and a tool call that must omit an unused parameter), 2 runs each:

| Model               | JSON contract | Tool call | Latency | Completion tokens |
| ------------------- | ------------- | --------- | ------- | ----------------- |
| `minimax-m3`        | 2/2           | 2/2       | 1.9s    | 129               |
| `glm-5.2`           | 2/2           | 2/2       | 5.7s    | 1007              |
| `mimo-v2.5`         | 2/2           | 2/2       | 13.1s   | 1222              |
| `deepseek-v4-flash` | 2/2           | 2/2       | 35.9s   | 7934              |
| `qwen3.6-plus`      | 2/2           | 2/2       | 35.5s   | 2444              |
| `qwen3.7-max`       | **1/2**       | 2/2       | 52.9s   | 3206              |
| `kimi-k2.6`         | **1/2**       | 2/2       | 103.3s  | 4384              |

`deepseek-v4-flash` was the default and burned 7934 completion tokens and 36s on a task
`minimax-m3` answered correctly in 129 tokens and 1.9s — it is the least efficient option,
not the most, despite the "flash" name. `qwen3.7-max` and `kimi-k2.6` each failed a run:
`qwen3.7-max` miscounted (`fixed=1` where the answer was 2), which disqualifies it for jobs
whose entire output is counts. Re-run the bake-off before changing an assignment; do not
pick on model naming.

### kimi-k2.7-code rejects `temperature`

The provider 400s on **any** `temperature` value for that model, so every agent call failed
while a bare curl succeeded. Chart-wide `dropParams: true` does not help: LiteLLM only drops
params it knows a provider rejects, and for an OpenAI-compatible passthrough it assumes
`temperature` is supported. Fixed with a per-model `additional_drop_params: ["temperature"]`,
driven by the `dropTemperature` input in `litellmmodels.yaml`.

## Operational gotchas found in the 2026-08-16 audit

**Identity.** `FORGEJO_PAT` resolves to **dusk-bot's** token (1Password `dusk-bot` /
`DUSK_BOT_PAT` — the same identity Renovate uses), not Exikle's. It was Exikle's until
2026-08-16, which meant every PR the review skill merged and every README the sync skill
committed was attributed to the human whose commits are otherwise GPG-signed. dusk-bot
holds admin+push on `Artemis-Cluster` and `frostlink`.

**Probes.** The app container had none, so a hung gateway would sit `Running` while cron
silently stopped firing. All three probes now hit the gateway's **unauthenticated
`/health` on 8642** (the dashboard on 9119 is behind pocket-id and 302s/401s, so it is
useless as a probe target). The startup probe allows 10 minutes — three init containers,
one of which downloads `gh` over the internet — before liveness can act; liveness then
needs 6×30s of unresponsiveness. Do not tighten those without re-checking init duration.

**HelmRelease timeout.** `spec.timeout` was unset, inheriting Helm's 5m default. With
`strategy: Recreate`, `terminationGracePeriodSeconds: 120` and three init containers, that
budget is too tight — an upgrade timed out mid-audit and Flux rolled back to `hermes.v30`.
Now `15m` with install/upgrade remediation retries.

**`HERMES_CRON_TIMEOUT` was `0`.** Per `/opt/hermes/cron/jobs.py`, this is an _inactivity_
timeout, not a wall-clock cap — a job that keeps producing output legitimately runs past
it — and `0` disables it entirely, leaving only the 1800s stale-claim TTL to recover a tick
that actually _died_. A hung-but-alive run could block indefinitely. Now `900` (15 minutes
of silence). Because it is inactivity-based it will not kill a long but active run; note
`streaming.enabled: false`, so a single slow LLM call is silent for its whole duration.

**Auxiliary roles.** Seven `auxiliary:` roles plus `delegation` were pinned to
`deepseek-v4-flash` — the least efficient model measured, on exactly the small frequent
tasks (title generation, goal judging, triage) where its ~7900-token overhead is worst.
All moved to `minimax-m3`; the `dsv4f` alias and the model declaration stay so it remains
selectable.

**`render-local-ks` cannot validate chart output.** It renders the Flux Kustomization's
resources — the HelmRelease, ConfigMaps — not the templated chart, so probe/container
changes appear to "not render". Validate those with `helm template` against the
app-template chart and the HelmRelease's `spec.values`.

**`wait: false` on the Kustomization.** `kubernetes/apps/cortex/hermes/ks.yaml` sets
`wait: false` with no `healthChecks`, so the Kustomization reports `Applied revision` even
while the HelmRelease underneath is failing or rolling back. Judge a hermes deploy by
`flux get helmrelease hermes -n cortex`, never by the Kustomization alone.

**Backups.** `/opt/data` is snapshotted hourly to `atlas` by the kopiur `SnapshotPolicy`
(`H * * * *`). `LAST-VERIFIED` is empty — snapshots are not restore-verified; use the
`restore-drill` skill for that.
