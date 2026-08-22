---
name: osd-rebuild
description: Rebuild a Rook-Ceph OSD in place so its data is rewritten by backfill — used to apply new pool settings (compression, encryption) to existing data, or to physically replace an OSD disk. Use for "rebuild OSD", "replace the ceph drive", "compress existing ceph data", "swap the NVMe in cp-0X", or "recreate osd.N". Scoped to the Artemis cluster.
---

# Skill: OSD Rebuild

Destroy and recreate one Rook-Ceph OSD so Ceph refills it by backfill. Because backfill goes
through the normal BlueStore write path, everything written back lands under the **current** pool
settings — this is the only way to apply compression to data that already exists.

Two variants, same procedure:

| Variant       | When                                        | Difference                                 |
| ------------- | ------------------------------------------- | ------------------------------------------ |
| **In-place**  | Applying new pool settings to existing data | Zap and reuse the same disk                |
| **Disk swap** | Replacing failing or older hardware         | Power off, physically swap, then provision |

> Read `.agents/references/rook-ceph.md` for Rook-Ceph and RBD context first — its § OSD topology
> holds the rules a rebuild must not break. `.agents/references/osd-topology-2026-08-21.md` has the
> measurements behind them.

---

## Artemis topology — read before you touch anything

```text
3 hosts × 1 OSD each   size=3   min_size=2   failure domain = host
osd.0 → talos-cp-03    osd.1 → talos-cp-01    osd.2 → talos-cp-02
device: /dev/nvme0n1  (devicePathFilter ^/dev/disk/by-id/nvme-SAMSUNG_MZVLW256HEHP.*)
```

**This is not a drain-and-rebalance.** With exactly 3 hosts and `size=3` at host failure domain,
removing one OSD leaves 2 hosts — CRUSH cannot place a third replica anywhere. PGs go
`active+undersized+degraded` and **stay there** until the OSD comes back. There is no "wait for
rebalance to finish" step; there is nothing to rebalance to.

Consequences you are accepting for the length of the rebuild:

- Running at **2 copies**. `min_size=2` means I/O continues, but there is zero redundancy margin.
- **A second OSD failure during the window stops all I/O.** Not data loss, but a hard outage.
- The window is however long it takes to backfill the full OSD (~154 GiB as of 2026-08-11).

**Therefore: exactly one OSD at a time, and `HEALTH_OK` before starting the next.** Never batch.

---

## Pre-flight — all must pass

```bash
TOOLS=$(kubectl -n rook-ceph get pod -l app=rook-ceph-tools -o name | head -1)
alias ceph_="kubectl -n rook-ceph exec $TOOLS -c rook-ceph-tools -- ceph"

ceph_ -s                      # must be HEALTH_OK, all PGs active+clean
ceph_ osd df                  # note RAW USE — this is what has to backfill back
ceph_ osd tree                # confirm the osd.N → host mapping
```

Do not start if:

- Health is anything other than `HEALTH_OK` (a pre-existing warning becomes invisible under the
  degraded state, and you lose the ability to tell new problems from old)
- Any PG is not `active+clean`
- Another OSD was rebuilt less than one full scrub interval ago
- You do not have a spare disk on hand — the rebuild is when you are most exposed

---

## Procedure

### 1. Pin the OSD identity

```bash
OSD=2                                    # the OSD being rebuilt
NODE=talos-cp-02                         # its host
ceph_ osd metadata $OSD | grep -E 'hostname|bluestore_bdev_dev_node|device_ids'
```

Record `device_ids` — it carries the serial, which is how you confirm you pulled the right
physical drive later.

### 2. Stop the OSD

```bash
kubectl -n rook-ceph scale deployment rook-ceph-osd-$OSD --replicas=0
kubectl -n rook-ceph wait --for=delete pod -l ceph-osd-id=$OSD --timeout=5m
```

PGs go degraded here. That is expected and is the point of no return for the window.

### 3. Purge it from the cluster

```bash
ceph_ osd out $OSD
ceph_ osd purge $OSD --yes-i-really-mean-it
ceph_ osd tree                           # osd.$OSD must be gone, not just "down"
```

`purge` removes the OSD from CRUSH, deletes its auth key, and frees the ID for reuse. Do not use
`ceph osd rm` alone — it leaves the auth entry and CRUSH slot behind, and provisioning will fail
in a way that looks like a disk problem.

### 4. Remove the Rook deployment

```bash
kubectl -n rook-ceph delete deployment rook-ceph-osd-$OSD
```

### 5. Wipe the disk

Rook will not provision a disk that still carries LVM/BlueStore metadata. On Talos there is no
SSH, so this runs either through `talosctl` or a privileged pod.

**Preferred — talosctl:**

```bash
talosctl -n <node-ip> wipe disk nvme0n1
```

> Verify the subcommand name against the running Talos version the first time
> (`talosctl wipe --help`) — it has moved between releases. If it is unavailable, use the pod
> method below.

**Fallback — privileged pod:**

```bash
kubectl -n rook-ceph run disk-zap-$OSD --rm -it --restart=Never \
  --overrides='{"spec":{"nodeName":"'"$NODE"'","hostNetwork":true,
    "containers":[{"name":"zap","image":"quay.io/ceph/ceph:v20.2.3","stdin":true,"tty":true,
    "securityContext":{"privileged":true},
    "command":["sh","-c","sgdisk --zap-all /dev/nvme0n1 && dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=200 oflag=direct && blkdiscard /dev/nvme0n1 || true"],
    "volumeMounts":[{"name":"dev","mountPath":"/dev"}]}],
    "volumes":[{"name":"dev","hostPath":{"path":"/dev"}}]}}'
```

**Disk-swap variant:** skip the wipe. Instead `talosctl -n <node-ip> shutdown`, physically swap
the drive, power on, wait for the node to rejoin (`kubectl get node $NODE -w`). A factory-fresh
drive needs no zapping; a used one does — run the wipe above after the node is back.

### 6. Let Rook provision the replacement

```bash
kubectl -n rook-ceph rollout restart deployment rook-ceph-operator
kubectl -n rook-ceph logs -f deploy/rook-ceph-operator | grep -E 'osd|provision'
```

The operator runs a `rook-ceph-osd-prepare-$NODE` job that finds the blank device via
`devicePathFilter` and creates the OSD. It reuses the freed ID, so you get `osd.$OSD` back with
the same number.

```bash
kubectl -n rook-ceph get pods -l ceph-osd-id=$OSD -w
```

If the prepare job finds no devices, the wipe did not fully take — check its logs for
`skipping device ... already in use` and re-run step 5.

### 7. Watch backfill to completion

```bash
watch -n 30 'kubectl -n rook-ceph exec '"$TOOLS"' -c rook-ceph-tools -- ceph -s'
```

Wait for `HEALTH_OK` and all 265 PGs `active+clean`. Until then you are still at 2 copies.

To throttle backfill if client latency suffers (these are consumer drives — it will):

```bash
ceph_ config set osd osd_max_backfills 1
ceph_ config set osd osd_recovery_max_active 1
# revert with `ceph config rm osd <key>` once clean
```

### 8. Verify the rewrite actually compressed

```bash
ceph_ osd df                             # RAW USE for the rebuilt OSD vs the other two
```

This is the real proof. The rebuilt OSD should show materially lower `RAW USE` than its
siblings, because only its copy has been rewritten under the current pool settings.

```bash
ceph_ tell osd.$OSD perf dump | jq '.bluestore | {compressed_original, compressed_allocated}'
```

**Do not expect `ceph df` pool `USED` to drop by the full ratio after one OSD.** It aggregates
all three replicas, so you see roughly a third of the eventual saving per rebuild. Full benefit
lands only after all three.

---

## After each rebuild

- Confirm `HEALTH_OK` and all PGs `active+clean`
- Let at least one deep-scrub interval pass before the next OSD
- Update `.claude/session-journal.md` with which OSD, which disk serial, and the before/after
  `RAW USE`

---

## If it goes wrong

| Symptom                                     | Cause                                 | Action                                                                                                                      |
| ------------------------------------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Prepare job finds no devices                | Disk still has LVM/BlueStore metadata | Re-run step 5; check `lsblk` output in the job log                                                                          |
| OSD comes up but stays `down`               | Auth key left behind from an `osd rm` | `ceph auth del osd.$OSD`, delete the deployment, re-run step 6                                                              |
| PGs stuck `undersized` after OSD is back up | CRUSH weight is 0                     | `ceph osd crush reweight osd.$OSD 0.23289`                                                                                  |
| Backfill starves client I/O                 | Consumer drives saturating            | Apply the throttle in step 7                                                                                                |
| Second OSD fails mid-window                 | I/O halted (`min_size=2` unmet)       | Bring the rebuilding OSD back **first**, even un-backfilled — restores quorum of replicas faster than fixing the failed one |

**Never** lower `min_size` to 1 to escape a stall. It converts an outage into potential data loss
on the next fault.
