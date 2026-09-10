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
| `library/` (Tasks, Pipelines, StepActions) | reconciled by Flux from the OCI artifact         | only after a **successful** push builds a new artifact |

Commit both together and the new workflow runs against the old pipeline. The run fails, no artifact
is built, and the new pipeline never arrives — you are locked out of the path that ships the fix.

**`just kube apply-ks forgejo tekton-tasks` is what breaks the loop.** It writes the local library
to the cluster ahead of any commit. So the procedure is always:

1. `just kube render-ks forgejo tekton-tasks` — offline validation
2. `just kube apply-ks forgejo tekton-tasks` — library live, ahead of git
3. `workflow_dispatch` a run and read the result
4. commit → push → wait for the artifact → `just kube sync-flux ocirepo` → resume

**Keep each library change backward-compatible with the workflow already in git**, so there is never
a moment where cluster and repo disagree in a way that fails a run.

### When the change spans both halves

Some changes cannot be backward-compatible — binding `source` to an `emptyDir`, or adding a key to a
Secret the workflow builds. `workflow_dispatch` reads the workflow from the **ref**, so a dispatch
cannot test an uncommitted workflow. For those, apply the library first, then commit and push both
together and let the push-triggered run be the test. If it fails, the artifact simply is not built
and the previous one stays live; recover by fixing and re-applying with `apply-ks`.

> Do **not** test such a change by dispatching with the old workflow still in git. On 2026-09-03 that
> was started by mistake: the committed workflow still bound `source` to a ReadWriteOnce PVC while
> the applied pipeline had two tasks cloning independently, so both would have cloned into the same
> volume concurrently and could have pushed a partial tree and moved the `main` tag onto it. The run
> was cancelled before the push step; `clone` had already errored.

---

## Tekton sums step requests even though steps run sequentially

Tekton renders every step of a Task as its own **container**. Kubernetes sums all containers'
resource requests when scheduling a pod, so a Task with five steps reserves the sum of all five even
though Tekton runs them strictly one at a time.

**When merging single-step Tasks into one multi-step Task, do not carry each step's original
requests across.** Size them for a single step. Merging `push`/`tag`/`sign`/`verify` with their old
values summed to 1350m CPU and 1408Mi per pod and produced `ExceededNodeResources`; it then
recovered on its own once headroom appeared, which is the failure mode that looks like success.
Current values total 375m / 832Mi across five steps.

---

## Why the shape is what it is

**One pod per registry, not one per verb.** Pod allocation, not work, was the cost: a measured run
spent 109 of 124 seconds scheduling, networking and mounting pods to run 15 seconds of CLI. `push`,
`tag`, `sign` and `verify` are strictly sequential and share two images, so they are steps of
`flux-artifact-release`.

**Checkout is folded in, not shared.** With clone as its own task the `source` workspace had to
cross a pod boundary, which meant a PVC, which meant Tekton's affinity assistant pinned every pod of
the run onto whichever node the clone landed on. Cloning inside each release pod lets `source` be a
plain `emptyDir`: no per-run ReadWriteOnce claim, and the pods schedule independently. The cost is
one extra shallow clone per run.

**`notify` waits only on `release-registry`.** `flux-system`'s OCIRepository pulls
`oci://registry.dcunha.io/exikle/artemis-cluster` and only that. A tree-wide grep finds no other
reference to `git.dcunha.io/exikle/artemis-cluster` than the pipeline's own default param — the
Forgejo half is a mirror with no consumer. It still gates whether the PipelineRun succeeds; it just
does not gate reconciliation.

**Keep the mirror anyway.** `registry.dcunha.io` is apoci, in `fediverse/apoci` — inside this
cluster. Flux bootstraps the cluster from a registry the cluster hosts. The Forgejo copy on LXC 105
is the only artifact that survives the cluster being down.

**`coschedule: pipelineruns` was considered and rejected.** Its rationale was keeping images warm
across a run, but sandbox events show images were already cached and the delay is CNI. Pinning every
pod of a run to one node is precisely the behaviour dropping the PVC removed — and the one node in
this cluster sitting at 96% of its CPU requests is where that pinning sent them.

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

Port 1234 is guarded by **mTLS and** the NetworkPolicy in `buildkit/app/networkpolicy.yaml`. Keep
both; neither replaces the other.

- **mTLS** — `--tlscacert` is documented as _"ca certificate to verify clients"_, so passing it
  makes a client certificate **mandatory**, not optional. Both certs come from
  `internal-ca-issuer`, the CA the cluster already runs; the server cert's SAN is
  `buildkit.forgejo.svc.cluster.local`, so `buildkit-address` must stay that name or the handshake
  fails on hostname verification.
- **NetworkPolicy** — ingress to 1234 only from pods in `forgejo` carrying
  `app.kubernetes.io/managed-by: tekton-pipelines`, the label Tekton stamps on every TaskRun pod.

The label was never a credential: it is ordinary pod metadata, so anything that could create a pod
in `forgejo` could wear it and reach an unauthenticated build daemon, with write access to the
`${IMAGE}-build-cache` that release builds read back. That is what the client cert closes
(#1957 added the policy, #1998 added the certs).

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

## Known ceiling: Multus

Runs are dominated by cluster-wide `FailedCreatePodSandBox` retries costing ~17–21s each — a single
unlucky pod can lose more time than every optimisation above saves. Two plausible fixes were tested
and disproved; the evidence and the surviving lead are in issue #1956. Read that before theorising
about it again.
