# GPU — Artemis-Cluster

The cluster has five Intel GPUs on five of the seven nodes (one Arc, one P630, three HD 530s). It has two allocation mechanisms, and each card belongs to one lane.

## Hardware and what each GPU reports

| Node                | GPU                          | PCI ID   | DRA `model` / `family`  | `gpu-tier` |
| ------------------- | ---------------------------- | -------- | ----------------------- | ---------- |
| `talos-gpu-01`      | Arc A380 (VFIO from Proxmox) | `0x56a5` | `A380` / `Arc A-Series` | `arc`      |
| `ymir`              | UHD P630 (Xeon E-2124G)      | `0x3e96` | `Unknown` / `Unknown`   | `gen95`    |
| `talos-cp-01/02/03` | HD 530 (M710q, Skylake)      | `0x1912` | `Unknown` / `Unknown`   | `gen9`     |
| `talos-w-01/02`     | none (Proxmox VMs)           | —        | —                       | _unset_    |

Only the Arc reports a real model string. The Gen 9 and Gen 9.5 iGPUs report `Unknown` for both `model` and `family`. A CEL selector that targets one of them must match on `pciId`. Before you write a selector, read the live values:

```sh
kubectl get resourceslices -o json | jq '.items[].spec.devices[].attributes'
```

## Two lanes, one per card

Both mechanisms are deployed, and neither is redundant. The split is by **card**, never by app. If you run both mechanisms against the same GPU, the scheduler cannot see that a `dri-render` slot and a DRA claim are the same silicon.

| Lane      | Card            | Mechanism                         | Who it is for                                                    |
| --------- | --------------- | --------------------------------- | ---------------------------------------------------------------- |
| Exclusive | Arc A380        | `intel-gpu-resource-driver` (DRA) | one serious consumer at a time — currently silo                  |
| Shared    | ymir's UHD P630 | `generic-device-plugin`           | latency-tolerant, cross-namespace — Frigate, future small models |

The shared lane exists because DRA cannot cross namespaces. A `ResourceClaim` is namespace-scoped. Two pods can share one GPU through a claim only if they live in the same namespace. `generic-device-plugin` has no such limit. It advertises `devic.es/dri-render` off `/dev/dri/renderD128`, and any namespace can request it. DRA does not provide this capability here. This is why the team did not delete the plugin when Jellyfin moved to DRA.

`count:` on the device plugin is **not capacity accounting**. It is the number of pods that can hold a slot, and nothing measures whether the card can keep up. Set it to what the GPU can actually sustain. Do not set a large number.

The HD 530s of the control planes are deliberately in neither lane. They publish DRA devices and the cluster monitors them, but nothing is steered onto them.

## Node affinity keys

Key on `node.kubernetes.io/gpu-tier`. Never key on `extensions.talos.dev/i915`. `instructions/cluster-conventions.md` § GPU Workloads is the home for that rule, and it wins. Each node declares its tier in `talos/nodes/*.yaml.j2` under `KubeNodeConfig.labels`. The label is absent on nodes with no GPU. The `i915` label means only that the extension is installed, and every schematic carries it. It would also stop matching if a card moved to `xe`, which is a separate extension with a different label.

## Claims

A `ResourceClaimTemplate` creates a fresh claim for each pod. So two pods that must share one physical GPU deadlock, because the second pod never schedules. If sharing within a namespace is required, write a plain `ResourceClaim` instead. Up to 256 pods can reserve one claim.

**`ResourceClaimTemplate.spec` is immutable.** If you change a selector, it fails with `field is immutable`, and Flux does not recreate the object on its own. Delete the template and apply again:

```sh
kubectl delete resourceclaimtemplate -n <ns> <name>
just kube apply-ks <ns> <app>
```

CEL selectors work. silo (and Jellyfin before it) pins the Arc with `device.attributes["gpu.intel.com"].model == "A380"` and allocates correctly. Test a new selector against a real allocation. Do not assume that it works. For the driver version, run `grep tag: kubernetes/apps/kube-system/intel-gpu-resource-driver/app/ocirepository.yaml`.

`memory` reports `0` on every device, including the Arc. So capacity-aware placement on VRAM is not available. A workload that overcommits VRAM fails at runtime, not at scheduling.

Do not request `gpu.intel.com/i915`. `intel-device-plugin` was removed (`967a7d0f9`), so no node advertises that resource, and a pod that requests it stays Pending forever.

## drm-exporter

drm-exporter provides per-node metrics for every GPU: engine utilization, memory, frequency, power, and temperature. The metrics carry labels for the PCI slot and the node.

Two Talos-specific settings are both load-bearing:

- `SYS_RAWIO` is dropped, and only `PERFMON` remains. That capability reads MSRs, and Talos ships no `msr` module (`siderolabs/extensions#620`). Keeping it gains nothing. Dropping it costs the Intel iGPU package temperature and nothing else. Engine utilization, memory, frequency and power all come from the perf PMU and sysfs.
- The `observability` namespace carries `resource.kubernetes.io/admin-access: "true"`. The exporter claims GPUs through an admin-access _monitor_ claim. That claim gives read-only visibility of every device on the node and does not count as consumed, so it never steals the Arc from a workload. Without the namespace label, the apiserver rejects the claim outright.

Scheduling keys on `gpu-tier` existing. So the exporter runs on the five nodes with a GPU and not on the two Proxmox workers.

## The Arc has no Resizable BAR, and nothing available fixes it

The BIOS of `pantheon` (HPE ML150 G9) has no ReBAR or Above-4G option. So the A380 runs with a **256MB VRAM aperture** in front of 6GB of memory. Measured on the live card:

```text
BAR0  0xc0000000-0xc0ffffff        →  16MB  (registers)
BAR2  0x380000000000-0x38000fffffff → 256MB  (VRAM aperture)
resource2_resize = 0x100           → 256MB is the only size offered
```

`drm_memory_total_bytes` still reports the full `5.94Gi` of vram. The driver sees all of it. What is capped is how much the host can map at once.

**`ymir` does not fix this.** The complete BIOS list of Gigabyte for the C246N-WU2 is F2, F4 and F5a. All three are security fixes, and none introduces Resizable BAR. If you move the card to bare metal, you remove the passthrough layer, but the aperture limit stays.

The effect on each workload:

- **Media transcode costs about 10%.** The Jellyfin docs put the penalty there. They note that ReBAR is _mandatory_ only on Arc B-series, and a recommendation on A-series. QuickSync is a fixed-function engine that streams through and never needs a large host-visible window. This is why the card works well here. The Arc should keep this workload.
- **Graphics and gaming degrade badly.** This is well documented, and most published "Arc needs ReBAR" benchmarks come from this case.
- **Compute is untested here.** Expect reduced host-to-device transfer throughput. Nobody has verified a stronger claim for oneAPI/Level Zero on this card. Running a small model on it is a cheaper experiment than acting on an assumption either way.

No board swap fixes this while the E-2124G stays. ReBAR support begins at Intel 10th gen and the 400-series. So every C246 mini-ITX board lacks it (Gigabyte C246N-WU2, ASRock Rack C246 WSI and E3C246D2I, the various C246 NAS boards). This is a platform-generation limit, not a vendor choice. The only route that keeps the CPU is the ReBarUEFI DXE module, which needs CSM disabled. `hardware.md` records that disabling CSM on the board of ymir kills video.

## Arc A380 on bare metal

Today the `i915` extension of Talos enumerates the card from inside a Proxmox VM, and the card reports a correct model string. If you move it to bare metal, you remove the passthrough layer and add no driver problem. `talos/schematics/gpu.yaml` already carries `i915.force_probe=*`, `intel_iommu=on` and `iommu=pt`.

Two things do not transfer from upstream repos. First, Intel **GVT-g** is mediated passthrough of an _integrated_ GPU and cannot slice a discrete card (ours is already full VFIO). Second, no public home-ops repo runs a discrete Arc on bare-metal Talos, so no reference config exists for it.

`ymir` is a **1U chassis**, so the card cannot stand in the x16 slot. It must lie flat on a riser. Dimensionally that works: the ASRock A380 Challenger ITX is ~40mm thick against roughly 44mm of internal height. Fit is not the blocker.

Check two things before you commit to the move: **thermals** and **PSU power**. That card cools with an axial fan that blows down onto its heatsink. If the card lies flat with a few millimetres of clearance, the fan has nothing to draw from. 1U GPUs are normally passive blocks that front-to-back chassis airflow feeds. The card also takes an 8-pin PCIe connector, and 1U power supplies frequently do not carry one.

**None of this changes the ReBAR situation.** C246 cannot provide ReBAR (see above). So the move gives you operational simplification (no Proxmox passthrough, no dependency on a healthy `pantheon`) and nothing else. `ymir` already runs Frigate on its own iGPU, so weigh the move on that basis alone.

## `xe` vs `i915`

Only the Arc is a candidate for `xe`. Gen 9 (HD 530) and Gen 9.5 (UHD P630) predate the architecture that `xe` was written for. They stay on `i915` permanently.

`siderolabs/i915` and `siderolabs/xe` are separate extensions that ship one module each. To adopt `xe`, you add an extension. You do not swap one, because the iGPU nodes still need `i915`. While the Arc works on `i915`, there is no reason to do it.

## ymir disk headroom

`ymir` is a 128GB SATA M.2 that carries the AI workloads plus a miroir loopfile pool. So it is the node most prone to `DiskPressure`. **A node under `DiskPressure` carries a `node.kubernetes.io/disk-pressure:NoSchedule` taint.** Any DaemonSet that does not tolerate the taint loses its pod. Any Helm release that waits for that DaemonSet to become Ready fails and rolls back. Before you move a workload onto a node, check the node conditions as well as the hardware.
