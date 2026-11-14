# CI — home-infra

This file explains how Forgejo Actions runs here: the `oci-push` workflow that builds the Flux
artifact of this repo, the container builds for `Exikle/containers`, the runner that they all share,
and the constraints behind each. Manifests under `clusters/artemis/kubernetes/` carry no comments
(`yaml-conventions.md` § No Comments in Manifests), so the rationale lives here.

Tekton (`tekton-system`, `forgejo/tekton-runner`) was retired on 2026-10-27. Every workflow now runs
on the plain `forgejo-runner`. Do not bring Tekton back to work around a runner limit. Fix the
runner.

---

## Where the workflows live

| Piece                               | Where                                                                          |
| ----------------------------------- | ------------------------------------------------------------------------------ |
| The jobs themselves                 | `Exikle/forgejo-workflows`, `.forgejo/workflows/*.yaml` (reusable)             |
| The callers (triggers, concurrency) | each repo's `.forgejo/workflows/`, pinned to a forgejo-workflows commit        |
| The job image                       | `ci-toolbox` in `Exikle/containers` (`apps/ci-toolbox/`)                       |
| The runner, its labels and podspecs | `clusters/artemis/kubernetes/apps/forgejo/forgejo-runner/app/helmrelease.yaml` |
| The remote image builder            | `clusters/artemis/kubernetes/apps/forgejo/buildkit/`                           |

A change to a shared workflow reaches a repo only when the pin of that repo moves. Renovate moves
pins through the `forgejo-workflows` manager in `exikle/renovate-config`. To test a change before it
is on `main`, push it to a branch of `forgejo-workflows`. Then point a caller on a test branch at
that commit. A pin is just a sha.

Test `oci-push` against scratch repositories, never the real ones. A test caller passes its own
`forgejo-oci-url` and `registry-oci-url` (for example `…/exikle/ci-plain-runner-test`). If you run
against the real URLs from a branch, the run moves the `main` tag onto a branch commit, and Flux
deploys it.

---

## The runner

`forgejo-runner` is the upstream Forgejo runner with the k8s plugin of Erwan Leboucher as a native
sidecar. Every job is its own pod in `forgejo`, built from the podspec that its label names.

| Label                                      | Podspec            | Use                                                        |
| ------------------------------------------ | ------------------ | ---------------------------------------------------------- |
| `ubuntu-latest`, `ubuntu-24.04`, `default` | `podspec-default`  | everything that needs no special mounts                    |
| `buildkit`                                 | `podspec-buildkit` | image builds — mounts the buildkitd client cert            |
| `docker`, `multiarch`                      | `podspec-dind`     | a privileged dind sidecar, for workflows that need dockerd |
| `talos`                                    | `podspec-talos`    | talosctl jobs — mounts a Talos API service account         |

Keep the runner and the plugin on the same major version. The plugin protocol changed between 12.x
and 13.x, and a mismatched pair does not run jobs.

The plugin does these things that the chart does not make obvious:

- `container:` in a workflow replaces the main image of the podspec and keeps everything else:
  volumes, mounts, env, and resources. That is how `buildkit` jobs run `ci-toolbox` and still get
  `/buildkit-certs`. The image must have `sh`. The main command of the plugin is
  `sh -c 'mkdir … && sleep'`.
- Job pods carry the label `app.kubernetes.io/managed-by: forgejo-runner`. The plugin does not use
  pod labels that you set in a podspec. Select job pods by that label (the NetworkPolicy of buildkit
  does).
- The actions cache works from job pods. `actions/cache` and `cache: true` of `jdx/mise-action`
  reach the cache server of the runner on 8088/8089. The cache lives on the `/data` emptyDir of the
  runner pod, so a runner restart empties it. The first run after a rollout is always a miss.
- The memory limit of the plugin sidecar is raised to 512Mi. Upstream reports that the 128Mi of the
  chart runs out of memory at capacity 3. This runner runs at capacity 10.

---

## The two clocks, now only one

A shared-workflow change has two halves: the pin of the caller, which Forgejo reads from git on each
run, and the shared workflow at that pin. Both are git. There is no cluster half any more. The old
Tekton library reconciled from the OCI artifact, and it could lock CI out of shipping its own fix.
If a shared-workflow change breaks `oci-push`, revert the pin of the caller. Nothing in the cluster
has to move first.

The one cluster dependency left is the runner labels. If a workflow asks for a label that the runner
does not offer, it queues forever, silently. Before you land any workflow that uses a new label, add
the label (and its podspec) and make sure that it exists with `fjo api /admin/actions/runners`.

---

## `oci-push`

It is one job with one step, on `ubuntu-latest` with the `ci-toolbox` image. The step does this:

1. It shallow-clones the commit. The `path` input names the folder that becomes the artifact
   root. It defaults to `.` (the whole repo). This repo passes `clusters/artemis`, so the artifact
   holds only the Artemis cluster folder.
2. In the background, it releases to the Forgejo mirror (`git.dcunha.io/exikle/<repo>`).
3. In the foreground, it releases to the standalone registry (`registry.dcunha.io`), then pings Flux.
4. It waits for the mirror and fails the run if the mirror failed.

"Release" is `flux push artifact` → `flux tag artifact --tag main` → `cosign sign` → `cosign verify`.
Each part is retried up to 3 times. Flux reads only the standalone registry, so the webhook fires as
soon as that copy verifies, about 20s after the job starts. The mirror no longer sits in front of it.

Keep the mirror anyway. `registry.dcunha.io` is apoci, in `fediverse/apoci`, which is inside this
cluster. Flux bootstraps the cluster from a registry that the cluster hosts. The Forgejo copy on
LXC 105 is the only artifact that survives when the cluster is down.

A missed webhook ping never fails the run. Flux picks up the artifact on its next poll anyway. The
ping sends an explicit User-Agent, because Cloudflare answers the default of urllib with 403 1010,
which breaks the receiver of Frostlink behind its tunnel.

The workflow has one step, not five. On this runner, each extra step costs about 4s of exec round
trips, so related commands share a step and a job.

---

## Signing is load-bearing

The OCIRepository of `flux-system` sets `verify.provider: cosign` with
`secretRef: cosign-public-key`. Flux **rejects an artifact that it cannot verify**, so a broken
signing key stops reconciliation cluster-wide.

- Any manual recovery push must be signed:
  `flux push artifact` → `flux tag artifact --tag main` →
  `cosign sign --yes --tlog-upload=false --use-signing-config=false --key …`. The key is the
  `cosign` item in the `artemis` 1Password vault.
- Signing is **offline**: nothing is uploaded to the public Rekor log. cosign v3 rejects
  `--tlog-upload=false` on its own (it conflicts with the default `--use-signing-config`), so both
  flags are needed. Every `cosign verify` here passes `--insecure-ignore-tlog`.

`oci-push` pins the public key that Flux trusts in the workflow itself, and does not derive it from
the private key. A run that is signed with the wrong key then fails in CI, not quietly at reconcile.

Two keys stay apart. Only the `cosign` key (which Flux trusts) can sign a cluster artifact, so it is
a **repo** secret on `home-infra` and `frostlink` alone. The account-level `COSIGN_PRIVATE_KEY`
and `COSIGN_PASSWORD` secrets, which the workflows of every repo can read, hold the `cosign-release`
key that signs `containers` images. A repo secret overrides an account secret of the same name,
which makes the split work. Never set the Flux key at account level.

Secrets are job env now. Under Tekton, they crossed into the cluster as Secrets that were mounted
only into the steps that needed them. On the plain runner, every step of a job sees the secrets of
the job. This is one more reason why each workflow is a single step that only its own repo can
change.

---

## Container builds — `container-release` and `container-pull-request`

Both run on the `buildkit` label with the `ci-toolbox` image. They talk to buildkitd over mTLS with
`docker buildx --driver remote`. No dockerd is involved.

- The app version is read straight out of the HCL (`variable "VERSION"` default), not through
  `buildx bake --print`, so resolving it never depends on buildkitd. The tag ladder is the same as
  the app-versions action: an optional `v`, then one to three numeric components.
- Tags go in through a bake override file, not through `--set`. `--set` takes a single reference, so
  it reads a comma-joined list as one invalid tag. The HCL declares an empty
  `docker-metadata-action` target for `image` to inherit.
- Bake `image-all`, never `image`. `image-all` carries the platform list. `image` alone builds only
  the native platform of the builder. One bake invocation pushes a single index to both registries,
  so both get the same digest and there is nothing to merge.
- A pull request publishes nothing (`output=type=cacheonly`, `cache-to=type=inline`). It cannot
  write to either registry, and it cannot poison the cache that the release path reads back.
- The weekly rebuild runs `--no-cache --pull`. Base images sit on mutable tags, and a cached build
  replays old `apk add` layers. The rebuild still exports the registry cache.
- Signing covers the index digest only, on both registries. Nothing verifies per-platform digests,
  so `--recursive` would add signatures that nobody checks.
- Lint runs on the default image, not on `ci-toolbox`. zizmor ships no musl build. Tools come from
  `.mise/config.toml` through `mise-action` with its cache. These are the same pins as
  `mise run lint`.

Validation and release share one buildkitd, on purpose. This includes its `RUN --mount=type=cache`
mounts, which `cacheonly` does not isolate. Pull requests on `containers` come only from the owner
and Renovate. Revisit this if the repo ever takes outside pull requests.

---

## buildkit — the remote builder, and why its security context is loose

### Two boundaries, not one

Two things guard port 1234: **mTLS and** the NetworkPolicy inline in `buildkit/app/helmrelease.yaml`
(`networkpolicies:`). Keep both. Neither replaces the other.

- mTLS: `--tlscacert` makes a client certificate **mandatory**. Both certs come from
  `internal-ca-issuer`. The SAN of the server cert is `buildkit.forgejo.svc.cluster.local`, so the
  address that a job dials must stay that name, or the handshake fails on hostname verification. The
  client cert reaches jobs only through the podspec of the `buildkit` runner label. That podspec
  mounts the `buildkit-client-cert` Secret at `/buildkit-certs`.
- NetworkPolicy: Ingress to 1234 is allowed only from pods in `forgejo` that carry the label
  `app.kubernetes.io/managed-by: forgejo-runner`. The k8s plugin stamps that label on every job pod.

The label was never a credential. Anything that can create a pod in `forgejo` can wear it. The
client cert closes that gap. `usages` keeps the two certs apart (server cert `server auth` only,
client cert `client auth` only). A residual risk remains. Any _other_ cert that is minted from that
CA with a clientAuth EKU would also authenticate. To mint one, you need `Certificate` create RBAC,
which is a far higher bar than creating a pod in `forgejo`, so the team accepted the risk.

> Not closed by any of this: the Role of `forgejo-runner` carries `pods/exec: create` on **every**
> pod in `forgejo`, `buildkit-0` included. An exec bypasses the NetworkPolicy and the TLS listener
> alike.

### Settings that look wrong but are not

| Setting                                                                                                              | Why                                                                                                                                                                                                                                                                |
| -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `container.apparmor.security.beta.kubernetes.io/buildkitd: unconfined` (annotation, not the `appArmorProfile` field) | Rootless buildkitd unshares user namespaces, which the default AppArmor profile denies. app-template rejects the `appArmorProfile` securityContext field, so the annotation is the only route.                                                                     |
| `--oci-worker-no-process-sandbox`                                                                                    | Rootless without `privileged` requires skipping the process sandbox. The pod itself is the isolation boundary.                                                                                                                                                     |
| `allowPrivilegeEscalation: true`, `capabilities.add: [SETUID, SETGID]`                                               | rootlesskit maps UIDs via `newuidmap`/`newgidmap`, which are setuid binaries. If you set `allowPrivilegeEscalation: false`, the kernel denies the exec outright. If you drop SETUID/SETGID from the bounding set, the kernel cannot honor their file capabilities. |
| `readOnlyRootFilesystem: false`                                                                                      | buildkitd writes worker state and snapshots to the root filesystem.                                                                                                                                                                                                |
| liveness/readiness `buildctl --addr unix:///run/user/1000/buildkitd.sock debug workers`                              | `--addr` is repeatable, so buildkitd serves a unix socket alongside the TCP listener purely so the probe has an address it can reach. If the probe pointed at `tcp://localhost:1234` instead, it would need to carry a client cert, since TLS applies there.       |

---

## Workflow shape — what costs time

This is measured on this runner, 2026-10-15 and 2026-10-27 (issue #2807 has the original harness):

| Cost                                   | Plain runner (k8s plugin) |
| -------------------------------------- | ------------------------- |
| Pod start-up per job                   | ~6-10s (image cached)     |
| Each extra step in a job               | ~4s                       |
| Each extra job (chained with `needs:`) | +12-15s                   |

- Cut jobs first, then steps. A job is a pod, so splitting work into jobs only pays when each part
  does more than ~15s of real work in parallel.
- Bake tools into the job image. Do not install them at run time. `ci-toolbox` carries git, jq, yq,
  python3, curl, flux, cosign, docker and buildx. `apk add` costs ~5s a job, and a GitHub download
  can fail.
- Shared logic for small jobs lives in `ci-toolbox` (`run: ci <command>`). You can test it locally
  with `podman run … ci <command> --dry-run`.
- The vulnerability scan is one job for every app. The grype database is a ~4-minute download, and a
  matrix fetched it once per app.

Reference timings after the move: `oci-push` ~31s (Flux pinged at ~20s), labeler ~12s, a containers
PR ~1m with a cached lint, and a single-app sandbox release ~1m15s.

---

## Multi-arch builds (linux/amd64 + linux/arm64)

Every app in `Exikle/containers` builds for both arches, so its image runs on Artemis (amd64) and
Frostlink (arm64). The build never emulates the target arch, because it cannot here:

- The Talos kernel has no `binfmt_misc` at all (not a module, not built in), so no node can register
  QEMU user-mode emulation. `buildkit` only offers `linux/amd64` and `linux/386`.
- `kata-qemu` pods fail with `Unsupported network interface: netkit`. Cilium runs the netkit
  datapath, and Kata does not support it.

So each Dockerfile does everything on `$BUILDPLATFORM` and only _assembles_ the target arch:

- Go: Cross-compile with `GOOS="${TARGETOS}" GOARCH="${TARGETARCH}"` and `CGO_ENABLED=0`, or use
  `xx-go` when cgo is needed.
- Static binaries from upstream images: `COPY --from=<image@digest>` in the final stage resolves the
  variant of the target platform without running anything (`ci-toolbox` takes flux, cosign, docker
  and buildx this way).
- The runtime filesystem: Install the alpine packages of the target arch into an empty root from an
  amd64 container, then `COPY` it into `FROM scratch`. `apps/ci-toolbox/Dockerfile` is the reference
  shape. It handles three things that are not obvious:
    - An amd64 alpine image only trusts amd64 index signatures. Install `alpine-keys` and copy
      `/usr/share/apk/keys/<arch>/*.pub` into the new root, or the index is rejected as UNTRUSTED.
    - It uses `--no-scripts`, because package post-install scripts are target-arch binaries.
    - The busybox applet symlinks normally come from such a script. The Dockerfile recreates them
      from `busybox --list-full` of the build-arch busybox (the applet list is the same).
- Never `RUN` a target-arch binary in a Dockerfile. If an app ever needs that, it needs a native
  arm64 builder, not emulation. Frostlink is the only arm64 machine.

To add arm64 to an app, add `"linux/arm64"` to `image-all` in its `docker-bake.hcl` and convert the
final stage to the rootfs shape. Validate locally with
`podman build --platform linux/arm64 --ignorefile include/.dockerignore apps/<app>`. Anything that
the image needs at build time must sit under `scripts/`, `defaults/` or `entrypoint.sh`, because the
shared `.dockerignore` excludes the rest.

## Known ceiling: Multus

Cluster-wide `FailedCreatePodSandBox` retries dominate the runs. Each retry costs ~17–21s, and a
single unlucky pod can lose more time than every optimization above saves. The team tested two
plausible fixes and disproved both. The evidence and the surviving lead are in issue #1956. Read
that before you theorize about it again.
