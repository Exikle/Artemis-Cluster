# Skill: apoci Federation

Manage ActivityPub federation between apoci registry instances.

## Background

Each apoci instance is an ActivityPub actor (`@registry@<domain>`). Federation is follow-based:

- When A follows B, B's artifact pushes are mirrored to A
- For full bidirectional sync, both instances must follow each other
- `autoAccept: mutual` (set on both Artemis and Frostlink) auto-accepts a follow-back if you already follow them

**Instances:**
| Instance | Registry URL | Actor |
|----------|-------------|-------|
| Artemis | `https://registry.dcunha.io` | `@registry@dcunha.io` |
| Frostlink | `https://registry.frostlink.dev` | `@registry@frostlink.dev` |

The `apoci` binary is present in each pod. Use `-c /apoci/config/apoci.yaml` — the config already has the endpoint and admin token path wired up.

## Federate Two Instances (bidirectional)

### Step 1 — Send follow from A to B

```bash
# Artemis follows Frostlink (use actor URL — domain-only webfinger may not resolve in-cluster)
kubectl -n fediverse exec deploy/apoci -c app -- \
  apoci follow add "https://registry.frostlink.dev/ap/actor" -c /apoci/config/apoci.yaml

# OR: Frostlink follows Artemis
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow add "https://registry.dcunha.io/ap/actor" -c /apoci/config/apoci.yaml
```

### Step 2 — Accept on the receiving side

```bash
# Check pending on Frostlink
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow pending -c /apoci/config/apoci.yaml

# Accept (use the actor/domain shown in pending output)
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow accept dcunha.io -c /apoci/config/apoci.yaml
```

With `autoAccept: mutual`, accepting the first follow automatically sends a follow-back to the requester, and the requester auto-accepts it (since they already follow). One `accept` call federates both directions.

### Step 3 — Verify

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

All follow commands support `--remote` + `--token` to target an instance from outside the pod:

```bash
ARTEMIS_TOKEN=$(kubectl -n fediverse get secret apoci -o jsonpath='{.data.APOCI_ADMIN_TOKEN}' | base64 -d)

apoci follow add "https://registry.frostlink.dev/ap/actor" \
  --remote https://registry.dcunha.io \
  --token "$ARTEMIS_TOKEN"
```

Or via env vars: `APOCI_REMOTE_URL` and `APOCI_ADMIN_TOKEN`.

## Troubleshooting

**webfinger 404 on bare domain** — Use the full actor URL (`https://registry.<domain>/ap/actor`) instead of the domain shorthand. The domain-only form does a webfinger lookup on the bare domain, which may not resolve in-cluster.

**Follow stuck in `pending`** — `autoAccept` is set to `mutual` not `all`; the peer must explicitly accept unless they already follow you. Run `apoci follow pending` on the receiving instance and `apoci follow accept <domain>`.

**Follow rejected** — Check `autoAccept` config on the remote. If set to `none`, manual acceptance is always required.

**Asymmetric state after data loss (one side shows follower, other doesn't)** — Do NOT use `follow remove` to fix this. `remove` (and `remove --force`) clears BOTH the outgoing follow AND the incoming follow on your side, triggering ActivityPub Unfollow to the remote — which in turn removes you from the remote's follower list. You end up in an endless remove/re-add loop. Instead, just re-run `follow add <actor>` on the side that's missing — if the remote no longer has the follow recorded, it will accept the new Follow activity and update its state.
