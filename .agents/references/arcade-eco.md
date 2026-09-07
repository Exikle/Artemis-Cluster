# eco — Artemis-Cluster

The Eco game server in the `arcade` namespace. Everything here is a constraint the manifest
cannot state itself (`yaml-conventions.md` § No Comments in Manifests).

## The save format migrates one way, so `timeout` is 15m

Eco migrates its save in place on the first boot of a new version, and the migration is
**one-way**: an older binary refuses the upgraded save and crash-loops. That makes the
cluster-wide upgrade remediation (rollback) destructive here, so a slow world load must never be
mistaken for a failure. Flux's 5m default is shorter than a full load, so the HelmRelease sets
`timeout: 15m` to match the startup probe budget (90 × 10s).

**Remediation itself cannot be overridden in the HelmRelease.** The `flux-system` patch in
`kubernetes/flux/sync/cluster.yaml` wins over any `spec.upgrade` set on the release.

## It must run as root, and its root filesystem must be writable

The official image's `WorldGenerator` renders the terrain map through GDI+, which fails as uid
1000 even with a writable rootfs and `HOME` set — the same shape as the old flaresolverr
exception. Two consequences beyond the pod security context (`pod-security-exceptions.md`):

- `HOME: /tmp` is required because the image has no `passwd` entry for uid 1000, and
  fontconfig/GDI+ need a writable home.
- `readOnlyRootFilesystem: false` on the container, because that render writes inside `/app`.

## The gatus check is pointed at cluster DNS on purpose

`eco.dcunha.io` resolves to the Service LoadBalancer IP, which carries game traffic and has no
80/443 listener — an auto-discovered gatus check times out against it. The
`gatus.home-operations.com/endpoint` annotation therefore probes the in-process web server over
cluster DNS (`:3001`) instead.
