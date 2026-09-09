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

## Arc A380 on bare metal

The card is enumerated by Talos's own `i915` extension today, from inside a Proxmox VM, and
reports a correct model string. Moving it to bare metal removes the passthrough layer
rather than adding a driver problem — `talos/schematics/gpu.yaml` already carries
`i915.force_probe=*`, `intel_iommu=on` and `iommu=pt`.

Two things that do not transfer from upstream repos: Intel **GVT-g** is mediated passthrough
of an _integrated_ GPU and cannot slice a discrete card (ours is already full VFIO), and no
public home-ops repo runs a discrete Arc on bare-metal Talos, so there is no reference
config for it.

If the Arc ever lands in `ymir`, that node holds two Intel GPUs and every claim there needs
a CEL selector — `model` for the Arc, `pciId` for the P630. `ymir` is a
Gigabyte C246N-WU2 (mini-ITX, one x16 slot) on a 128GB SATA M.2; check physical clearance,
PCIe aux power, and its disk headroom before planning that move.

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
