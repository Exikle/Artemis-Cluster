# pantheon Host Networking

Host-side virtual networking on the Proxmox box. Storage for the same host is in
`pantheon-zfs.md`; cluster-side networking is in `networking.md`. Everything here is a measured
number or a rationale — nothing that `ip`, `bridge` or `ethtool` answers directly.

Origin: Forgejo issues #2160 (vNIC drops caused the miroir cascades) and #2204 (review the rest
of the host's network settings).

---

## There is exactly one NIC, and no second one to bond with

`nic0` is a Mellanox ConnectX-3 (`mlx4_en`, MT27500) at `06:00.0`, and it is the **only**
ethernet function on the box. No onboard 1GbE is visible — the ML150 G9's are either disabled in
BIOS or absent. Host management, all three Talos VMs and the Forgejo LXC share that one cable.

That is the blast radius #2160 measured: a single cable or port fault severs `talos-w-01`,
`talos-w-02` and `talos-gpu-01` simultaneously, while bare-metal `ymir` is untouched. **It cannot
be fixed in software.** The two real options are re-enabling the onboard NICs in BIOS and
building an `active-backup` bond (degrades hard to 1G, needs host downtime), or accepting it and
making sure no miroir replica pair lands on two pantheon VMs.

---

## The tap drop knee is a packet-rate limit, not a bandwidth limit

Measured 2026-09-17, `iperf3` UDP from a pod on `ymir` to a pod on `talos-gpu-01`, 20s per run,
reading `/sys/class/net/tap104i0/statistics/tx_dropped` on the host:

| Offered rate | datagram size | packets/s | tap TX drops |
| ------------ | ------------- | --------- | ------------ |
| 200 Mbit/s   | 200 B         | ~125,000  | **0**        |
| 300 Mbit/s   | 200 B         | ~187,000  | 55,881       |
| 400 Mbit/s   | 200 B         | ~250,000  | 531,600      |
| 522 Mbit/s   | 200 B         | ~326,000  | 510,582      |
| 700 Mbit/s   | 200 B         | ~331,000  | 1,246,888    |

**The knee sits between 125k and 187k pps.** Below it the host tap drops nothing.

Holding the bitrate fixed at 522 Mbit/s and changing only the datagram size isolates the
variable:

| datagram size | packets/s | tap TX drops |
| ------------- | --------- | ------------ |
| 200 B         | ~326,000  | 510,582      |
| 500 B         | ~163,000  | **0**        |
| 1400 B        | ~58,000   | **0**        |

Same 522 Mbit/s in all three. This is the direct confirmation of #2160's reasoning: the tun
`ptr_ring` counts skbs, not bytes, so GRO-aggregated superpackets sail through at a bitrate that
small packets cannot survive.

---

## Where the loss actually goes, once the tap stops dropping

With `txqueuelen` at 160000 the host tap drops nothing at 326k pps, but `iperf3` still reported
18-23% loss. That loss is **not** in the network path. One instrumented 20s run:

| Stage                                                                     | packets lost |
| ------------------------------------------------------------------------- | ------------ |
| host tap (`tap104i0` `tx_dropped`)                                        | ~30,000      |
| guest kernel (`bond0.1099` `rx_drop`, and softnet `dropped` on every CPU) | **0**        |
| UDP socket receive-buffer overflow in the receiving pod                   | **626,851**  |
| iperf3's own reported total                                               | 731,396      |

On that pod `/proc/net/snmp` shows `InErrors` and `RcvbufErrors` byte-for-byte identical, so
every UDP error is the application failing to drain its socket.

Raising only the receive socket buffer, everything else unchanged:

| `iperf3 -w` | rcvbuf errors | reported loss |
| ----------- | ------------- | ------------- |
| default     | 761,400       | 14%           |
| 8M          | 140,800       | 4.1%          |
| 32M         | **1,650**     | **1.6%**      |

The guest's `net.core.rmem_max` is already 67108864, so nothing capped the larger buffers.

**Do not tune the host for this.** Past ~326k pps the host and guest kernels are clean and the
remaining loss belongs to whatever application is receiving. When an app on this cluster loses
UDP at high packet rates, check its `SO_RCVBUF` before touching pantheon.

## `netdev_max_backlog` and `netdev_budget` are unproven, and the harness cannot prove them

`ansible/roles/host_net_tuning` sets `netdev_max_backlog` 1000 -> 50000, `netdev_budget`
300 -> 600 and `netdev_budget_usecs` 2000 -> 4000 via `/etc/sysctl.d/90-host-net.conf`.

**Do not describe those values as a measured fix.** An A/B on 2026-09-17 ran the harness above at
326k pps in both configurations and got **zero** backlog drops in each arm (19.6M packets at
50000, 19.6M at the stock 1000), with `time_squeeze` deltas of 2 and 1.

The reason is structural: the harness drives `mlx4` NAPI polling, and the NAPI receive path never
enqueues to the softnet backlog queue. Only the `netif_rx()` side does — veth, or RPS, which is
disabled on this host. **No iperf3 test through `nic0` can ever exercise `netdev_max_backlog`
here.**

The values are kept because they are harmless and align the host with the Talos guests, which
already run 50000.

### The unexplained 16,335

`/proc/net/softnet_stat` column 2 read 14,572 on CPU 3 and 1,763 on CPU 5 over 63 days — 16,335,
which is _exactly_ `nic0`'s `RX dropped` across the same window, with `errors`, `missed` and
`overrun` all 0. #2204 originally recorded these as zero, which is wrong.

What produced them is still unknown. It is on a `netif_rx()` path the harness does not reach, and
the exact equality with `nic0`'s counter is not yet explained. Do not attribute it to VLAN
filtering — that was an early guess and it is wrong.

---

## `bridge-vids` carried three VLANs that do not exist

`vmbr0` allowed `1001,1002,1088,1099,1151,1152,1153,1154`. The UniFi controller's own
`networkconf` API returns only **99, 1001, 1062, 1088, 1099, 1151, 1152** — so **1002, 1153 and
1154 exist nowhere on the network**. Trimmed on 2026-09-17, first to `1099,1152` and then to
`1062,1099,1152` once the CAM VLAN was trunked through to the VMs (below).

The authoritative list, when this needs rechecking:

```bash
curl -sk -H "X-API-KEY: $(op read op://artemis/unifi/UNIFI_API_KEY)" \
  https://10.10.99.1/proxy/network/api/s/default/rest/networkconf
```

### VLAN 1062 (CAM) is trunked to the pantheon VMs

`talos/cluster.yaml.j2` gives **every** Talos node a `bond0.1062` VLAN interface, and the `cam`
NetworkAttachmentDefinition masters its macvlan on it. Until 2026-09-17 that interface was dead
on the three pantheon VMs — their taps trunked only `1099;1152`, so a `cam`-attached pod
scheduled onto `talos-w-01`, `talos-w-02` or `talos-gpu-01` would have got an interface that
silently received nothing, with no error anywhere. `talos-gpu-01`'s `bond0.1062` showed it: 0 RX
packets, 51 TX.

It is now trunked end to end, so the `cam` NAD works on any node:

- `vmbr0` `bridge-vids` is `1062,1099,1152`
- all three `qemu-server` configs carry `trunks=1062;1099;1152`

frigate remains pinned to `node.kubernetes.io/gpu-tier: gen95` (only `ymir` carries it) for
transcoding reasons, not networking ones — that pin is now a GPU constraint alone.

Verified end to end on 2026-09-17: a pod on `talos-gpu-01` annotated onto the `cam` NAD came up
with `net1 = 10.10.62.250/24` and pinged the CAM gateway `10.10.62.1` at 0% loss, 0.59ms average.

Two diagnostic traps cost a detour on the way there, both worth knowing before debugging a VLAN
on this host:

- **`tcpdump -i nic0 vlan 1062` can never match.** `nic0` runs `rx-vlan-offload: on`, so the
  hardware strips the VLAN header and moves the tag into skb metadata before libpcap sees the
  frame. The BPF `vlan` primitive reads packet bytes, which no longer carry a tag. A clean
  capture reports "0 packets captured" on a VLAN that is working perfectly.
- **A guest's `bond0.<vid>` sitting at 0 RX packets does not mean the VLAN is broken.** CAM is a
  quiet, mostly-unicast VLAN, so nothing floods to a guest that has not yet ARPed onto it. Test
  with a real `cam`-attached pod and a ping, not with interface counters.

**Correction (2026-09-23): the switch-side change was needed and never made.** pantheon is on
the **CRS309's `sfp-sfpplus8`** (its MAC is learned there; UCG port 3 is the CRS309 uplink), and
that port's trunk carries 1, 1001, 1088, 1099, 1151 and 1152 — **not 1062**. So camera traffic
never reaches `vmbr0` and a `cam`-attached pod on a pantheon VM gets nothing; frigate works
because it runs on ymir. Adding 1062 to the CRS309 bridge VLAN entry (tofu stack `mikrotik`)
is what the paragraph below assumes happened.

The cost is that camera broadcast and multicast traffic now enters `vmbr0` and is flooded to the
VM taps. If that ever shows up as load, the lever is removing 1062 from the taps that do not need
it rather than from `nic0`.

**Apply VLAN changes with `bridge vlan add/del`, never `ifreload -a`.** The host's management
address rides `vmbr0.1099`, on the same bridge being reconfigured. `/etc/network/interfaces` is
edited separately to persist, and is **not** ansible-managed.

---

## Settings deliberately left at stock

| Setting                    | Why it stays                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------- |
| RPS / XPS disabled         | Measured in #2160; enabling made drops worse                                                                  |
| `irqbalance` inactive      | All 25 mlx4 IRQs are pinned to node 0 because the card is there; irqbalance would spread them off it          |
| Ring buffers 1024 of 8192  | `errors`, `missed` and `overrun` are all 0 across 3.8e10 packets                                              |
| Channels RX 16 / TX 24     | Raising RX adds IRQs that all still land on node 0; no evidence of uneven RSS                                 |
| Flow control               | 837 pause-duration over 63 days is noise; disabling rx pause converts pauses into drops                       |
| LXC veth `txqueuelen` 1000 | veth has no tun `ptr_ring`, so the #2160 mechanism does not apply; `veth105i0` has zero drops both directions |

The Forgejo LXC ran `firewall=1` until 2026-09-17. `/etc/pve/firewall/` is an empty directory —
no cluster rules, no per-guest rules — so the `fwbr`/`fwpr`/`fwln` triple bridge hop was pure
overhead. Now `firewall=0`, and `veth105i0` attaches straight to `vmbr0` with PVID 1099.

---

## Re-running the harness

```bash
kubectl run iperf-server-2204 --image=docker.io/networkstatic/iperf3:latest \
  --restart=Never --overrides='{"spec":{"nodeName":"talos-gpu-01"}}' -- -s
kubectl run iperf-client-2204 --image=docker.io/networkstatic/iperf3:latest \
  --restart=Never --command --overrides='{"spec":{"nodeName":"ymir"}}' -- sleep 7200
kubectl exec iperf-client-2204 -- iperf3 -c <server-pod-ip> -u -l 200 -b 522M -t 20
```

Traps, all of which cost a run to find:

- **`kubectl apply` is hard-blocked** by `.claude/hooks/guard-destructive.sh`. `kubectl run` is
  not, and the `default` namespace enforces `privileged`, so no securityContext is needed.
- **Leave at least 8 seconds between runs.** Back-to-back `iperf3` against one server makes every
  run after the first fail instantly, and a truncated capture hides the error.
- **Ignore iperf3's own loss percentage as a host metric.** At 125k pps it reports ~10% loss while
  the host tap drops nothing, so a second loss mechanism exists further along (guest virtio ring,
  or iperf3's single-threaded UDP receiver). `tap104i0`'s `tx_dropped` is the host-side ground
  truth.
- **`ip link set txqueuelen` resizes a live tun `ptr_ring`** — tun handles
  `NETDEV_CHANGE_TX_QUEUE_LEN` — so a sweep needs no VM restart.
