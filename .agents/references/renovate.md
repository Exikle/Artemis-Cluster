# Renovate — Preset Pinning, Automerge Policy, Per-App Guards

All of it lives in `.renovaterc.json5` at the repo root. That file is deliberately bare of
prose; every "why" below used to be a comment block in it.

Upstream presets: <https://github.com/home-operations/renovate-presets>

---

## Preset Pinning

```json5
extends: [
  "github>home-operations/renovate-presets#8.1.0",
  "github>home-operations/renovate-presets//apps/cnpg.json5#8.1.0",
  "github>home-operations/renovate-presets//apps/grafanaDashboards.json5#8.1.0",
  "github>home-operations/renovate-presets//apps/searxng.json5#8.1.0",
  "github>home-operations/renovate-presets//apps/talosFactory.json5#8.1.0",
  ":automergePr",
  ":timezone(America/Toronto)",
]
```

### Why every entry carries an explicit tag

Up to and including **6.0.0**, `default.json` reached its content through nested
`github>home-operations/renovate-presets//config/...` references that carried **no tag**.
Renovate resolves an untagged nested preset against the preset repo's **default branch**, not
the tag its parent was pinned at — so the pin was never real.

When upstream deleted `config/`, `managers/`, `overrides/` and `policies/` from `main`
(7.0.0, _"consolidate the general-purpose presets into default.json"_), every consumer pinned to
any older tag started 404ing on the nested fetch and **Renovate aborted in the init phase** — no
dependency updates at all.

**7.0.0 is the first release whose files are self-contained.** Before bumping this pin to any
new tag, verify the target tag has no self-references:

```bash
curl -sf "https://api.github.com/repos/home-operations/renovate-presets/git/trees/<TAG>?recursive=1" \
  | jq -r '.tree[]|select(.type=="blob")|.path'
# then, for default.json and each apps/*.json5 this repo extends:
curl -sf "https://raw.githubusercontent.com/home-operations/renovate-presets/<TAG>/default.json" \
  | grep -n "home-operations/renovate-presets" || echo "self-contained"
```

A silent abort looks exactly like "no updates were due" — check the Renovate log, not the PR list.

### Why the apps/ presets are listed individually

**6.0.0 made the `apps/` presets opt-in** — the root preset no longer pulls them in, so every
app-specific manager/datasource this repo depends on has to be listed explicitly. Dropping one
is silent: the custom manager simply stops extracting and the dependency goes stale with no error.

| Preset                    | What it feeds here                   |
| ------------------------- | ------------------------------------ |
| `cnpg.json5`              | `Cluster.spec.imageName`             |
| `grafanaDashboards.json5` | the 16 `grafanadashboard.yaml` files |
| `searxng.json5`           | searxng's sha-suffixed tags          |
| `talosFactory.json5`      | `talos/*.j2`                         |

### 7.0.0 ➔ 8.0.0 — the helm-values narrowing

The entire diff is one change in `default.json`: the `helm-values` manager's scope narrows from
the broad `/\.ya?ml(?:\.j2)?$/` glob to only `values.yaml`, `helmrelease.yaml` and `hr.yaml`
(plus `.yml` / `.j2` variants). Upstream's reason is that bare `image:` lines were being
double-extracted alongside the `kubernetes` manager, inflating grouped-update counts against
`minimumGroupSize`.

**This is a no-op here only because every HelmRelease in this repo is named `helmrelease.yaml`.**
The `kubernetes` manager still uses the old broad glob, so it covers everything helm-values gave
up. If a HelmRelease is ever added under a different filename, its `spec.values.image.*` block
stops being extracted — with no error.

---

## Commit Signing — Model A

```json5
automergeStrategy: "squash",
```

Squash-merge so Forgejo creates one merge commit it can sign with the instance SSH key
(`MERGES=always`). **No `platformCommit`, no local GPG signing** — the instance is the sole signer
for bot commits.

This is why no rule here sets `automergeType: "branch"`: that would push the bump straight to
`main`, skipping the PR-and-squash path that lets the instance sign, and land unsigned bot commits
on a protected branch. Inheriting `:automergePr` keeps everything on the signed path.

(Frostlink made the opposite choice — it sets `platformCommit: "enabled"` to cover both
`automergeType` paths. The two repos are not interchangeable here.)

---

## Per-App Guards

These override the broad automerge rules above them. Later `packageRules` win, so **order matters**.

### Talos — never automerge

The cluster is on a Talos prerelease — **v1.14.0-rc.1** as of 2026-08-21, on all seven nodes.
Renovate follows the prerelease stream once `currentValue` is unstable, and
`factory.talos.dev/versions` lists betas and RCs — so with automerge on, an `rc.2` release would
merge itself and **tuppr would drain and roll all seven nodes unattended**.

Deliberately **not** scoped to `matchDatasources`. The Talos version is pinned in two places that
resolve to the same `packageName` through different datasources:

- the installer image in `talos/*.j2` → `custom.talos-factory`
- the `talos` CLI in `.mise/config.toml` → `github-tags`, via the mise manager

A datasource filter covers only the first, leaving the CLI to automerge on the patch/minor rules
and silently drift away from the version it renders configs for — the exact drift the pin exists
to prevent.

Keep manual until the cluster is back on a stable version.

### pocket-id — the operator halts on an unsupported version

pocket-id is reconciled by pocket-id-operator, which **refuses to manage a pocket-id newer than
the release it was built against**: `reconcileVersion` calls `haltIfUnsupportedVersion`, which logs
_"Pocket-id version is unsupported by this operator; halting"_ and exits the manager. The container
then CrashLoopBackOffs forever.

pocket-id itself keeps serving — the Deployment is untouched — so the only symptom is that every
`PocketIDOIDCClient`, `PocketIDUser` and `PocketIDUserGroup` **silently stops reconciling**.

That is exactly what **#1622** did: v2.14.0 released 2026-08-18 and automerged the same day on the
"Auto-merge all minor updates" rule, against operator v0.13.1 — the newest release, which names
v2.14.0 as its `firstUnsupportedVersion`.

**The bump is one-way and pinning back does NOT undo it.** pocket-id runs its schema migrations on
first start, and an older binary refuses to boot against a newer schema (_"downgrades are not
allowed"_). **#1623** tried exactly that and took the IdP down until **#1624** restored v2.14.0.
Recovering from a bad bump means a **database restore**, not a redeploy — which is the whole reason
these must not automerge.

The operator lags pocket-id by days-to-weeks on every minor, so this will recur. Bump only after an
operator release lists the target as tested.

### Eco — track only promoted `-beta` tags

strangeloopgames publishes four tag streams against the same version: the promoted build
`0.14.0.2-beta`, the CI builds `0.14.0.2-beta-release-1054` and `0.14.0.0-beta-staging-3328`, and
`latest`.

Docker versioning reads everything after the first `-` as a compatibility suffix, so a pin on a
`-release-NNNN` tag has a suffix no other tag shares and **Renovate crosses streams to satisfy it**
— that is how the pin went `0.14.0.1-beta-release-1052 ➔ 0.14.0.2-beta`.

Anchoring the versioning regex on `-beta` leaves only the promoted builds visible, and the fourth
component maps to `build`, which Renovate ranks as a patch-level bump.

### rook-ceph — never automerge, group only

**A rook chart _patch_ is enough to move Ceph across a security boundary.** The chart carries a
default `cephImage.tag`, and v1.20.4 ➔ v1.20.5 shifted it from v20.2.2 to v20.2.4 — the
CVE-2025-30156 release, which introduces the aes256k CephX key type and raises two HEALTH_ERR
checks until daemon keys are rotated.

Only the repo-side `cephImage` pin stopped **#1676** (v1.20.5 ➔ v1.20.6, automerged 2026-08-20)
from carrying that upgrade in unattended, with no rotation or `muteHealthWarning` config in place.
Hence `automerge: false` on the group rather than relying on the pin alone.

**Ceph majors are a further one-way trap.** rook lists `supportedVersions = {Squid, Tentacle}` and
`validateCephVersion` refuses anything outside it — but the CephCluster CR still applies, so Flux
reports the HelmRelease **Ready** while the operator has quietly stopped managing the cluster.
Several public repos are sitting in that state.

Note that an RC carries no prerelease suffix, so `ignoreUnstable` cannot catch one: Ceph encodes
the release type in the minor field (`x.0.z` dev, `x.1.z` RC, `x.2.z` stable —
[docs](https://docs.ceph.com/en/latest/releases/general/)), which is why v21.1.0 (Umbrella RC) was
once raised as an ordinary major bump.

Upgrade sequence and CephX rationale: `.agents/references/rook-ceph.md`.

### The zer0ver guard

The zer0ver policy (preset 5.0.0+) reclassifies 0.x minors as breaking: they get a
`feat(scope)!:` prefix and land on a `major-` branch. **That is presentation only** — `updateType`
stays `"minor"`, so an unguarded rule here still automerges them. The preset says as much: a guard
shipped upstream would just be overridden by this rule, so it has to live here as
`matchCurrentVersion: "!/^v?0\\./"`.

Without it, 0.x minors on core infrastructure automerge to production — flux-operator
0.57.0 ➔ 0.58.0 was queued on `renovate/major-flux-operator` and would have gone in unattended.

### Disabled managers

| Packages                                               | Why disabled                                                                                                                                                                           |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `actions/upload-artifact`, `actions/download-artifact` | Forgejo supports only up to v3; v4+ uses a GHES-incompatible backend                                                                                                                   |
| `tekton/setup`, `tekton/pipeline`                      | provided by the tekton-runner itself, not fetched from a forge — the github-actions manager resolves bare `owner/repo` against github.com, so every branch reported a no-result lookup |

---

## Grafana Dashboards

Dashboard revisions are bare integers, so **every bump reads as `major`** — that is the
datasource's shape, not a breaking change, hence `automerge: true` on
`matchDatasources: ["custom.grafana-dashboards"]` + `matchUpdateTypes: ["major"]`.

No `automergeType` override here — see **Model A** above for why `branch` is off the table.

---

## Tekton Manager Scoping

Renovate's `tekton` manager ships with an **empty** `managerFilePatterns`, so it is inert until
scoped explicitly, and the home-operations preset does not extend it.

```json5
tekton: {
  managerFilePatterns: ["kubernetes/apps/forgejo/tekton-runner/library/**/*.yaml"],
}
```

It reads `spec.steps[].image`, `spec.sidecars[].image`, `spec.stepTemplate.image` and StepAction
`spec.image` **structurally**, without needing `# renovate:` annotations — so those are deliberately
absent in that directory.

**Keep the scope narrow**: the extractor ignores `kind`/`apiVersion` and would happily probe
unrelated manifests.

---

## Lock File Maintenance

**Nine** of the ten tools in `.mise/config.toml` are `latest` — `talos` is the only pin — so
`.mise/mise.lock` is the only thing pinning the rest, and nothing was refreshing it. flate,
kopiur, minijinja, oxfmt, python, shellcheck, uv, yayamlls and zizmor were all frozen at whatever
resolved when the lock was last written.

It needs its **own schedule** — the top-level `"at any time"` would run this every pass.

Renovate runs `mise lock --bump` for this, which needs the mise binary. It is deliberately **not**
added to `allowedUnsafeExecutions` — mise >= 2026.7.12 gets safe mode (`MISE_SAFE=1`) instead,
which resolves versions over HTTP without letting project config shell out. If the runner ever
ships an older mise, Renovate logs a warning and skips; it does not half-write the lock.

Left off automerge on purpose: these tools back the `just` recipes and the flate CI workflow, so
the monthly bump gets eyes on it.

---

## Grouping

| Group           | Matches                                                             | `minimumGroupSize`    |
| --------------- | ------------------------------------------------------------------- | --------------------- |
| `flux-operator` | `/flux-operator/`, `/flux-instance/`                                | 2                     |
| `rook-ceph`     | `/rook-ceph/`, `/rook-ceph-cluster/` (docker + helm)                | 2, `automerge: false` |
| `kubernetes`    | `siderolabs/kubelet`, kube-apiserver/-controller-manager/-scheduler | 2                     |
| `cilium`        | `cilium/charts/cilium`, `charts-mirror/cilium`                      | 2                     |
| `envoy-gateway` | `envoyproxy/gateway-helm`                                           | 2                     |

`minimumGroupSize: 2` means these raise **individually** unless both halves of the pair move in
the same run. A lone `flux-instance` bump arriving as its own PR is the rule working, not a
misconfiguration.

---

## Merging a batch — read `commit-style.md` first

The single most expensive Renovate footgun here is not in `.renovaterc.json5` at all: **never
queue `merge_when_checks_succeed` on more than one PR at a time.** Queued PRs race on the `main`
ref; losers report `merged=true` with a `merge_commit_sha` that is left dangling and never becomes
reachable from `main`, and the API reports no error. On 2026-08-19 nine PRs were queued that way
and three were lost, recovered later by cherry-pick.

Full mechanism, the two related traps, and the sequential `tea`-based merge-and-verify loop:
`.agents/instructions/commit-style.md` § Never batch `merge_when_checks_succeed`. It is not
restated here.

---

## Where Artemis and Frostlink deliberately differ

Both repos have a `renovate.md` and the mechanisms rhyme, so the divergences are easy to
mis-copy. These are intentional:

|                            | Artemis                                                        | Frostlink                                            |
| -------------------------- | -------------------------------------------------------------- | ---------------------------------------------------- |
| Preset pin                 | `8.1.0`                                                        | `8.0.0`                                              |
| `apps/` presets extended   | cnpg, grafanaDashboards, searxng, talosFactory                 | cnpg, phanpy, talosFactory                           |
| Signing                    | `:automergePr`, **no** `platformCommit`                        | `platformCommit: "enabled"`, no `:automergePr`       |
| `automergeType: "branch"`  | never used — would land unsigned on main                       | used for Forgejo Actions                             |
| Container-digest automerge | **unscoped** — every `docker` digest                           | scoped to `matchPackageNames: ["/home-operations/"]` |
| Talos automerge guard      | `matchPackageNames: ["siderolabs/talos"]`, datasource-agnostic | none — only a file-path guard on `tuppr/upgrades/**` |
| tuppr guard                | not needed (the Talos guard covers it)                         | `matchFileNames` + `minimumReleaseAge: "7 days"`     |

Do not "harmonise" a row without reading both files' rationale for it.
