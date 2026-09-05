# Reference: Rook-Ceph — Artemis-Cluster

Everything Ceph-specific on this cluster: OSD topology rules, Ceph version selection, CephX, the
mgr-module settings that must not be removed, resolved incidents worth keeping, and RBD CSI
recovery. It does **not** cover the StorageClass surface apps actually consume (`storage.md`
§ Storage Classes), backups (`kopiur.md`), or the Proxmox host's ZFS pools (`pantheon-zfs.md`).
The 2026-08-21 capacity and drive-replacement analysis behind the topology rules below lives in
`osd-topology-2026-08-21.md`.

## Rook-Ceph

- 3 OSDs total on M710q control plane nodes — do not add without explicit direction
- `useAllNodes: false` — never change to `useAllNodes: true`
- `pg_autoscaler` hard limit: `mon_max_pg_per_osd=250` — cannot be exceeded by adding pools
- Storage classes are documented in `storage.md` § Storage Classes — `ceph-block` is the only one
  that exists, and there is no `ceph-filesystem`

### OSD topology — the live rules

Failure domain is `host` and both CRUSH rules are `chooseleaf_firstn 0 type host`. With three
hosts and `size=3` there is exactly one legal mapping for every PG, so **one OSD down puts all 65
PGs `undersized+degraded` with nowhere to recover**, and an OSD rebuild runs its whole ~78 GiB
backfill at two copies. That is why maintenance at full redundancy is impossible today and why the
rules below are rules rather than preferences. Full measurements, options and costs:
`osd-topology-2026-08-21.md`.

- **Never put OSDs on more than one `pantheon` VM while `failureDomain: host`.** `talos-w-01`,
  `talos-w-02` and `talos-gpu-01` are all VMs on `pantheon` off the same `vmpool`; CRUSH sees three
  independent hosts and will place 2 of 3 copies on two of them. One is fine. Two is a hidden
  correlated pair that defeats `size=3` — add a `chassis` CRUSH bucket first if a second is ever
  wanted.
- **The cluster has at most 5 independent failure domains** — `talos-cp-01/02/03`, `ymir`, and
  `pantheon` counted once. There is no 6th.
- **The redundancy win lands at the 4th host, not the 5th.** At 4 hosts you can `ceph osd out` a
  drive, let CRUSH re-replicate to full 3 copies, and only then pull it. The 5th host buys only
  the two-hosts-down case (~30% of PGs below `min_size` instead of 100%).
- **`ymir` is the only genuinely independent 4th host**, and it needs RAM first — 87% of
  allocatable is already requested, so a 2 Gi OSD pod sits `Pending`. Hard blocker.
- **`pg_num` stays 64 at 3, 4 and 5 OSDs.** The autoscaler's ideal holds at ~32 because adding OSDs
  raises `num_osds` and lowers `ratio` by the same factor, and it only acts on a ≥3× divergence.
  At 7 OSDs, 195/7 = 27.9 crosses under `mon_pg_warn_min_per_osd` and `pg_num` would have to go
  to 128.
- **The `devicePathFilter` is model-locked and anchored.** It is now
  `^/dev/disk/(by-id/nvme-SAMSUNG_MZVLW256HEHP-000L7_[^-]+|by-partlabel/r-rook)$`, matching either
  a whole disk (unconverted node) or the `r-rook` partition (converted for miroir, issue #1981).
  The `[^-]+$` anchor is what stops it matching `...-part1`, i.e. miroir's partition. A
  differently-modelled drive is not picked up. Prefer per-node `devices:` entries over the global
  filter, which also removes the risk of matching a boot device on a new node.
- **A Ceph-backing partition must never have `ceph` in its label.** ceph-volume's
  `is_ceph_disk_member` tests `'ceph' in PARTLABEL`, so such a partition is rejected as a legacy
  ceph-disk member and `rook-ceph-osd-prepare` logs `skipping device ...: ["Used by ceph-disk"]`
  on a brand-new empty partition. This is why the partition is `r-rook`, not `r-ceph`.
- **Replace the Eaton UPS batteries before buying any SSD.** No OSD has power-loss protection, so
  one mains outage is a simultaneous unclean power-off of every copy of every object plus all three
  mons. Replication does not help with a correlated event.
- The three PM961s are **healthy** — 12–13% wear, zero media errors, all slow counters zero over
  18.6 h of real load. There is no health-driven case for replacing them; swaps are opportunistic
  and run through the `osd-rebuild` skill.

### Ceph version selection — no `cephImage` pin (2026-08-20)

**The `rook-ceph-cluster` chart's default `cephImage.tag` selects the Ceph version. Do not
re-add a repo-side pin.** This reverses the earlier "always pin `cephImage.tag`" convention.

Rook moves its chart default in lockstep with the CephX defaults each release needs, so the
chart is internally consistent and pinning desynchronizes it:

| chart   | default `cephImage.tag` | `security.cephx.csi.keyType` | `mgr.modules[rook]`  |
| ------- | ----------------------- | ---------------------------- | -------------------- |
| v1.20.4 | v20.2.2                 | _(absent)_                   | commented out        |
| v1.20.5 | **v20.2.4**             | `aes`                        | commented out        |
| v1.20.6 | **v20.2.4**             | `aes`                        | **`enabled: false`** |

Our pin is what left the cluster on v20.2.3 after the v1.20.5 chart landed — i.e. it held us
on a CVE-vulnerable Ceph rather than protecting us from anything. Removing it also retired the
`quay.io/ceph/ceph` `allowedVersions` guard in `.renovaterc.json5`: rook will never default to
a Ceph its own operator refuses, which is what that regex approximated.

The trade is that the chart version now moves Ceph, and a chart _patch_ is enough to cross a
security boundary (v1.20.4 ➔ v1.20.5 moved v20.2.2 ➔ v20.2.4). The `rook-ceph` Renovate group
is therefore `automerge: false`. **Re-pin only as a temporary hold** if a specific Ceph release
must be avoided, and remove the pin again once it is.

### CephX AES256K / CVE-2025-30156 (resolved 2026-08-20)

Ceph v20.2.4 (and v19.2.6) introduce the `aes256k` CephX key type. The old AES service tickets
have no effective integrity check, so an attacker holding any CephX key could bit-flip their way
to cluster admin in linear time. Resolution needs rook ≥ v1.20.6 **and** Ceph ≥ v20.2.4 **and** a
daemon key rotation — the version bump alone does nothing.

Applied here as `spec.security.cephx` in the cluster HelmRelease:

- `daemon.keyRotationPolicy: KeyGeneration` + `keyGeneration: 2` — one-shot rotation of mon, mgr,
  osd, mds, admin, exporter and crash keys to `aes256k`. Bump `keyGeneration` again to re-rotate.
- `csi.keyType: aes` — **load-bearing.** AES256K CSI keys require **Linux kernel 7.0+** and every
  node runs 6.18. Rook autodetects key type otherwise, and an autodetected `aes256k` CSI key makes
  new PVC kernel mounts fail. `rbdMirrorPeer` stays `aes` for the same reason.

End state (`ceph auth dump-keys --format=json`): 11 keys `aes256k`, 5 `aes` (4× `client.csi-*`
plus `client.rbd-mirror-peer`). That split is correct and is not a partial migration.

`healthCheck.muteHealthWarning` mutes the four `AUTH_INSECURE_*` **warnings**, which persist by
design while non-core clients stay on AES. The two `AUTH_INSECURE_SERVICE_*` **errors** are not
muted and must be resolved by rotation, not suppressed.

The rolling upgrade takes ~15 min for 3 OSDs and does two passes — version first, then rotation.
PVCs stay mounted throughout. Restart `rook-ceph-tools` afterwards for its admin keyring; a
transient `[errno 13] RADOS permission denied` right at toolbox start is expected and clears.

**This is complete, not half-done.** `ceph config get mon auth_service_cipher` returns `aes256k`,
which is the setting that actually closes the CVE — every service ticket is now AES256K, so no
CephX key can be escalated, including the CSI keys still on `aes`. Rook's guidance is explicit
that older kernels keep using AES authentication keys safely once Ceph issues AES256K service
tickets. The remaining work below is optional hardening that clears two muted cosmetic warnings.

**Kernel 7.0 is not coming soon — do not plan around it.** Talos tracks the _LTS_ kernel and
6.18 is the current longterm (Talos `main`, `release-1.14` and `release-1.13` are all on 6.18.4x
as of 2026-08-20). Linux 7.0/7.1/7.2 exist only as mainline/stable. The Ceph client's aes256k
support arrived via the `ceph-for-7.0-rc1` merge — a feature merge, not a stable backport — so
6.18 LTS will never gain it. Unblocking needs the next LTS designation (conventionally the last
release of a calendar year) plus Talos adopting it.

**Parked — do not attempt without a kernel 7.0+ fleet:** migrating CSI keys to `aes256k` (needs
`keepPriorKeyCountMax: 1` and a cordon/drain/reboot pass per node), and `security.cephx.allowedCiphers:
[aes256k]`. The latter can lock rook out of the cluster entirely with the same `[errno 13] RADOS
permission denied`, requiring an emergency `daemon.keyType: aes` + both-ciphers patch to recover.

### `cephConfig.mgr.log_max_recent: "100"` — do not remove while on Ceph 20.2.x

Ceph 20.2.2 ([ceph#67515](https://github.com/ceph/ceph/pull/67515)) made the `rook` mgr module log
the full body of every `list_namespaced_pod` response at debug level. The `prometheus` module calls
`orch_is_available()` every 15s, which lists every pod in `rook-ceph` — on this cluster that is
~810 KB of JSON per call, ~9 calls per 5 min.

Those entries are retained in the in-memory `EntryRing` sized by `log_max_recent`. The documented
default of 500 is the _client_ default; daemons default to **10000**, so nothing is ever evicted and
the active mgr grows ~90 MB/hr until it OOMs against its 2Gi limit (observed: ~daily restarts).

Capping the ring at 100 bounds retention to ~80 MB.

**Correction (2026-08-09):** the upstream fix ([ceph#69609](https://github.com/ceph/ceph/pull/69609))
_was_ backported to tentacle as [ceph#69927](https://github.com/ceph/ceph/pull/69927), merged
2026-07-21, and its merge commit is an ancestor of the `v20.2.3` tag — so the cluster already carries
it. An earlier revision of this note said it had not been backported; that was wrong. The setting is
now redundant but harmless, and is kept as belt-and-braces (it also bounds any future log-volume
regression). `melotic/home-ops` keeps it on v20.2.3 for the same reason.

Refs: [rook#17786](https://github.com/rook/rook/issues/17786),
[tracker#77538](https://tracker.ceph.com/issues/77538), [tracker#78165](https://tracker.ceph.com/issues/78165)

The same issue also reports a thread leak in the `rook` module
([ceph#70071](https://github.com/ceph/ceph/pull/70071), still open against `main`). **It is not
active here** — measured 2026-08-09, the active mgr's thread count was flat at 168 across 12.5
minutes, and tchaikov's signature for that bug is a monotonically _growing_ `/proc/<pid>/task`
count. The 169-vs-81 reading from 2026-08-04 was steady-state, not drift.

### RESOLVED 2026-08-05: `rook-ceph-cluster` ks back to `wait: true`

cp-01 was uncordoned, `mon-a` and `osd-1` scheduled, and Ceph returned to 3/3 mons and 3/3 OSDs.
`wait: true` was restored and the stalled HelmRelease cleared with
`flux reconcile helmrelease rook-ceph-cluster -n rook-ceph --reset` — it had been Failed for 74
days on `MissingRollbackTarget` (last `deployed` release was v108, everything after it `failed`,
so Flux had no rollback target). It upgraded cleanly to v142 once the cluster was healthy.
`ceph crash archive-all` was run against a `HEALTH_WARN` for two mgr crashes — **that was a
misread and archiving is not a fix**, see the next section.

Kept for the next time a control-plane node is down:

- With cp-01 cordoned, `mon-a`/`osd-1` sit `Pending`, so the operator can never satisfy
  `ceph mon ok-to-stop` when rolling a mon. It loops on `deployment rook-ceph-mon-b cannot be
stopped ... Error EBUSY: not enough monitors would be available` every 60s and `CephCluster`
  stays `phase: Progressing` indefinitely. Under `wait: true` that pins the Kustomization at
  `Ready=False` and dependency-blocks **29** downstream Kustomizations.
- Ceph serves normally throughout (pools active, client I/O flowing) — the gate is wrong, not the
  storage. Dropping to `wait: false` is the correct temporary unblock.
- Do **not** reach for `continueUpgradeAfterChecksEvenIfNotHealthy: true`: it would let the
  operator restart `mon-b` while `mon-a` is down, dropping quorum to a single mon and taking the
  cluster offline. The operator's refusal loop is correct — leave it looping.

### RESOLVED 2026-08-09: `rook` mgr module crash loop — `node_proxy_fullreport`

**Caller identified: the `prometheus` mgr module, not the dashboard.** Ceph **v20.2.3** added
hardware metrics to `src/pybind/mgr/prometheus/module.py`; `collect()` calls `get_hardware_metrics()`
unconditionally on every scrape, which calls `node_proxy_fullreport()`. Rook's orchestrator backend
does not implement it (rook has _no_ `node_proxy` code, `master` included), so every 15s scrape threw
`NotImplementedError` from `orchestrator/_interface.py:369`. There is no config option to disable it —
the only guard is `orch_is_available()`.

**Fix: `cephClusterSpec.mgr.modules` → `- name: rook, enabled: false`.** That makes
`orch_is_available()` false so `get_hardware_metrics()` returns early. Verified in rook v1.20.3
source that the toggle sticks: `configureMgrModules` calls `MgrDisableModule` on the `else` branch,
and the force-enabling `configureOrchestratorModules` only runs under `if module.Enabled`.

This **reverses the earlier decision** recorded above ("we do not disable the rook module — it drops
the orchestrator integration the dashboard relies on"). Two things changed that calculus:

- The cost was measured, not assumed. There are **no CephNFS CRs** and no `CephNFS` references in
  `kubernetes/`; all pool/OSD management is CRD-driven. The actual loss is the `ceph orch` CLI and the
  dashboard's host/device/inventory pages. Pools, RBD, CephFS, metrics, alerts and CSI are unaffected.
- It was **not cosmetic**. Each `NotImplementedError` was recorded as a module crash; 4151 of them
  overflowed the `crash` module, which then died on its own `dictionary changed size during iteration`
  bug, putting the cluster in `HEALTH_ERR`. The crash store was also the "mgr memory leak" — the active
  mgr fell from **1702 MiB to 241 MiB** once cleared. Storage I/O was fine throughout, so the earlier
  "cosmetic" read was right about the data path and wrong about the mgr.

**Superseded 2026-08-20 — keep `enabled: false` permanently; do not revert.** Rook made this the
chart default in v1.20.6 ("mgr: Disable the rook mgr module", rook#18213), with the values comment
"The rook mgr module is not recommended. The only impact is that some small features will be
disabled in the Ceph dashboard." So this is upstream policy now, not a local workaround.
[ceph#70280](https://github.com/ceph/ceph/pull/70280) is still open regardless (checked 2026-08-20).

Note `mgr.modules` is a **list**, and Helm replaces lists rather than merging them — our explicit
`- name: rook / enabled: false` entry must stay in the values even though it matches the default,
or the rest of our list (`diskprediction_local`, `insights`, `pg_autoscaler`) would drop it.

Cleanup, if this recurs: `ceph crash archive-all` alone is not enough. The crash **collector** replays
unposted files from `/var/lib/ceph/crash` on the node running the active mgr at ~1.5/s, so the count
climbs back even after the source is stopped — there were 16,543 unposted files here. Stop the source
first, verify with `ceph crash ls-new | tail` that no crash is newer than the fix, then delete the
backlog directories directly before a final `archive-all`.

Do not "fix" this with `mgr/crash/warn_recent_interval` (auto-archive after a day) — it hides the
storm without stopping it, and the mgr keeps paying for the crash store.

## RBD CSI Recovery (pods stuck ContainerCreating)

Symptoms: `input/output error` on mounts, `operation already exists` in CSI logs, `MountVolume.SetUp failed`.

```bash
# Step 1 — restart CSI node plugin on the affected node
kubectl delete pod -n rook-ceph -l app=csi-rbdplugin --field-selector spec.nodeName=<node>
# wait ~30s; check if pods recover
kubectl get pods -A | grep ContainerCreating

# Step 2 — clean stale VolumeAttachments (if pods still stuck)
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>

# Step 3 — if kernel-level RBD module is broken
talosctl reboot -n <ip> --wait

# Step 4 — hard reset (last resort)
# Proxmox: qm reset <vmid>
```

Idle PVCs on `ceph-block` cost three copies each and nothing reclaims them — the audit and the
detection recipe are in `storage.md` § Orphaned PVCs.
