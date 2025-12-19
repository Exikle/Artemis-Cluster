# Artemis Homelab: DHCP & DNS Architecture

This document describes the current DHCP/DNS architecture for the Artemis homelab and serves as a runbook-style reference for:

- Migrating DHCP from Pi-hole v6 to MikroTik
- Introducing Technitium DNS as the primary DNS platform
- Planning a secondary Technitium instance on the Raspberry Pi (ex‑Pi‑hole)

---

## 1. Network Overview

### 1.1 VLANs and Gateways

All user VLANs are /24s with `.1` as the default gateway on the MikroTik L3 router.

| VLAN | ID   | Subnet           | Gateway     | Purpose        |
|------|------|------------------|-------------|----------------|
| LAN  | 1    | 192.168.1.0/24   | 192.168.1.1 | General LAN    |
| LAB  | 1099 | 10.10.99.0/24    | 10.10.99.1  | Lab / K8s      |
| GST  | 1151 | 10.10.151.0/24   | 10.10.151.1 | Guest          |
| HME  | 1001 | 10.10.1.0/24     | 10.10.1.1   | Home devices   |
| IOT  | 1152 | 10.10.152.0/24   | 10.10.152.1 | IoT devices    |
| TST  | 1088 | 192.168.88.0/24  | 192.168.88.1| Test / misc    |

### 1.2 Key IPs

- **MikroTik router (per VLAN gateways)**
  - HME: `10.10.1.1`
  - LAB: `10.10.99.1`
  - GST: `10.10.151.1`
  - IOT: `10.10.152.1`
  - LAN: `192.168.1.1`
  - TST: `192.168.88.1`

- **DNS / infra (LAB VLAN)**
  - Pi‑hole v6: `10.10.99.2`
  - Technitium (primary, LXC): `10.10.99.3`
  - K8s ingress: `10.10.99.97`
  - Cilium/CoreDNS VIP: `10.10.99.99`

- **LAB static infrastructure** (DHCP reservations on MikroTik)
  - UniFi CloudKey: `10.10.99.4`
  - MikroTik itself: `10.10.99.7`
  - TrueNAS: `10.10.99.100`
  - Talos CPs: `10.10.99.101–103`
  - Talos workers: `10.10.99.201–202`

---

## 2. DHCP Migration: Pi‑hole → MikroTik

### 2.1 Previous State (Pi‑hole v6)

Pi‑hole v6 ran both DNS and DHCP, using `dnsmasq`-style configs in `/etc/dnsmasq.d/02-pihole-vlans.conf` and TOML in `/etc/pihole/pihole.toml`.

- Each VLAN had a `dhcp-range=set:<TAG>,...` with 24h leases.
- `pihole.toml` enabled embedded DHCP (`dhcp.active = true`).

### 2.2 Target State (MikroTik)

MikroTik now provides DHCP for all VLANs; Pi‑hole runs **DNS only**.

**Per-VLAN DHCP pools on MikroTik:**

| VLAN | DHCP Server | Pool Name  | Range                      | Lease Time |
|------|-------------|-----------|----------------------------|-----------|
| LAB  | `dhcp-LAB`  | `pool-LAB`| 10.10.99.50–10.10.99.70    | 1d        |
| LAN  | `dhcp-LAN`  | `pool-LAN`| 192.168.1.50–192.168.1.200 | 1d        |
| GST  | `dhcp-GST`  | `pool-GST`| 10.10.151.50–10.10.151.200 | 8h        |
| HME  | `dhcp-HME`  | `pool-HME`| 10.10.1.50–10.10.1.200     | 1d        |
| IOT  | `dhcp-IOT`  | `pool-IOT`| 10.10.152.50–10.10.152.200 | 1d        |
| TST  | `dhcp-TST`  | `pool-TST`| 192.168.88.50–192.168.88.200 | 12h     |

**DHCP network entries (MikroTik → IP → DHCP Server → Networks):**

For each subnet:

- `Address`: `<subnet>/24`
- `Gateway`: VLAN `.1` IP
- `DNS Servers`: Currently Technitium (`.3`) + Pi‑hole (`.2`)
- `Domain`: `dcunha.lab`

**Security-related settings (per DHCP server):**

- `Authoritative = yes`
- `Add ARP For Leases = yes`
- `Always Broadcast = no`

### 2.3 Migration Procedure (Per VLAN)

1. **Disable Pi‑hole DHCP**: Comment out the VLAN's `dhcp-range` in `/etc/dnsmasq.d/02-pihole-vlans.conf` and restart FTL (`sudo systemctl restart pihole-FTL`).
2. **Enable MikroTik DHCP**: Ensure the corresponding DHCP server is active.
3. **Test**: Release/renew on a client to verify lease acquisition from MikroTik.

Once all VLANs are migrated:

- Disable DHCP globally in Pi‑hole: `sudo pihole-FTL --config dhcp.active false`.

---

## 3. Technitium DNS: Primary Deployment (LXC)

Technitium DNS is the primary authoritative DNS server for local zones.

### 3.1 LXC & Network

- **Host**: Proxmox
- **Container**: Unprivileged LXC
- **Primary IP**: `10.10.99.3/24` (Gateway: `10.10.99.1`)

### 3.2 Technitium Configuration

- **Web UI**: `http://10.10.99.3:5380/`
- **General**: Domain `dns.dcunha.io`
- **Forwarders**: `1.1.1.1`, `1.0.0.1`
- **Blocking**: Standard block lists (OISD, StevenBlack) enabled.

### 3.3 Local Zones

#### `dcunha.lab` (Primary Zone)

Contains A records for all infrastructure:

- `unifi` → `10.10.99.4`
- `router` → `10.10.99.7`
- `nas` → `10.10.99.100`
- `talos-cp-01..03` → `10.10.99.101..103`
- `ingress` → `10.10.99.97`

#### `dcunha.io` (Internal Override)

- Records: `@` and `*` point to `10.10.99.97` (ingress).

#### Kubernetes Internal Domains

Two conditional forwarder zones pointing to Cilium VIP (`10.10.99.99`):

- `cluster.local`
- `svc.cluster.local`

---

## 4. Future Work: Secondary Technitium on Raspberry Pi

The Raspberry Pi currently running Pi‑hole will become a secondary DNS server.

### 4.1 Deployment Steps

1. **Wipe Pi**: `pihole uninstall` and clean directories.
2. **Install Technitium**: `curl -sSL https://download.technitium.com/dns/install.sh | sudo bash`
3. **Configure Secondary Zones**:
   - Create `dcunha.lab` as a **Secondary Zone**.
   - Point to Primary Master: `10.10.99.3`.
4. **Enable Zone Transfers on Primary**:
   - Allow zone transfers to `10.10.99.2` in Zone Options.
5. **Update MikroTik**:
   - Set DHCP DNS Servers to `10.10.99.3, 10.10.99.2`.

---

## 5. Quick Reference

- **Technitium Install**: `curl -sSL https://download.technitium.com/dns/install.sh | sudo bash`
- **Restart Pi‑hole**: `sudo systemctl restart pihole-FTL`
- **Disable Pi‑hole DHCP**: `sudo pihole-FTL --config dhcp.active false`
