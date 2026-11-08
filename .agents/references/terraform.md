# OpenTofu — Artemis-Cluster

This file covers the `terraform/` tree. It holds everything in the house that has an API and _creates objects_.
`terraform/README.md` covers operational usage. This file carries the reasoning, the
provider choices, and the traps.

## The ownership boundary

> Tofu owns everything up to and including the Talos VM.
> Flux owns everything inside the cluster.
> Ansible owns the mutable Linux boxes that are not Talos.

Every failure mode that people reported with this layout comes from two tools that own one
object. Flux reconciles continuously. Tofu reconciles only when someone runs it. An object that both own
drifts forever: Flux reverts it, the next tofu plan shows the diff, and the cycle repeats.

Never add the `kubernetes` or `helm` providers. They cause the double-ownership problem.
Also, `kubernetes_manifest` needs a live API server at _plan_ time. Plans then break exactly when
the cluster is down, which is when you most need to reason about the infrastructure
underneath it.

## Why OpenTofu and not Terraform

OpenTofu uses the MPL-2.0 license, not BUSL. It also has native state and plan encryption. Terraform does not have this, and this repo depends on it. Every provider below resolves on `search.opentofu.org`.

## Provider choices, and why

| Target   | Provider                      | Notes                                                   |
| -------- | ----------------------------- | ------------------------------------------------------- |
| Proxmox  | `bpg/proxmox`                 | The maintained one. **Not `Telmate/proxmox`** — legacy. |
| UniFi    | `ubiquiti-community/unifi`    | See below — the original is archived.                   |
| RouterOS | `terraform-routeros/routeros` | The CRS309, stack `mikrotik`. Read the traps first.     |
| TrueNAS  | `truenas/truenas`             | Official. Read the traps first.                         |

### UniFi — the provider situation

`paultyng/terraform-provider-unifi` (581★) is archived and read-only. Two live forks
exist, and they are not interchangeable:

- `ubiquiti-community/unifi`: Owned by an org. It continues the v0.41.x lineage, so it is a
  drop-in for existing paultyng state. It exposes `firewall_zone` and `firewall_policy`, and
  it alone exposes `bgp`, `wan`, `traffic_route`, `vpn_*`, and `wireguard_peer`.
- `filipowm/unifi`: One maintainer owns it. It rebased to a v1.x with an incompatible schema.
  It has more typed `setting_*` singletons, but no BGP, WAN, or traffic routes.

We use `ubiquiti-community` because of the bus factor and the broader UCG-Max surface.

### Proxmox — when SSH is actually needed

The provider is API-first. SSH is required _only_ for uploading snippets, certain file
content types, importing a disk through `source_file.path`, and container `idmap` entries.
VM/LXC CRUD, storage, pools, users, and `download_file` are all pure API.

Talos does not use cloud-init, so you can avoid the snippet path, and therefore SSH,
entirely. Use `proxmox_virtual_environment_download_file` to pull the Talos image, then
`..._vm`. Machine config does not belong to tofu. It comes from `just talos` plus the node templates.

GPU passthrough (`hostpci`) works, but any change force-stops the VM. Raw PCI IDs are
better covered than the newer resource-mapping style.

## State — committed to this repo, always encrypted

State lives in git, next to the stack that owns it
(`terraform/stacks/<name>/terraform.tfstate`). It is encrypted with the native
state encryption of OpenTofu (`aes_gcm` keyed by `pbkdf2`, 600k iterations, sha512).

Why the state is in the repo and not on a share: The team considered an NFS
dataset on `atlas` and rejected it. `backend "local"` cannot tell "the state
file is missing" from "the mount is not there". If the NFS mount drops (and WSL2 does
not remount reliably across restarts), tofu silently writes a _fresh empty state_ into
the empty mountpoint. The next apply then tries to rebuild infrastructure that already
exists. Git has no equivalent silent-failure mode. The file is either in the working
tree or it is not, and git says which.

Git also supplies the things that the team wanted from the share. It keeps off-machine copies (Forgejo),
precise history (`git log` on the state file), and rollback (`git checkout <sha>`).

Why the state is not in the cluster: Tofu creates the Talos VMs. The storage of the cluster runs on
those VMs. The cluster would then hold the state that describes them. If the cluster dies, you cannot plan a
rebuild. The same circularity applies to the shared CNPG Postgres through the `pg` backend.

### How the passphrase gets in

`terraform/mod.just` reads the passphrase from 1Password at run time and builds `TF_ENCRYPTION`
in the environment. It never writes the passphrase to a file. It never passes it through the
`onepassword` provider. Providers initialise _after_ the encryption block is
evaluated, so that route would store the state key inside the state that it encrypts.

Override the reference with `TOFU_PASSPHRASE_REF`, or the literal value with
`TOFU_PASSPHRASE` (used to test the mechanism without touching 1Password).
The recipes refuse to run on a passphrase shorter than 16 characters.

Vault placement: The reference points at `op://infrastructure/tofu-state/password`.
`infrastructure` is in the read set of the in-cluster Connect token. See the vault order in
`clustersecretstore.yaml`. A cluster compromise still reaches the
passphrase that decrypts the state that describes the hypervisor that the cluster runs on. Moving the
passphrase out of any cluster-readable vault is still owed
([#2760](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2760)). It is a one-line change here,
because the reference is a variable and not a hardcoded path.

Vaults are split by blast radius (who can read it), not by tool. A shared
`ansible` / `terraform` split would duplicate credentials like the Proxmox token, and
duplicates drift.

If you lose the passphrase, every state file is unrecoverable. Keep it in a second
vault. There is no recovery path. The ciphertext is all there is.

### The guard that makes this safe

Committing state is only safe while it is ciphertext. For this reason,
`hooks/tfstate_encrypted.py` runs as a pre-commit hook on every staged `*.tfstate`
and refuses plaintext. It passes only on a document that has a non-empty
`encrypted_data` key, so an unrecognised shape fails closed. It also rejects an empty file, which is the
signature of a backend path that pointed somewhere wrong.

This matters because `just tofu ...` sets `TF_ENCRYPTION` but a bare `tofu apply`
does not. The team tested both paths. The recipe produces ciphertext, a bare apply
produces plaintext, and the hook catches the second.

`.gitignore` deliberately does not ignore `*.tfstate`, because git must track it.
`.sourceignore` excludes `terraform/` so tracked state never ships inside the Flux
OCI artifact to the registry.

### If plaintext state ever gets committed

Treat every credential in it as compromised. Rotate them, then rewrite history to
remove the blob. Do not delete the file in a later commit. It stays in the
object store and in every clone.

## Adopting existing infrastructure

Everything in this house already exists. Every stack is therefore an import exercise,
never a create one.

1. Write the resource block.
2. Run `just tofu import <stack> <address> <id>`.
3. Run `just tofu plan <stack>` until it reports no changes.

A clean plan after import is the only real success signal. If the plan wants to change
something you did not intend, the resource block is wrong. Fix it and do not apply.

## Traps

- UniFi can lock you out. A bad firewall apply severs the path you are applying over.
  Plan first, every time, and keep a console or recovery route.
- `unifi_user` churn: UniFi auto-creates a user object for every client that has ever
  associated, and keeps mutating it (hostname, note, last-seen). Managing DHCP
  reservations this way produces perpetual diffs. `allow_existing = true` and
  `skip_forget_on_destroy = true` are effectively mandatory.
- The UniFi site ID is the short hex slug, not `Default`. If you use the wrong value, the provider silently
  targets the wrong site.
- Do not manage DNS records here. external-dns owns them: `external-dns-unifi` for the
  LAN, and `external-dns-cloudflare` / `external-dns-edge` / `external-dns-frostlink` for
  Cloudflare (`networking.md` § External DNS). One owner per record set.
- BGP is deliberately out of scope. The `ubiquiti-community` provider can manage
  AS 64533, but the whole cluster network rides on that peering. It stays manual.
- TrueNAS dataset `type` and `compression` are case-sensitive, and `type` is ForceNew.
  The examples of the official provider say `"FILESYSTEM"` / `"LZ4"`. atlas reads back
  `"filesystem"` / `"lz4"` (imported on 25.04, still lowercase on 25.10). The uppercase
  spelling plans a destroy and recreate of every dataset. Use lowercase, and never apply on
  a plan that proposes a replacement.
- TrueNAS uses HTTPS on port 1443, not 443. It sets `ui_httpsport = 1443` with plain HTTP on
  80, so the endpoint is `wss://10.10.99.100:1443/api/current`. Port 443 is refused.
- The OpenTofu registry has no GPG key for `truenas/truenas`, so `init` installs it
  with signature validation skipped. The Terraform registry does verify it. For that reason, `versions.tf` pins the version
  exactly. `terraform-routeros/routeros` is
  in the same position and is pinned the same way.
- RouterOS needs api-ssl with a real certificate. The CRS309 shipped with
  `certificate=none`. A self-signed cert fails with `CA not found`. It needs a local CA
  (`tofu-ca`) that signs the server cert (`tofu-api`). Keep both out of the stack.
- RouterOS `/ip service` cannot be imported on 7.20. The provider keys it by name,
  and each live ssh/winbox session appears as another row with the same name.
- Do not manage RouterOS `/system clock`. Its generated resource pins the literal
  date and time, so an apply winds the clock back.
- RouterOS `/interface ethernet` always plans an in-place update after import, because
  `factory_name` is required and import cannot fill it. That update re-sends every port
  setting. Do not do that to sfp1 (UCG uplink) or sfp8 (pantheon) in daytime.

## Renovate

The `terraform` manager is scoped to `terraform/**/*.tf` in `.renovaterc.json5`.
Provider updates are explicitly not automerged, because they change real hardware. This
matters because the inherited `home-operations` preset sets no `enabledManagers` and
extends `config:recommended`, so every manager is on by default.
