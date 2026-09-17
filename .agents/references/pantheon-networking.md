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
1154 exist nowhere on the network**. Trimmed to `1099,1152` on 2026-09-17, which is exactly what
the three VM taps trunk.

The authoritative list, when this needs rechecking:

```bash
curl -sk -H "X-API-KEY: $(op read op://artemis/unifi/UNIFI_API_KEY)" \
  https://10.10.99.1/proxy/network/api/s/default/rest/networkconf
```

1062 (CAM) is deliberately absent: frigate pins to `node.kubernetes.io/gpu-tier: gen95`, which is
`ymir` — bare metal, not a pantheon guest.

### The `cam` NAD cannot work on a pantheon VM

`talos/cluster.yaml.j2` gives **every** Talos node a `bond0.1062` VLAN interface, and the `cam`
NetworkAttachmentDefinition masters its macvlan on it. On the three pantheon VMs that interface
can never carry traffic: their tap devices trunk only `1099;1152` (`trunks=1099;1152` in the
qemu-server config), and `vmbr0` no longer allows 1062 on any port. `talos-gpu-01`'s
`bond0.1062` confirms it — 0 RX packets, 51 TX.

So a pod attached to `cam` that schedules onto `talos-w-01`, `talos-w-02` or `talos-gpu-01` gets
an interface that silently receives nothing, with no error anywhere. Today the only consumer is
frigate, which pins to `node.kubernetes.io/gpu-tier: gen95` — a label only `ymir` carries — so it
always lands on metal and the trap stays latent.

Do not "fix" this by adding 1062 to the pantheon trunk. That pulls camera traffic onto the host
bridge for no benefit. If a second `cam` consumer ever appears, pin it to `ymir` too.

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
