# Tekton CI — Artemis-Cluster

The `oci-push` pipeline that builds this repo's Flux artifact, and the constraints that shape it.
Manifests under `kubernetes/` carry no comments (`yaml-conventions.md` § No Comments in Manifests),
so the rationale lives here.

Catalog of what runs where is the tree: `kubernetes/apps/forgejo/tekton-runner/library/`
(`steps/` StepActions, `tasks/` Tasks, `pipelines/` Pipelines).

---

## The two clocks — this dictates the order of every CI change

A CI change has two halves that become live at different moments:

| Half                                       | Source of truth                                  | Becomes live                                           |
| ------------------------------------------ | ------------------------------------------------ | ------------------------------------------------------ |
| `.forgejo/workflows/*.yaml`                | read from git by the runner at the pushed commit | the **next push**, immediately                         |
| the shared workflow they call              | `Exikle/forgejo-workflows`, at the caller's pin  | when this repo's pin moves to the new commit           |
| `library/` (Tasks, Pipelines, StepActions) | reconciled by Flux from the OCI artifact         | only after a **successful** push builds a new artifact |

Commit both together and the new workflow runs against the old pipeline. The run fails, no artifact
is built, and the new pipeline never arrives — you are locked out of the path that ships the fix.

**`just kube apply-ks forgejo tekton-tasks` is what breaks the loop.** It writes the local library
to the cluster ahead of any commit. So the procedure is always:

1. `just kube render-ks forgejo tekton-tasks` — offline validation
2. Suspend the root and `forgejo/tekton-tasks`, then `just kube apply-ks forgejo tekton-tasks` —
   library live, ahead of git
3. `workflow_dispatch` a run and read the result
4. commit → push → wait for the artifact → resume, as in `.agents/instructions/commit-style.md`
   § The sequence (which names `flux-system` in the `sync-flux` call)

**Keep each library change backward-compatible with the workflow already in git**, so there is never
a moment where cluster and repo disagree in a way that fails a run.

### `container-validate` escapes the two clocks — nothing else does

Since 2026-09-17 the **validation** path resolves its Pipeline _and_ its Task straight from git with
the Tekton git resolver, so for that path only there is no cluster half and no `apply-ks` step: point
`pipelineRef.revision` at a branch and the run uses it.

Three things to know before relying on it:

- **The Pipeline and its Tasks are pinned separately and Tekton cannot derive one from the other.**
  `container-validate` takes a `library-revision` param (default `main`) for the taskRef, and the
  `containers` workflow passes it beside `pipelineRef.revision`. **Change both together** — override
  only the pipeline revision and you silently branch-test a new Pipeline against the `main` Task.
- **A change to the Pipeline cannot be tested by pushing to `main`**, because `main` is what it is
  fetched from. Use a branch.
- **Release paths deliberately do not use it.** `oci-push` and `container-build` still resolve by
  name from the cluster, because the runner's own `policies/README.md` recommends blocking resolver
  refs: they let a PipelineRun fetch and execute an arbitrary remote Pipeline. Validation is the
  small blast radius; shipping is not.

### When the change spans both halves

Some changes cannot be backward-compatible — binding `source` to an `emptyDir`, or adding a key to a
Secret the workflow builds. `workflow_dispatch` reads the workflow from the **ref**, so a dispatch
cannot test an uncommitted workflow. For those, apply the library first, then commit and push both
together and let the push-triggered run be the test. If it fails, the artifact simply is not built
and the previous one stays live; recover by fixing and re-applying with `apply-ks`.

> Do **not** test such a change by dispatching with the old workflow still in git. If the committed
> workflow binds `source` to a ReadWriteOnce PVC while the applied pipeline has two tasks cloning
> independently, both clone into the same volume concurrently and could push a partial tree and move
> the `main` tag onto it.

---

## Tekton sums step requests even though steps run sequentially

Tekton renders every step of a Task as its own **container**. Kubernetes sums all containers'
resource requests when scheduling a pod, so a Task with five steps reserves the sum of all five even
though Tekton runs them strictly one at a time.

**When merging single-step Tasks into one multi-step Task, do not carry each step's original
requests across.** Size them for a single step. Summed old values produced `ExceededNodeResources`
that then recovered on its own once headroom appeared, which is the failure mode that looks like
success.

---

## Why the shape is what it is

**One pod per registry, not one per verb.** Pod allocation, not work, was the cost: nearly all of a
run went on scheduling, networking and mounting pods to run seconds of CLI. `push`,
`tag`, `sign` and `verify` are strictly sequential and share two images, so they are steps of
`flux-artifact-release`.

**Checkout is folded in, not shared.** With clone as its own task the `source` workspace had to
cross a pod boundary, which meant a PVC, which meant Tekton's affinity assistant pinned every pod of
the run onto whichever node the clone landed on. Cloning inside each release pod lets `source` be a
plain `emptyDir`: no per-run ReadWriteOnce claim, and the pods schedule independently. The cost is
one extra shallow clone per run.

**`notify` is a step of `release-registry`, not a Task.** `flux-system`'s OCIRepository
pulls `oci://registry.dcunha.io/exikle/artemis-cluster` and only that, so only that release needs to
ping Flux — the Forgejo half is a mirror with no consumer. It is the last step of
`flux-artifact-release`, gated by that Task's `notify` param (default `"false"`; the pipeline sets
`"true"` on `release-registry` only).

Tekton `Step`s have no `when:`, so the gate lives **inside** the StepAction as an `enabled` param
that exits 0 early. That is why `flux-notify` the StepAction survives and `flux-notify` the Task was
deleted.

**Keep the mirror anyway.** `registry.dcunha.io` is apoci, in `fediverse/apoci` — inside this
cluster. Flux bootstraps the cluster from a registry the cluster hosts. The Forgejo copy on LXC 105
is the only artifact that survives the cluster being down.

**Every step declares only the workspaces it needs** (isolated workspaces, beta; requires
`enable-api-fields: beta`, already set). The cosign private key must not be readable by the `clone`
step — Flux rejects artifacts it cannot verify, so that key is cluster-wide code execution. `clone` sees `source`+`basic-auth`,
`push` sees `source`+`auth`, `tag` sees `auth`, `sign`/`verify` see `cosign`+`docker-config`, and
`notify` sees none. Verify a change to this at the pod level, not the manifest: the workspace volumes
render as `ws-<hash>` and you can read which container mounts which.

**Container builds are folded the same way.** `container-image-build` holds
clone+options+build as steps, so `container-build` is 5 Tasks and `container-validate` is 1, and both
dropped their 2Gi ReadWriteOnce `source` PVC for an `emptyDir` in the `containers` repo's workflows.
Same reasoning as the release path: the PVC was only there because `source` crossed a pod boundary.

**`coschedule: pipelineruns` was considered and rejected.** Images were already cached and the delay
is CNI. Pinning every pod of a run to one node is precisely the behaviour dropping the PVC removed.

---

## Signing is load-bearing

`flux-system`'s OCIRepository sets `verify.provider: cosign` with `secretRef: cosign-public-key`.
Flux **rejects an artifact it cannot verify**, so a broken signing key stops reconciliation
cluster-wide.

Two consequences:

- Any manual recovery push must be signed:
  `flux push artifact` → `flux tag artifact --tag main` → `cosign sign --key …`. The key is the
  `cosign` item in the `artemis` 1Password vault.
- The pipeline's own `verify` step is redundant _for trust_ — Flux does the real check at
  consumption. It is kept because it now costs about a second inside an existing pod and fails
  loudly in CI rather than quietly at reconcile time.

`cosign.pub` ships in the `cosign-creds` workspace rather than being derived from the private key at
runtime. It is a public key, so carrying it in the workflow makes the value signatures are checked
against auditable in git. The standalone `cosign-verify` Task still derives it, deliberately: it is
called by `container-build` from the `containers` repository, whose `cosign-creds` Secret is built by
a workflow this repo does not own.

---

## The tekton-runner values that look wrong but are not

- **`RUNNER_CAPACITY: "6"`.** The binary defaults to 2, which serialized the `containers` CI: its
  lint job waited for a free slot while prepare and go-check held both. Six covers a full pull
  request fan-out plus the build matrix.
- **`RUNNER_DEFAULT_WORKSPACE_SIZE_LIMIT: 1Gi`.** The binary defaults to 5Gi. Script groups here
  write nothing to the source workspace, so the default is a needless ephemeral-storage claim.
- **`RUNNER_REDIS_URL` pointing at Dragonfly, index 4.** Redis-backed failover: the standby adopts
  in-flight Tekton runs instead of losing them. Dragonfly is a supported standalone endpoint;
  Sentinel and Cluster are not. Index allocation is registered in `postgres-dragonfly.md`.
  `RUNNER_NAME`, `RUNNER_REDIS_KEY_PREFIX` and `RUNNER_REDIS_ENCRYPTION_KEY_FILE` all come from the
  chart, templated to the release name — do not set them.

---

## buildkit — the remote builder, and why its security context is loose

`kubernetes/apps/forgejo/buildkit` is the remote builder for `Exikle/containers`
(`container-build` / `container-validate`, via `docker buildx --driver remote`). Nothing in
`oci-push` touches it.

### Two boundaries, not one

Port 1234 is guarded by **mTLS and** the NetworkPolicy inline in
`buildkit/app/helmrelease.yaml` (`networkpolicies:`). Keep both; neither replaces the other.

- **mTLS** — `--tlscacert` is documented as _"ca certificate to verify clients"_, so passing it
  makes a client certificate **mandatory**, not optional. Both certs come from
  `internal-ca-issuer`, the CA the cluster already runs; the server cert's SAN is
  `buildkit.forgejo.svc.cluster.local`, so `buildkit-address` must stay that name or the handshake
  fails on hostname verification.
- **NetworkPolicy** — ingress to 1234 only from pods in `forgejo` carrying
  `app.kubernetes.io/managed-by: tekton-pipelines`, the label Tekton stamps on every TaskRun pod.

The label was never a credential: it is ordinary pod metadata, so anything that could create a pod
in `forgejo` could wear it and reach an unauthenticated build daemon, with write access to the
`${IMAGE}-build-cache` that release builds read back. That is what the client cert closes.

**The two certs share `internal-ca-issuer` with the rest of the cluster.** `usages` keeps them
apart — the server cert is `server auth` only and the client cert `client auth` only, so neither
can play the other's role. The residual is that any _other_ cert minted from that CA with a
clientAuth EKU would also authenticate here. Minting one needs `Certificate` create RBAC, which is
a far higher bar than creating a pod in `forgejo`, so this was accepted rather than standing up a
dedicated CA pair the way `postgres-ca` does. Revisit if buildkit ever faces something less trusted.

> Not closed by any of this: `forgejo-runner`'s Role carries `pods/exec: create` on **every** pod in
> `forgejo`, `buildkit-0` included. An exec bypasses the NetworkPolicy and the TLS listener alike.

### Wiring the client cert through Tekton — two webhook rules that are not in the CRD schema

The client cert reaches the build step as a **Task volume**, deliberately not a workspace: the
workspace list is bound by the release workflow in the separate `Exikle/containers` repo, so a new
workspace would be a cross-repo change subject to the two-clock problem above. A Task volume is
entirely library-side and the workflow never changes.

Getting it there hits two validations the `tasks.tekton.dev` OpenAPI schema does **not** express —
both only show up as an admission rejection at apply time:

| Attempt                                              | Rejection                                                                          |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `volumeMounts` on a Task step that uses `ref:`       | `volumeMounts cannot be used with Ref: spec.steps[0].volumeMounts`                 |
| `volumeMounts.name` a literal string in a StepAction | `invalid value: buildkit-certs` … `expect the Name to be a single param reference` |

So the working shape is: the **StepAction** declares the `volumeMounts` with
`name: $(params.certs-volume)`, and the **Task** declares `spec.volumes` and passes the volume's
name in as that param. The mount path stays a literal in the StepAction — only `name` must be a
param reference.

Its pod spec breaks several house rules deliberately. None of these are safe to "tidy":

| Setting                                                                                                              | Why                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `container.apparmor.security.beta.kubernetes.io/buildkitd: unconfined` (annotation, not the `appArmorProfile` field) | Rootless buildkitd unshares user namespaces, which the default AppArmor profile denies. app-template rejects the `appArmorProfile` securityContext field, so the annotation is the only route.                                                            |
| `--oci-worker-no-process-sandbox`                                                                                    | Rootless without `privileged` requires skipping the process sandbox. The pod itself is the isolation boundary.                                                                                                                                            |
| `allowPrivilegeEscalation: true`, `capabilities.add: [SETUID, SETGID]`                                               | rootlesskit maps UIDs via `newuidmap`/`newgidmap`, which are setuid binaries. Set `allowPrivilegeEscalation: false` and the exec is denied outright; drop SETUID/SETGID from the bounding set and their file capabilities cannot be honoured.             |
| `readOnlyRootFilesystem: false`                                                                                      | buildkitd writes worker state and snapshots to the root filesystem.                                                                                                                                                                                       |
| liveness/readiness `buildctl --addr unix:///run/user/1000/buildkitd.sock debug workers`                              | `--addr` is repeatable, so buildkitd serves a unix socket alongside the TCP listener purely so the probe has an address it can reach. Pointing the probe at `tcp://localhost:1234` instead would need it to carry a client cert, since TLS applies there. |

---

## The container-build path — `bake-options` and `buildx-bake`

Constraints baked into those two StepActions, none of which are obvious from reading the scripts.

**Params arrive as env, never interpolated into the script.** `$(params.x)` splices the raw value
into the middle of a shell statement, so a multi-line or multi-word value (`images` is multi-line)
breaks the script. Both StepActions take params through `env:` and read `$X`.

**`bake-options` reads the app version straight out of the HCL** rather than asking buildx.
`buildx bake --print` would need a builder connection, and resolving a version must not depend on
buildkitd being reachable. The version ladder is the same as the app-versions action: an optional
`v`, then one to three numeric components; anything trailing is dropped from the semantic form.

**`buildx-bake` copies auth somewhere writable.** buildx writes builder state into
`$DOCKER_CONFIG`, but the workspace is a read-only Secret mount. Shared files (`.dockerignore`)
are copied in without clobbering an app's own copy, matching how the repo stages a build context.

**The remote driver is always given a client cert.** buildkitd's `--tlscacert` makes mTLS
mandatory. The server cert's SAN is the in-cluster Service name, so `BUILDKIT_ADDRESS` must stay
that name — see § Wiring the client cert through Tekton.

**A validation build publishes nothing at all** — no image, and no cache export either — so a pull
request cannot write to either registry or poison the cache the release path reads back. Nothing
was pushed means there is no digest, but the result still has to be written or Tekton fails the
TaskRun for an unset result.

**Tags go in through a bake override file, not `--set`.** `--set` takes a single reference, so a
comma-joined list is read as one invalid tag. The HCL already declares an empty
`docker-metadata-action` target for `image` to inherit — the same mechanism the Actions path used.

**Bake the `image-all` target, never `image`.** `image-all` carries the platform list; `image`
alone silently builds only the builder's native platform whatever the bake file declares. Because
one bake invocation builds every platform, the push already yields a single index and there is
nothing to merge afterwards.

## Workflow shape — what actually costs time (measured 2026-10-15)

Measured with timing marks posted from inside jobs on both runners (`tekton` → Tekton runner;
`ubuntu-latest`/`docker` → forgejo-runner with the k8s plugin), five runs per case unless noted.
Numbers, the harness and the follow-ups are in issue #2807.

| Cost                                   | Plain runner (k8s plugin) | Tekton runner |
| -------------------------------------- | ------------------------- | ------------- |
| Pod start-up per job                   | ~10s                      | ~11-13s       |
| Each extra step in a job               | ~4s                       | ~1s           |
| Each extra job (chained with `needs:`) | +12-15s                   | +12-15s       |

**Fewer jobs first, then fewer steps.** A job is a pod, so splitting work into jobs only pays when
each part does more than ~15s of real work in parallel. On the plain runner every step is several
API-server `exec` calls (copy the script in, run it, read outputs back), so fold related commands
into one step. Tekton steps are containers in one pod and cost almost nothing.

**Bake tools into the job image; do not install or download them at run time.** Installing git and
python with `apk` costs ~5s per job. Downloading flux, kubectl and yq from GitHub cost ~8s and
failed in 1 of 5 runs. A slim purpose image (68-83MB) started ~4s faster on Tekton than the
bjw-s runner image.

**`actions/cache` does not pay for small dependency sets.** A pip install of ansible-core took 45s
uncached and 50s cached: restoring, saving and the two extra steps cost more than the download.

**Shared logic lives in the `ci-toolbox` image, not in workflow YAML.** A job is one step,
`run: ci <command>`. That works on both runners (Tekton cannot resolve `uses:`), can be tested
locally with `podman run … ci <command> --dry-run`, and is versioned by Renovate. Labeler and
labels-sync together in one toolbox step took 16s on the plain runner and 19s on Tekton, against
22s for the old labeler alone.

### Runner settings that matter under load

- **forgejo-runner `capacity`** was 4. With 10 jobs queued at once, jobs waited a median 26s before
  their pod existed. At 10 the wait is 1-2s.
- **Tekton pod spreading** (`TektonConfig` `pipeline.default-pod-template`, topologySpread on
  hostname). Without it the scheduler stacked TaskRun pods on `talos-w-01` — image locality wins
  over its being the busiest worker — and start-up at 10 concurrent runs was 24s. With it, 10s.
  TaskRun pods now also land on the control planes, which are schedulable here; they are light,
  since image builds run on `buildkit`.
- **`running-in-environment-with-injected-sidecars: false`.** Nothing injects sidecars into TaskRun
  pods (k8tz adds an init container, not a sidecar), so Tekton need not wait for sidecar readiness.
  Single-run start-up 13s → 11s.

Tested and not worth it:

- **Tekton controller `performance`** (threads 8, qps 50, burst 100) — no change across 20 runs at 10
  concurrent. The controller is not the bottleneck at this scale.
- **Preferring non-control-plane nodes** in the pod template — the node-affinity score outweighs the
  soft spread, pods packed onto `talos-w-01` again, and total time went back up to 30s.
- **Spreading alone without the sidecar flag** made single runs slower (23s vs 20s): pods land on
  nodes that have not pulled the image yet. Keep both settings together.

## Known ceiling: Multus

Runs are dominated by cluster-wide `FailedCreatePodSandBox` retries costing ~17–21s each — a single
unlucky pod can lose more time than every optimisation above saves. Two plausible fixes were tested
and disproved; the evidence and the surviving lead are in issue #1956. Read that before theorising
about it again.
