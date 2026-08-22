# terraform/ — OpenTofu

Everything in the house that has an API and _creates objects_: Proxmox VMs and LXCs,
UniFi networks, Cloudflare tunnels.

**This directory is invisible to Flux.** The root Kustomization is scoped to
`./kubernetes/apps`. Nothing here is ever reconciled into the cluster.

## The ownership rule

> Tofu owns everything up to and including the Talos VM.
> Flux owns everything inside the cluster.
> Ansible owns the mutable Linux boxes that aren't Talos.

Never let two tools own the same object. That is where every reported failure with this
layout comes from.

## Layout

```text
modules/          shared reusable modules
stacks/<name>/    one stack per blast radius, each with its own state
```

Separate state per stack means a UniFi mistake cannot corrupt Proxmox state, and a DNS
change does not refresh every provider in the house.

## Usage

```bash
just tofu stacks              # list stacks
just tofu init <stack>
just tofu plan <stack>        # always, before apply
just tofu apply <stack>       # prompts for confirmation
just tofu import <stack> <address> <id>
just tofu fmt
```

Every recipe runs under `op run`, so `op://` references in the environment resolve from
1Password. The state-encryption passphrase is passed as `TF_VAR_state_passphrase` and is
declared in `terraform/mod.just`.

## State

State lives on a dataset on `atlas` (TrueNAS), mounted over NFS, using the `local`
backend. `atlas` is deliberately **not** managed by tofu — so if the cluster or `pantheon`
is down, state is still readable and a rebuild can still be planned.

State is encrypted at rest with OpenTofu's native state encryption (`aes_gcm` + `pbkdf2`),
covering both state and plan files. The passphrase comes from 1Password _outside_ tofu —
never via the `onepassword` provider, because providers initialise after the encryption
block is evaluated.

**Losing the passphrase means the state is unrecoverable.** It is backed up in two vaults.

History and rollback come from ZFS snapshots of the dataset.

## Adding a stack

1. `mkdir stacks/<name>` and write `main.tf`, `providers.tf`, `versions.tf`
2. Point the backend at `/mnt/atlas/tofu-state/<name>/terraform.tfstate`
3. **Import existing objects — do not create.** Success is `tofu plan` reporting no changes.
4. Add the stack to the rollout notes in `.agents/references/terraform.md`

## Warning: UniFi

A bad firewall apply can sever the network path you are applying over and lock you out of
your own network. Always plan first, and keep a console or recovery path available.
