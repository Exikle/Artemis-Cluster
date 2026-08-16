# Hermes Deployment — Handoff

Plan for bringing the Nous Research **hermes-agent** into Artemis, adapted from
[eleboucher/homelab](https://git.erwanleboucher.dev/eleboucher/homelab/src/branch/main/kubernetes/apps/ai/hermes).
Nothing here is deployed yet. Written 2026-08-13.

**Default model is `opencode-go/deepseek-v4-flash`**, which differs from upstream
(Erwan defaults to `opencode-go/minimax-m3`). See [Model configuration](#model-configuration).

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

Every model Erwan references already exists as a `LitellmModel` in `cortex`:
`deepseek-v4-flash`, `minimax-m3`, `glm-5.2`, `mimo-v2.5`, `qwen3.6-plus`.
No LiteLLM work is required.

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

`config.yaml` in the ConfigMap. Keep upstream's shape but **default to
deepseek-v4-flash**:

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

Since 2026-08-16 the init copies to the real library paths, so **git is authoritative and
overwrites `SKILL.md` on every pod restart.** Anything the agent self-patches into a
`SKILL.md` is lost at the next restart unless it is committed back to this repo (the
skill's own Step 5 auto-commit flow is what closes that loop). Before changing a skill,
diff the live copy against git — the divergence is routinely two-way:

```bash
POD=$(kubectl -n cortex get pod -l app.kubernetes.io/name=hermes -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app -- cat /opt/data/skills/operations/cluster-health/SKILL.md > /tmp/live.md
diff -u kubernetes/apps/cortex/hermes/app/skills/cluster-health/SKILL.md /tmp/live.md
```

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
