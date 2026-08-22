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

Every recipe reads the state-encryption passphrase from 1Password and injects it as
`TF_ENCRYPTION`. For testing without 1Password, set `TOFU_PASSPHRASE` directly; to point
at a different item, set `TOFU_PASSPHRASE_REF`.

## State

State is **committed to this repo**, encrypted with OpenTofu's native state
encryption. `terraform/stacks/<name>/terraform.tfstate` is a tracked file and is
always ciphertext.

The passphrase is read from 1Password at run time by `terraform/mod.just` and
injected as `TF_ENCRYPTION`. It never lands in a file.

A pre-commit hook (`hooks/tfstate_encrypted.py`) refuses to commit plaintext state.
`just tofu ...` sets up encryption; a bare `tofu apply` does **not** — so use the
recipes, and trust the hook to catch it when you forget.

**Losing the passphrase makes every state file unrecoverable.** It lives in two vaults.

Full reasoning, including why an NFS share on `atlas` was rejected:
`.agents/references/terraform.md`.

## Adding a stack

1. `mkdir stacks/<name>` and write `main.tf`, `providers.tf`, `versions.tf`
2. Declare `backend "local" {}` — state lands beside the stack and is committed
3. **Import existing objects — do not create.** Success is `tofu plan` reporting no changes.
4. Add the stack to the rollout notes in `.agents/references/terraform.md`

## Warning: UniFi

A bad firewall apply can sever the network path you are applying over and lock you out of
your own network. Always plan first, and keep a console or recovery path available.
