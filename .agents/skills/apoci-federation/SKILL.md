---
name: apoci-federation
description: Set up, repair, or tune an apoci OCI registry — ActivityPub federation between instances (cross-instance follow, artifact mirroring, webfinger, peer verification) and registry garbage collection and retention (keepLastN vs maxAge, pinnedGlobs, excludedRepos). Use for "federate apoci", "apoci ActivityPub follow", "apoci federation peer", "mirror apoci artifacts between instances", "apoci webfinger", "apoci retention", "apoci garbage collection", "registry GC", or "apoci registry disk full". Scoped to the Artemis cluster.
---

# Skill: apoci Federation

Manage ActivityPub federation between apoci registry instances.

## Background

Each apoci instance is an ActivityPub actor (`@registry@<domain>`). Federation is follow-based:

- When A follows B, B mirrors its artifact pushes to A.
- For full bidirectional sync, both instances must follow each other.
- `autoAccept: mutual` (set on both Artemis and Frostlink) auto-accepts a follow-back if you already follow them.

Instances:

| Instance  | Registry URL                     | Actor                     |
| --------- | -------------------------------- | ------------------------- |
| Artemis   | `https://registry.dcunha.io`     | `@registry@dcunha.io`     |
| Frostlink | `https://registry.frostlink.dev` | `@registry@frostlink.dev` |

The `apoci` binary is present in each pod. Use `-c /apoci/config/apoci.yaml`. The config already has the endpoint and admin token path wired up.

## Federate Two Instances (bidirectional)

### Step 1: Send the follow from A to B

```bash
# Artemis follows Frostlink (use actor URL — domain-only webfinger may not resolve in-cluster)
kubectl -n fediverse exec deploy/apoci -c app -- \
  apoci follow add "https://registry.frostlink.dev/ap/actor" -c /apoci/config/apoci.yaml

# OR: Frostlink follows Artemis
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow add "https://registry.dcunha.io/ap/actor" -c /apoci/config/apoci.yaml
```

### Step 2: Accept on the receiving side

```bash
# Check pending on Frostlink
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow pending -c /apoci/config/apoci.yaml

# Accept (use the actor/domain shown in pending output)
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow accept dcunha.io -c /apoci/config/apoci.yaml
```

With `autoAccept: mutual`, when you accept the first follow, apoci automatically sends a follow-back to the requester, and the requester auto-accepts it (since they already follow). One `accept` call federates both directions.

### Step 3: Verify

```bash
# Both should show the peer in their following list
kubectl -n fediverse exec deploy/apoci -c app -- \
  apoci follow list -c /apoci/config/apoci.yaml

kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow list -c /apoci/config/apoci.yaml

# Check outgoing request was accepted
kubectl -n fediverse exec deploy/apoci -c app -- \
  apoci follow outgoing -c /apoci/config/apoci.yaml
```

## Other Useful Commands

```bash
# View pending follow requests
apoci follow pending -c /apoci/config/apoci.yaml

# Reject a follow
apoci follow reject <domain> -c /apoci/config/apoci.yaml

# Unfollow a peer
apoci follow remove <domain> -c /apoci/config/apoci.yaml

# List known actors
apoci actor list -c /apoci/config/apoci.yaml

# Show this node's identity
apoci identity show -c /apoci/config/apoci.yaml
```

## Remote targeting (without exec)

All follow commands support `--remote` + `--token`, to target an instance from outside the pod:

```bash
ARTEMIS_TOKEN=$(kubectl -n fediverse get secret apoci -o jsonpath='{.data.APOCI_ADMIN_TOKEN}' | base64 -d)

apoci follow add "https://registry.frostlink.dev/ap/actor" \
  --remote https://registry.dcunha.io \
  --token "$ARTEMIS_TOKEN"
```

You can also use the env vars `APOCI_REMOTE_URL` and `APOCI_ADMIN_TOKEN`.

## Garbage Collection & Retention

`gc.retention` is in `app/resources/config.yaml`. Two facts about it are load-bearing.

`main` must stay in `pinnedGlobs`. The FluxInstance and the `flux-system`
OCIRepository both track `oci://registry.dcunha.io/exikle/artemis-cluster:main`.
That tag matches none of the other globs (`latest`, `v*`, `*.*.*`), so without an
explicit pin it is an ordinary retention candidate. If retention deletes it, the
whole cluster stops reconciling. Frostlink has the identical arrangement on
`registry.frostlink.dev/exikle/frostlink:main`.

`maxAge` overrides `keepLastN`. It is not a floor. The repo verified this live on both
clusters on 2026-08-05: with `keepLastN: 7, maxAge: 24h`, the surviving set is
_(newest 7)_ ∩ _(newer than 24h)_. Artemis had more than 7 tags under 24h and kept 7.
Frostlink had only 4 under 24h and kept 4. Do not assume that `keepLastN` protects
anything older than `maxAge`.

The `perRepo` rule targets `dcunha.io/exikle/artemis-cluster`, the local flux
artifact repo. Flux tags it once per commit and never reuses a tag, so it grows
without bound. Reclaimed disk is
negligible, because these are manifest artifacts, not image layers. This is tag hygiene.

`federation.excludedRepos` is outbound only. It stops this node from federating
matching repos out. It does not block the arrival of the blobs of a peer. `diskUsageThreshold`
only schedules an extra GC cycle. It does not widen what a cycle deletes.

The upstream config reference is `configs/apoci.example.yaml` in `eleboucher/apoci`.

## Troubleshooting

webfinger 404 on bare domain: use the full actor URL (`https://registry.<domain>/ap/actor`) instead of the domain shorthand. The domain-only form does a webfinger lookup on the bare domain, which does not always resolve in-cluster.

Do NOT add a `queryParams` filter to the webfinger HTTPRoute. A common homelab pattern uses `type: RegularExpression, value: ".*registry@.*"` to restrict the route. This passes manual `curl` tests because curl does not encode `@`, but Go's `net/http` (which apoci uses) percent-encodes it as `%40`. The regex never matches encoded requests, and that causes a 404 for all apoci-to-apoci federation. Match only the path. apoci handles unknown resources with its own 404.

Follow stuck in `pending`: `autoAccept` is set to `mutual`, not `all`. The peer must accept explicitly unless they already follow you. Run `apoci follow pending` on the receiving instance and `apoci follow accept <domain>`.

Follow rejected: check the `autoAccept` config on the remote. If it is `none`, the remote always requires manual acceptance.

Asymmetric state after data loss (one side shows a follower, the other does not): do NOT use `follow remove` to fix this. `remove` (and `remove --force`) clears BOTH the outgoing follow AND the incoming follow on your side. It then sends an ActivityPub Unfollow to the remote, which removes you from the follower list of the remote. You end up in an endless remove/re-add loop. Instead, run `follow add <actor>` again on the side that is missing the follow. If the remote no longer has the follow recorded, it accepts the new Follow activity and updates its state.
