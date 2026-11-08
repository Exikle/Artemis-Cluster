# pantheon Host Networking

This file covers the host-side virtual networking on the Proxmox box. `pantheon-zfs.md` covers the storage of the same host. `networking.md` covers the cluster-side networking. Everything here is a measured number or a rationale. Nothing here is a fact that `ip`, `bridge` or `ethtool` answers directly.

Origin: Forgejo issues #2160 (vNIC drops caused the miroir cascades) and #2204 (review the rest of the network settings of the host).

---

## There is exactly one NIC, and no second one to bond with

`nic0` is a Mellanox ConnectX-3 (`mlx4_en`, MT27500) at `06:00.0`. It is the **only** ethernet function on the box. No onboard 1GbE is visible. The onboard NICs of the ML150 G9 are either disabled in BIOS or absent. Host management, all three Talos VMs and the Forgejo LXC share that one cable.

#2160 measured the blast radius. A single cable or port fault severs `talos-w-01`, `talos-w-02` and `talos-gpu-01` at the same time, while bare-metal `ymir` is untouched. **Software cannot fix this.** Two real options exist. The first is to re-enable the onboard NICs in BIOS and build an `active-backup` bond (it degrades hard to 1G and needs host downtime). The second is to accept the risk and make sure that no miroir replica pair lands on two pantheon VMs.

---

## The tap drop knee is a packet-rate limit, not a bandwidth limit

Measured on 2026-09-17: `iperf3` UDP from a pod on `ymir` to a pod on `talos-gpu-01`, 20s per run. The measurement read `/sys/class/net/tap104i0/statistics/tx_dropped` on the host:

| Offered rate | datagram size | packets/s | tap TX drops |
| ------------ | ------------- | --------- | ------------ |
| 200 Mbit/s   | 200 B         | ~125,000  | **0**        |
| 300 Mbit/s   | 200 B         | ~187,000  | 55,881       |
| 400 Mbit/s   | 200 B         | ~250,000  | 531,600      |
| 522 Mbit/s   | 200 B         | ~326,000  | 510,582      |
| 700 Mbit/s   | 200 B         | ~331,000  | 1,246,888    |

**The knee sits between 125k and 187k pps.** Below it, the host tap drops nothing.

To isolate the variable, hold the bitrate fixed at 522 Mbit/s and change only the datagram size:

| datagram size | packets/s | tap TX drops |
| ------------- | --------- | ------------ |
| 200 B         | ~326,000  | 510,582      |
| 500 B         | ~163,000  | **0**        |
| 1400 B        | ~58,000   | **0**        |

All three runs used the same 522 Mbit/s. This confirms the reasoning of #2160 directly. The tun `ptr_ring` counts skbs, not bytes. GRO-aggregated superpackets pass at a bitrate that small packets cannot survive.

---

## Where the loss actually goes, once the tap stops dropping

With `txqueuelen` at 160000, the host tap drops nothing at 326k pps. But `iperf3` still reported 18-23% loss. That loss is **not** in the network path. One instrumented 20s run showed this:

| Stage                                                                     | packets lost |
| ------------------------------------------------------------------------- | ------------ |
| host tap (`tap104i0` `tx_dropped`)                                        | ~30,000      |
| guest kernel (`bond0.1099` `rx_drop`, and softnet `dropped` on every CPU) | **0**        |
| UDP socket receive-buffer overflow in the receiving pod                   | **626,851**  |
| iperf3's own reported total                                               | 731,396      |

On that pod, `/proc/net/snmp` shows `InErrors` and `RcvbufErrors` byte-for-byte identical. So every UDP error is the application failing to drain its socket.

The next run raised only the receive socket buffer and changed nothing else:

| `iperf3 -w` | rcvbuf errors | reported loss |
| ----------- | ------------- | ------------- |
| default     | 761,400       | 14%           |
| 8M          | 140,800       | 4.1%          |
| 32M         | **1,650**     | **1.6%**      |

The `net.core.rmem_max` of the guest is already 67108864, so nothing capped the larger buffers.

Do not tune the host for this. Past ~326k pps, the host and guest kernels are clean. The remaining loss belongs to the application that receives the packets. If an app on this cluster loses UDP at high packet rates, check its `SO_RCVBUF` before you touch pantheon.

## `netdev_max_backlog` and `netdev_budget` are unproven, and the harness cannot prove them

`ansible/roles/host_net_tuning` sets `netdev_max_backlog` 1000 -> 50000, `netdev_budget` 300 -> 600 and `netdev_budget_usecs` 2000 -> 4000 through `/etc/sysctl.d/90-host-net.conf`.

Do not describe those values as a measured fix. On 2026-09-17, an A/B test ran the harness above at 326k pps in both configurations. It got **zero** backlog drops in each arm (19.6M packets at 50000, 19.6M at the stock 1000), with `time_squeeze` deltas of 2 and 1.

The reason is structural. The harness drives `mlx4` NAPI polling, and the NAPI receive path never enqueues to the softnet backlog queue. Only the `netif_rx()` side does. That side is veth, or RPS, which is disabled on this host. **No iperf3 test through `nic0` can ever exercise `netdev_max_backlog` here.**

The values stay because they are harmless and they align the host with the Talos guests, which already run 50000.

### The unexplained 16,335

Over 63 days, `/proc/net/softnet_stat` column 2 read 14,572 on CPU 3 and 1,763 on CPU 5. The sum is 16,335, which is _exactly_ the `RX dropped` count of `nic0` across the same window. The `errors`, `missed` and `overrun` counts are all 0. #2204 originally recorded these as zero, which is wrong.

What produced them is still unknown. They are on a `netif_rx()` path that the harness does not reach, and nobody has explained the exact equality with the counter of `nic0`. Do not attribute it to VLAN filtering. That was an early guess and it is wrong.

---

## `bridge-vids` carried three VLANs that do not exist

`vmbr0` allowed `1001,1002,1088,1099,1151,1152,1153,1154`. The `networkconf` API of the UniFi controller returns only **99, 1001, 1062, 1088, 1099, 1151, 1152**. So **1002, 1153 and 1154 exist nowhere on the network**. They were trimmed on 2026-09-17, first to `1099,1152` and then to `1062,1099,1152` after the CAM VLAN was trunked through to the VMs (below).

To recheck the authoritative list, run:

```bash
curl -sk -H "X-API-KEY: $(op read op://artemis/unifi/UNIFI_API_KEY)" \
  https://10.10.99.1/proxy/network/api/s/default/rest/networkconf
```

### VLAN 1062 (CAM) is trunked to the pantheon VMs

`talos/cluster.yaml.j2` gives **every** Talos node a `bond0.1062` VLAN interface, and the `cam` NetworkAttachmentDefinition masters its macvlan on it. Until 2026-09-17, that interface was dead on the three pantheon VMs. Their taps trunked only `1099;1152`. A `cam`-attached pod scheduled onto `talos-w-01`, `talos-w-02` or `talos-gpu-01` would have got an interface that silently received nothing, with no error anywhere. The `bond0.1062` of `talos-gpu-01` showed it: 0 RX packets, 51 TX.

The VLAN is now trunked end to end, so the `cam` NAD works on any node:

- `vmbr0` `bridge-vids` is `1062,1099,1152`
- All three `qemu-server` configs carry `trunks=1062;1099;1152`

frigate stays pinned to `node.kubernetes.io/gpu-tier: gen95` (only `ymir` carries it) for transcoding reasons, not networking reasons. That pin is now a GPU constraint alone.

Verified end to end on 2026-09-17: a pod on `talos-gpu-01` annotated onto the `cam` NAD came up with `net1 = 10.10.62.250/24`. It pinged the CAM gateway `10.10.62.1` at 0% loss, 0.59ms average.

Two diagnostic traps cost a detour on the way there. Know both before you debug a VLAN on this host:

- `tcpdump -i nic0 vlan 1062` can never match. `nic0` runs `rx-vlan-offload: on`, so the hardware strips the VLAN header and moves the tag into skb metadata before libpcap sees the frame. The BPF `vlan` primitive reads packet bytes, and those bytes no longer carry a tag. A clean capture reports "0 packets captured" on a VLAN that works perfectly.
- A `bond0.<vid>` in a guest that sits at 0 RX packets does not mean the VLAN is broken. CAM is a quiet, mostly-unicast VLAN, so nothing floods to a guest that has not yet ARPed onto it. Test with a real `cam`-attached pod and a ping, not with interface counters.

**Correction (2026-09-23): the switch-side change was needed, and the team made it late.** pantheon is on the **CRS309's `sfp-sfpplus8`** (its MAC is learned there, and UCG port 3 is the CRS309 uplink), not directly on the UCG. Until 2026-09-23, that port did not carry 1062, so camera traffic never reached `vmbr0` (frigate worked only because it runs on ymir). `sfp-sfpplus8` is now a full trunk that includes 1062 (tofu stack `mikrotik`). The paragraph below assumes this.

The cost is that camera broadcast and multicast traffic now enters `vmbr0` and floods to the VM taps. If that shows up as load, the lever is to remove 1062 from the taps that do not need it, not from `nic0`.

Apply VLAN changes with `bridge vlan add/del`. Never use `ifreload -a`. The management address of the host rides `vmbr0.1099`, on the same bridge that you reconfigure. Edit `/etc/network/interfaces` separately to persist the change. Ansible does **not** manage that file.

---

## Settings deliberately left at stock

| Setting                    | Why it stays                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------- |
| RPS / XPS disabled         | Measured in #2160; enabling made drops worse                                                                  |
| `irqbalance` inactive      | All 25 mlx4 IRQs are pinned to node 0 because the card is there; irqbalance would spread them off it          |
| Ring buffers 1024 of 8192  | `errors`, `missed` and `overrun` are all 0                                                                    |
| Channels RX 16 / TX 24     | Raising RX adds IRQs that all still land on node 0; no evidence of uneven RSS                                 |
| Flow control               | pause-duration counts are noise; disabling rx pause converts pauses into drops                                |
| LXC veth `txqueuelen` 1000 | veth has no tun `ptr_ring`, so the #2160 mechanism does not apply; `veth105i0` has zero drops both directions |

The Forgejo LXC runs `firewall=0`. `/etc/pve/firewall/` is an empty directory with no cluster rules and no per-guest rules. So the `fwbr`/`fwpr`/`fwln` triple bridge hop would be pure overhead. `veth105i0` attaches straight to `vmbr0` with PVID 1099.

---

## Re-running the harness

```bash
kubectl run iperf-server-2204 --image=docker.io/networkstatic/iperf3:latest \
  --restart=Never --overrides='{"spec":{"nodeName":"talos-gpu-01"}}' -- -s
kubectl run iperf-client-2204 --image=docker.io/networkstatic/iperf3:latest \
  --restart=Never --command --overrides='{"spec":{"nodeName":"ymir"}}' -- sleep 7200
kubectl exec iperf-client-2204 -- iperf3 -c <server-pod-ip> -u -l 200 -b 522M -t 20
```

Each of these traps cost a run to find:

- `.claude/hooks/guard-destructive.sh` hard-blocks `kubectl apply`. It does not block `kubectl run`, and the `default` namespace enforces `privileged`, so no securityContext is needed.
- Leave at least 8 seconds between runs. If you run `iperf3` back to back against one server, every run after the first fails instantly, and a truncated capture hides the error.
- Ignore the loss percentage of iperf3 as a host metric. At 125k pps it reports ~10% loss while the host tap drops nothing. So a second loss mechanism exists further along (the guest virtio ring, or the single-threaded UDP receiver of iperf3). The `tx_dropped` counter of `tap104i0` is the host-side ground truth.
- `ip link set txqueuelen` resizes a live tun `ptr_ring`, because tun handles `NETDEV_CHANGE_TX_QUEUE_LEN`. So a sweep needs no VM restart.
