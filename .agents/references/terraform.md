# OpenTofu — Artemis-Cluster

The `terraform/` tree. Everything in the house that has an API and _creates objects_.
Operational usage lives in `terraform/README.md`; this file carries the reasoning, the
provider choices, and the traps.

## The ownership boundary

> Tofu owns everything up to and including the Talos VM.
> Flux owns everything inside the cluster.
> Ansible owns the mutable Linux boxes that aren't Talos.

Every failure mode reported by people running this layout comes from two tools owning one
object. Flux reconciles continuously; tofu reconciles only when run. An object owned by
both drifts forever — Flux reverts, tofu's next plan shows the diff, repeat.

**Never add the `kubernetes` or `helm` providers.** Beyond the double-ownership problem,
`kubernetes_manifest` needs a live API server at _plan_ time, so plans break exactly when
the cluster is down — which is when you most need to reason about the infrastructure
underneath it.

## Why OpenTofu and not Terraform

MPL-2.0 rather than BUSL, and native state/plan encryption, which Terraform does not have
and which this repo depends on. Every provider below resolves on `search.opentofu.org`.

## Provider choices, and why

| Target     | Provider                      | Notes                                                   |
| ---------- | ----------------------------- | ------------------------------------------------------- |
| Proxmox    | `bpg/proxmox`                 | The maintained one. **Not `Telmate/proxmox`** — legacy. |
| Talos      | `siderolabs/talos`            | Official. Machine secrets, config apply, kubeconfig.    |
| UniFi      | `ubiquiti-community/unifi`    | See below — the original is archived.                   |
| Cloudflare | `cloudflare/cloudflare` v5    | v4 is EOL. Tunnels and Zero Trust only.                 |
| 1Password  | `1Password/onepassword`       | Read-only data sources.                                 |
| RouterOS   | `terraform-routeros/routeros` | Optional, for the CRS309.                               |

### UniFi — the provider situation

`paultyng/terraform-provider-unifi` (581★) is **archived** and read-only. Two live forks
exist and they are not interchangeable:

- **`ubiquiti-community/unifi`** — org-owned, continues the v0.41.x lineage (so it is a
  drop-in for existing paultyng state). Exposes `firewall_zone`, `firewall_policy`, and
  uniquely `bgp`, `wan`, `traffic_route`, `vpn_*`, `wireguard_peer`.
- **`filipowm/unifi`** — single maintainer, rebased to a v1.x with **incompatible schema**.
  More typed `setting_*` singletons, but no BGP, WAN, or traffic routes.

**We use `ubiquiti-community`** for the bus factor and the broader UCG-Max surface.

### Proxmox — when SSH is actually needed

The provider is API-first. SSH is required _only_ for uploading snippets, certain file
content types, importing a disk via `source_file.path`, and container `idmap` entries.
VM/LXC CRUD, storage, pools, users, and `download_file` are all pure API.

Talos does not use cloud-init, so the snippet path — and therefore SSH — is avoidable
entirely. Use `proxmox_virtual_environment_download_file` to pull the Talos image, then
`..._vm`, then hand off to the `siderolabs/talos` provider.

GPU passthrough (`hostpci`) works, but any change force-stops the VM, and raw PCI IDs are
better covered than the newer resource-mapping style.

## State

`local` backend, on a dataset on `atlas` (TrueNAS), mounted over NFS.

**Why not in the cluster:** tofu creates the Talos VMs → Talos runs Ceph → Ceph would hold
the state describing those VMs. The cluster dies and you cannot plan a rebuild. The same
circularity applies to the shared CNPG Postgres via the `pg` backend. `atlas` is not
managed by tofu, so it breaks the cycle.

**Encryption is mandatory.** Native OpenTofu state encryption (`aes_gcm` + `pbkdf2`) over
state _and_ plan files. The passphrase is supplied from 1Password _outside_ tofu, via
`op run` and `TF_VAR_state_passphrase` — never through the `onepassword` provider, because
providers initialise **after** the encryption block is evaluated, which would store the
state key inside the state it encrypts.

Losing the passphrase makes the state unrecoverable. It lives in two vaults.
History and rollback come from ZFS snapshots of the dataset.

## Adopting existing infrastructure

Everything in this house already exists. Every stack is therefore an **import** exercise,
never a create one.

1. Write the resource block.
2. `just tofu import <stack> <address> <id>`.
3. `just tofu plan <stack>` until it reports **no changes**.

A clean plan after import is the only real success signal. If the plan wants to change
something you did not intend, the resource block is wrong — fix it, do not apply.

## Traps

- **UniFi can lock you out.** A bad firewall apply severs the path you are applying over.
  Plan first, every time, and keep a console or recovery route.
- **`unifi_user` churn.** UniFi auto-creates a user object for every client that has ever
  associated, and keeps mutating it (hostname, note, last-seen). Managing DHCP
  reservations this way produces perpetual diffs. `allow_existing = true` and
  `skip_forget_on_destroy = true` are effectively mandatory.
- **UniFi site ID** is the short hex slug, not `Default`. Getting it wrong silently
  targets the wrong site.
- **Do not manage DNS records in Cloudflare.** `external-dns-unifi` already owns them.
  One owner per record set.
- **BGP is deliberately out of scope.** The `ubiquiti-community` provider can manage
  AS 64533, but that peering is what the whole cluster network rides on. Left manual.
- **TrueNAS has no usable provider.** The only maintained one cannot manage NFS shares —
  the entire reason to touch `atlas`. Use Ansible; see `.agents/references/ansible.md`.

## Renovate

The `terraform` manager is scoped to `terraform/**/*.tf` in `.renovaterc.json5`, and
provider updates are explicitly **not** automerged — they change real hardware. This
matters because the inherited `home-operations` preset sets no `enabledManagers` and
extends `config:recommended`, so every manager is on by default.
