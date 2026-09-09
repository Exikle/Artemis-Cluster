# GPU — Artemis-Cluster

Three Intel GPUs across seven nodes, two allocation mechanisms, one lane per card.

## Hardware and what each GPU reports

| Node                | GPU                          | PCI ID   | DRA `model` / `family`  | `gpu-tier` |
| ------------------- | ---------------------------- | -------- | ----------------------- | ---------- |
| `talos-gpu-01`      | Arc A380 (VFIO from Proxmox) | `0x56a5` | `A380` / `Arc A-Series` | `arc`      |
| `ymir`              | UHD P630 (Xeon E-2124G)      | `0x3e96` | `Unknown` / `Unknown`   | `gen95`    |
| `talos-cp-01/02/03` | HD 530 (M710q, Skylake)      | `0x1912` | `Unknown` / `Unknown`   | `gen9`     |
| `talos-w-01/02`     | none (Proxmox VMs)           | —        | —                       | _unset_    |

**Only the Arc reports a real model string.** The Gen 9 and Gen 9.5 iGPUs report
`Unknown` for both `model` and `family`, so a CEL selector aimed at one of them must
match on `pciId`. Read the live values before writing a selector:

```sh
kubectl get resourceslices -o json | jq '.items[].spec.devices[].attributes'
```

## Two lanes, one per card

Both mechanisms are deployed and neither is redundant. They are split by **card**, never
by app — running both against the same GPU means the scheduler cannot see that a
`dri-render` slot and a DRA claim are the same silicon.

| Lane      | Card            | Mechanism                         | Who it is for                                                    |
| --------- | --------------- | --------------------------------- | ---------------------------------------------------------------- |
| Exclusive | Arc A380        | `intel-gpu-resource-driver` (DRA) | one serious consumer at a time — currently Jellyfin              |
| Shared    | ymir's UHD P630 | `generic-device-plugin`           | latency-tolerant, cross-namespace — Frigate, future small models |

**The shared lane exists because DRA cannot cross namespaces.** A `ResourceClaim` is
namespace-scoped, so two pods can only share one GPU through a claim if they live in the
same namespace. `generic-device-plugin` has no such limit — it advertises
`devic.es/dri-render` off `/dev/dri/renderD128` and any namespace can request it. That is
the one capability DRA does not provide here, and the reason the plugin was not deleted
when Jellyfin moved to DRA.

`count:` on the device plugin is **not capacity accounting** — it is how many pods may
hold a slot, and nothing measures whether the card can keep up. Set it to what the GPU can
actually sustain, not to a large number.

The control planes' HD 530s are deliberately in neither lane. They publish DRA devices and
are monitored, but nothing is steered onto them.

## Node affinity keys

Use `node.kubernetes.io/gpu-tier`. It is declared per node in `talos/nodes/*.yaml.j2` under
`KubeNodeConfig.labels` and is absent on nodes with no GPU.

**Do not key GPU affinity on `extensions.talos.dev/i915`.** That label means the extension
is installed, not that the node has an Intel GPU — every schematic carries `i915`, so it is
true on the two Proxmox workers, which then ran both plugins and published empty
ResourceSlices. It would also silently stop matching if a card ever moved to the `xe`
driver, since that is a separate extension (`siderolabs/xe`) stamping a different label.

## Claims

A `ResourceClaimTemplate` mints a fresh claim per pod, so two pods that must share one
physical GPU will deadlock — the second never schedules. Where sharing within a namespace
is required, write a plain `ResourceClaim` instead; one claim can be reserved by up to 256
pods.

**`ResourceClaimTemplate.spec` is immutable.** Changing a selector fails with
`field is immutable` and Flux will not recreate the object on its own — delete the template
and re-apply:

```sh
kubectl delete resourceclaimtemplate -n <ns> <name>
just kube apply-ks <ns> <app>
```

CEL selectors do work on driver 0.11.0 / Kubernetes 1.37 — Jellyfin pins the Arc with
`device.attributes["gpu.intel.com"].model == "A380"` and allocates correctly. Upstream
experience is mixed on this (one repo reverted to `allocationMode: All` plus node affinity
after hitting apiserver dry-run friction), so verify a new selector against a real
allocation rather than assuming.

`memory` reports `0` on every device including the Arc, so capacity-aware placement on VRAM
is not available. A workload that overcommits VRAM fails at runtime, not at scheduling.

Do not request `gpu.intel.com/i915`. It is advertised as `0` on the four nodes that
predate the removal of `intel-device-plugin` (`967a7d0f9`) — a tombstone in node status
that kubelet zeroed but never deleted. A pod requesting it stays Pending forever.

## drm-exporter

Per-node metrics for every GPU: engine utilization, memory, frequency, power, temperature,
labelled by PCI slot and node.

Two Talos-specific settings, both load-bearing:

- **`SYS_RAWIO` is dropped**, leaving only `PERFMON`. That capability is for reading MSRs,
  and Talos ships no `msr` module (`siderolabs/extensions#620`). Keeping it gains nothing;
  the cost of dropping it is Intel iGPU package temperature and nothing else — engine
  utilization, memory, frequency and power all come from the perf PMU and sysfs.
- **The `observability` namespace carries `resource.kubernetes.io/admin-access: "true"`.**
  The exporter claims GPUs through an admin-access _monitor_ claim — read-only visibility
  of every device on the node, not counted as consumed, so it never steals the Arc from a
  workload. Without the namespace label the apiserver rejects the claim outright.

Scheduling is keyed on `gpu-tier` existing, so it runs on the five nodes with a GPU and not
on the two Proxmox workers.

## The Arc has no Resizable BAR, and nothing available fixes it

`pantheon`'s BIOS (HPE ML150 G9) has no ReBAR or Above-4G option, so the A380 runs with a
**256MB VRAM aperture** in front of 6GB of memory. Measured on the live card:

```text
BAR0  0xc0000000-0xc0ffffff        →  16MB  (registers)
BAR2  0x380000000000-0x38000fffffff → 256MB  (VRAM aperture)
resource2_resize = 0x100           → 256MB is the only size offered
```

`drm_memory_total_bytes` still reports the full `5.94Gi` of vram — the driver sees all of it;
what is capped is how much the host can map at once.

**`ymir` does not fix this.** Gigabyte's complete BIOS list for the C246N-WU2 is F2, F4 and
F5a, all security fixes; none introduces Resizable BAR. Moving the card to bare metal removes
the passthrough layer, not the aperture limit.

What that means per workload:

- **Media transcode costs about 10%.** Jellyfin's own docs put the penalty there and note that
  ReBAR is _mandatory_ only on Arc B-series; on A-series it is a recommendation. QuickSync is
  a fixed-function engine that streams through and never needs a large host-visible window,
  which is why the card works well here. This is the workload the Arc should keep.
- **Graphics/gaming degrades badly**, which is well documented and is where most published
  "Arc needs ReBAR" benchmarks come from.
- **Compute is untested here.** Expect reduced host-to-device transfer throughput, but no
  claim stronger than that has been verified for oneAPI/Level Zero on this card — running a
  small model on it is a cheaper experiment than acting on an assumption either way.

No board swap fixes this while the E-2124G stays. ReBAR support begins at Intel 10th gen /
400-series, so every C246 mini-ITX board (Gigabyte C246N-WU2, ASRock Rack C246 WSI and
E3C246D2I, the various C246 NAS boards) lacks it — it is a platform-generation limit, not a
vendor choice. The only route that keeps the CPU is the ReBarUEFI DXE module, which needs
CSM disabled — and `AGENTS.md` records that disabling CSM on ymir's board kills video.

## Arc A380 on bare metal

The card is enumerated by Talos's own `i915` extension today, from inside a Proxmox VM, and
reports a correct model string. Moving it to bare metal removes the passthrough layer
rather than adding a driver problem — `talos/schematics/gpu.yaml` already carries
`i915.force_probe=*`, `intel_iommu=on` and `iommu=pt`.

Two things that do not transfer from upstream repos: Intel **GVT-g** is mediated passthrough
of an _integrated_ GPU and cannot slice a discrete card (ours is already full VFIO), and no
public home-ops repo runs a discrete Arc on bare-metal Talos, so there is no reference
config for it.

**Do not plan this move. The card does not physically fit `ymir`.** `ymir` is a 1U chassis —
44mm of internal height — and the card is an ASRock Arc A380 Challenger ITX at 2 slots and
169.9 x 123mm. Low-profile brackets are ~68mm, so even a low-profile Arc would need to lie
flat on a riser and be single-slot; the only Arc in that class is an A310, which is a
downgrade from the A380 for transcode. Combined with the fact that C246 cannot give the card
Resizable BAR anyway, there is no version of this migration that is an improvement.

The Arc stays in `pantheon`, which has the space and the power. If GPU compute becomes a real
requirement, it is a new machine — modern platform with native ReBAR, chassis chosen around
the card — not a retrofit of either existing node.

## `xe` vs `i915`

Only the Arc is a candidate for `xe`. Gen 9 (HD 530) and Gen 9.5 (UHD P630) predate the
architecture `xe` was written for and stay on `i915` permanently.

`siderolabs/i915` and `siderolabs/xe` are separate extensions shipping one module each, so
adopting `xe` means adding an extension, not swapping one — the iGPU nodes still need
`i915`. There is no reason to do it while the Arc works on `i915`.

## ymir disk headroom

`ymir` is a 128GB SATA M.2 carrying the AI workloads plus a miroir loopfile pool. It hit
`DiskPressure` on 2026-09-09 at 70GB of container images, evicted pods, and took its
ResourceSlice and both GPU plugin pods down with it — which in turn made a Helm upgrade of
the DRA driver time out and roll back. Kubelet image GC recovered it unaided within five
minutes (images 70GB → 12GB).

The lesson worth keeping: **a node under `DiskPressure` carries a
`node.kubernetes.io/disk-pressure:NoSchedule` taint**, so any DaemonSet that does not
tolerate it loses its pod, and any Helm release waiting on that DaemonSet to become Ready
fails and rolls back. Check node conditions before moving a workload onto a node, not just
its hardware.
