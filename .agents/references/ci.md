# CI — Artemis-Cluster

How Forgejo Actions runs here: the `oci-push` workflow that builds this repo's Flux artifact, the
container builds for `Exikle/containers`, the runner they all share, and the constraints behind
each. Manifests under `kubernetes/` carry no comments (`yaml-conventions.md` § No Comments in
Manifests), so the rationale lives here.

Tekton (`tekton-system`, `forgejo/tekton-runner`) was retired on 2026-10-27. Every workflow runs on
the plain `forgejo-runner` now. Do not bring Tekton back to work around a runner limit — fix the
runner.

---

## Where the workflows live

| Piece                               | Where                                                                   |
| ----------------------------------- | ----------------------------------------------------------------------- |
| The jobs themselves                 | `Exikle/forgejo-workflows`, `.forgejo/workflows/*.yaml` (reusable)      |
| The callers (triggers, concurrency) | each repo's `.forgejo/workflows/`, pinned to a forgejo-workflows commit |
| The job image                       | `ci-toolbox` in `Exikle/containers` (`apps/ci-toolbox/`)                |
| The runner, its labels and podspecs | `kubernetes/apps/forgejo/forgejo-runner/app/helmrelease.yaml`           |
| The remote image builder            | `kubernetes/apps/forgejo/buildkit/`                                     |

A change to a shared workflow reaches a repo only when that repo's pin moves. Renovate moves pins
through the `forgejo-workflows` manager in `exikle/renovate-config`. To test a change before it is
on `main`, push it to a branch of `forgejo-workflows` and point a caller on a test branch at that
commit — a pin is just a sha.

**Test `oci-push` against scratch repositories, never the real ones.** A test caller passes its
own `forgejo-oci-url`/`registry-oci-url` (e.g. `…/exikle/ci-plain-runner-test`). Run against the
real URLs from a branch, it would move the `main` tag onto a branch commit and Flux would deploy it.

---

## The runner

`forgejo-runner` is the upstream Forgejo runner with Erwan Leboucher's k8s plugin as a native
sidecar. Every job is its own pod in `forgejo`, built from the podspec its label names.

| Label                                      | Podspec            | Use                                                        |
| ------------------------------------------ | ------------------ | ---------------------------------------------------------- |
| `ubuntu-latest`, `ubuntu-24.04`, `default` | `podspec-default`  | everything that needs no special mounts                    |
| `buildkit`                                 | `podspec-buildkit` | image builds — mounts the buildkitd client cert            |
| `docker`, `multiarch`                      | `podspec-dind`     | a privileged dind sidecar, for workflows that need dockerd |
| `talos`                                    | `podspec-talos`    | talosctl jobs — mounts a Talos API service account         |

**Keep the runner and the plugin on the same major version.** The plugin protocol changed between
12.x and 13.x; a mismatched pair does not run jobs.

What the plugin does that is not obvious from the chart:

- **`container:` in a workflow replaces the podspec's main image and keeps everything else** —
  volumes, mounts, env, resources. That is how `buildkit` jobs run `ci-toolbox` and still get
  `/buildkit-certs`. The image must have `sh`; the plugin's main command is `sh -c 'mkdir … && sleep'`.
- **Job pods are labelled `app.kubernetes.io/managed-by: forgejo-runner`.** Pod labels set in a
  podspec are not used; select job pods by that label (buildkit's NetworkPolicy does).
- **The actions cache works from job pods.** `actions/cache` and `jdx/mise-action`'s `cache: true`
  reach the runner's cache server on 8088/8089. The cache lives on the runner pod's `/data`
  emptyDir, so **a runner restart empties it** — the first run after a rollout is always a miss.
- **The plugin sidecar's memory limit is raised to 512Mi.** The chart's 128Mi is reported to OOM at
  capacity 3 upstream; this runner runs at capacity 10.

---

## The two clocks, now only one

A shared-workflow change has two halves: the caller's pin, read from git on each run, and the
shared workflow at that pin. Both are git. There is no cluster half any more — the old Tekton
library reconciled from the OCI artifact and could lock CI out of shipping its own fix. If a
shared-workflow change breaks `oci-push`, revert the caller's pin; nothing in the cluster has to
move first.

The one cluster dependency left is **runner labels**. A workflow that asks for a label the runner
does not offer queues forever, silently. Add the label (and its podspec) and confirm it with
`fjo api /admin/actions/runners` before landing any workflow that uses it.

---

## `oci-push`

One job, one step, on `ubuntu-latest` with the `ci-toolbox` image:

1. shallow-clone the commit;
2. in the background, release to the Forgejo mirror (`git.dcunha.io/exikle/<repo>`);
3. in the foreground, release to the standalone registry (`registry.dcunha.io`), then ping Flux;
4. wait for the mirror and fail the run if it failed.

"Release" is `flux push artifact` → `flux tag artifact --tag main` → `cosign sign` → `cosign verify`,
each retried up to 3 times. Flux reads only the standalone registry, so the webhook fires as soon as
that copy verifies — about 20s after the job starts — and the mirror no longer sits in front of it.

**Keep the mirror anyway.** `registry.dcunha.io` is apoci, in `fediverse/apoci` — inside this
cluster. Flux bootstraps the cluster from a registry the cluster hosts. The Forgejo copy on LXC 105
is the only artifact that survives the cluster being down.

**A missed webhook ping never fails the run.** Flux picks the artifact up on its next poll anyway.
The ping sends an explicit User-Agent because Cloudflare answers urllib's default with 403 1010,
which breaks Frostlink's receiver behind its tunnel.

**One step, not five.** On this runner each extra step costs ~4s of exec round-trips, so related
commands share a step and a job.

---

## Signing is load-bearing

`flux-system`'s OCIRepository sets `verify.provider: cosign` with `secretRef: cosign-public-key`.
Flux **rejects an artifact it cannot verify**, so a broken signing key stops reconciliation
cluster-wide.

- Any manual recovery push must be signed:
  `flux push artifact` → `flux tag artifact --tag main` →
  `cosign sign --yes --tlog-upload=false --use-signing-config=false --key …`. The key is the
  `cosign` item in the `artemis` 1Password vault.
- Signing is **offline**: nothing is uploaded to the public Rekor log. cosign v3 rejects
  `--tlog-upload=false` on its own (it conflicts with the default `--use-signing-config`), so both
  flags are needed. Every `cosign verify` here passes `--insecure-ignore-tlog`.

**`oci-push` pins the public key Flux trusts in the workflow itself**, rather than deriving it from
the private key. A run signed with the wrong key then fails in CI instead of quietly at reconcile.

**Two keys, kept apart.** Only the `cosign` key (Flux trusts it) can sign a cluster artifact, so it
is a **repo** secret on `Artemis-Cluster` and `frostlink` alone. The account-level
`COSIGN_PRIVATE_KEY`/`COSIGN_PASSWORD` secrets, which every repo's workflows can read, hold the
`cosign-release` key that signs `containers` images. A repo secret overrides an account secret of
the same name, which is what makes the split work. Never set the Flux key at account level.

**Secrets are job env now.** Under Tekton they crossed into the cluster as Secrets mounted only into
the steps that needed them. On the plain runner every step of a job sees the job's secrets, which is
one more reason each workflow is a single step that only its own repo can change.

---

## Container builds — `container-release` and `container-pull-request`

Both run on the `buildkit` label with the `ci-toolbox` image and talk to buildkitd over mTLS with
`docker buildx --driver remote`. No dockerd is involved.

- **The app version is read straight out of the HCL** (`variable "VERSION"` default), not via
  `buildx bake --print`, so resolving it never depends on buildkitd. The tag ladder is the same as
  the app-versions action: an optional `v`, then one to three numeric components.
- **Tags go in through a bake override file, not `--set`.** `--set` takes a single reference, so a
  comma-joined list is read as one invalid tag. The HCL declares an empty `docker-metadata-action`
  target for `image` to inherit.
- **Bake `image-all`, never `image`.** `image-all` carries the platform list; `image` alone builds
  only the builder's native platform. One bake invocation pushes a single index to both registries,
  so both get the same digest and there is nothing to merge.
- **A pull request publishes nothing** — `output=type=cacheonly`, `cache-to=type=inline` — so it
  cannot write to either registry or poison the cache the release path reads back.
- **The weekly rebuild runs `--no-cache --pull`.** Base images sit on mutable tags, and a cached
  build replays old `apk add` layers. It still exports the registry cache.
- **Signing covers the index digest only**, on both registries. Nothing verifies per-platform
  digests, so `--recursive` would add signatures nobody checks.
- **Lint runs on the default image, not `ci-toolbox`.** zizmor ships no musl build. Tools come from
  `.mise/config.toml` through `mise-action` with its cache, the same pins as `mise run lint`.

**Validation and release share one buildkitd, on purpose**, including its `RUN --mount=type=cache`
mounts, which `cacheonly` does not isolate. Pull requests on `containers` come only from the owner
and Renovate. Revisit if the repo ever takes outside pull requests.

---

## buildkit — the remote builder, and why its security context is loose

### Two boundaries, not one

Port 1234 is guarded by **mTLS and** the NetworkPolicy inline in
`buildkit/app/helmrelease.yaml` (`networkpolicies:`). Keep both; neither replaces the other.

- **mTLS** — `--tlscacert` makes a client certificate **mandatory**. Both certs come from
  `internal-ca-issuer`; the server cert's SAN is `buildkit.forgejo.svc.cluster.local`, so the
  address a job dials must stay that name or the handshake fails on hostname verification. The
  client cert reaches jobs only through the `buildkit` runner label's podspec, which mounts the
  `buildkit-client-cert` Secret at `/buildkit-certs`.
- **NetworkPolicy** — ingress to 1234 only from pods in `forgejo` labelled
  `app.kubernetes.io/managed-by: forgejo-runner`, the label the k8s plugin stamps on every job pod.

The label was never a credential: anything that can create a pod in `forgejo` can wear it. That is
what the client cert closes. `usages` keeps the two certs apart (server cert `server auth` only,
client cert `client auth` only). The residual is that any _other_ cert minted from that CA with a
clientAuth EKU would also authenticate; minting one needs `Certificate` create RBAC, a far higher
bar than creating a pod in `forgejo`, so it was accepted.

> Not closed by any of this: `forgejo-runner`'s Role carries `pods/exec: create` on **every** pod in
> `forgejo`, `buildkit-0` included. An exec bypasses the NetworkPolicy and the TLS listener alike.

### Settings that look wrong but are not

| Setting                                                                                                              | Why                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `container.apparmor.security.beta.kubernetes.io/buildkitd: unconfined` (annotation, not the `appArmorProfile` field) | Rootless buildkitd unshares user namespaces, which the default AppArmor profile denies. app-template rejects the `appArmorProfile` securityContext field, so the annotation is the only route.                                                            |
| `--oci-worker-no-process-sandbox`                                                                                    | Rootless without `privileged` requires skipping the process sandbox. The pod itself is the isolation boundary.                                                                                                                                            |
| `allowPrivilegeEscalation: true`, `capabilities.add: [SETUID, SETGID]`                                               | rootlesskit maps UIDs via `newuidmap`/`newgidmap`, which are setuid binaries. Set `allowPrivilegeEscalation: false` and the exec is denied outright; drop SETUID/SETGID from the bounding set and their file capabilities cannot be honoured.             |
| `readOnlyRootFilesystem: false`                                                                                      | buildkitd writes worker state and snapshots to the root filesystem.                                                                                                                                                                                       |
| liveness/readiness `buildctl --addr unix:///run/user/1000/buildkitd.sock debug workers`                              | `--addr` is repeatable, so buildkitd serves a unix socket alongside the TCP listener purely so the probe has an address it can reach. Pointing the probe at `tcp://localhost:1234` instead would need it to carry a client cert, since TLS applies there. |

---

## Workflow shape — what costs time

Measured on this runner, 2026-10-15 and 2026-10-27 (issue #2807 has the original harness):

| Cost                                   | Plain runner (k8s plugin) |
| -------------------------------------- | ------------------------- |
| Pod start-up per job                   | ~6-10s (image cached)     |
| Each extra step in a job               | ~4s                       |
| Each extra job (chained with `needs:`) | +12-15s                   |

- **Fewer jobs first, then fewer steps.** A job is a pod, so splitting work into jobs only pays when
  each part does more than ~15s of real work in parallel.
- **Bake tools into the job image; do not install them at run time.** `ci-toolbox` carries git, jq,
  yq, python3, curl, flux, cosign, docker and buildx. `apk add` costs ~5s a job and a GitHub download
  can fail.
- **Shared logic for small jobs lives in `ci-toolbox`** (`run: ci <command>`), testable locally with
  `podman run … ci <command> --dry-run`.
- **The vulnerability scan is one job for every app.** The grype database is a ~4-minute download;
  a matrix fetched it once per app.

Reference timings after the move: `oci-push` ~31s (Flux pinged at ~20s), labeler ~12s, a
containers PR ~1m with a cached lint, a single-app sandbox release ~1m15s.

---

## Multi-arch builds (linux/amd64 + linux/arm64)

Every app in `Exikle/containers` builds for both arches so its image runs on Artemis (amd64) and
Frostlink (arm64). **The build never emulates the target arch**, because it cannot here:

- The Talos kernel has no `binfmt_misc` at all (not a module, not built in), so QEMU user-mode
  emulation cannot be registered on any node. `buildkit` only offers `linux/amd64` and `linux/386`.
- `kata-qemu` pods fail with `Unsupported network interface: netkit` — Cilium runs the netkit
  datapath and Kata does not support it.

So each Dockerfile does everything on `$BUILDPLATFORM` and only _assembles_ the target arch:

- **Go**: cross-compile — `GOOS="${TARGETOS}" GOARCH="${TARGETARCH}"` with `CGO_ENABLED=0`, or
  `xx-go` when cgo is needed.
- **Static binaries from upstream images**: `COPY --from=<image@digest>` in the final stage resolves
  the target platform's variant without running anything (`ci-toolbox` takes flux, cosign, docker
  and buildx this way).
- **The runtime filesystem**: install the target arch's alpine packages into an empty root from an
  amd64 container, then `COPY` it into `FROM scratch`. `apps/ci-toolbox/Dockerfile` is the
  reference shape. Three things it handles that are not obvious:
    - an amd64 alpine image only trusts amd64 index signatures — install `alpine-keys` and copy
      `/usr/share/apk/keys/<arch>/*.pub` into the new root, or the index is rejected as UNTRUSTED;
    - `--no-scripts`, because package post-install scripts are target-arch binaries;
    - busybox's applet symlinks normally come from such a script, so they are recreated from
      `busybox --list-full` of the build-arch busybox (same applet list).
- **Never `RUN` a target-arch binary** in a Dockerfile. If an app ever needs that, it needs a native
  arm64 builder — Frostlink is the only arm64 machine — not emulation.

To add arm64 to an app: add `"linux/arm64"` to `image-all` in its `docker-bake.hcl` and convert
the final stage to the rootfs shape. Validate locally with
`podman build --platform linux/arm64 --ignorefile include/.dockerignore apps/<app>`; anything the
image needs at build time must sit under `scripts/`, `defaults/` or `entrypoint.sh`, because the
shared `.dockerignore` excludes the rest.

## Known ceiling: Multus

Runs are dominated by cluster-wide `FailedCreatePodSandBox` retries costing ~17–21s each — a single
unlucky pod can lose more time than every optimisation above saves. Two plausible fixes were tested
and disproved; the evidence and the surviving lead are in issue #1956. Read that before theorising
about it again.
