# terraform/ — OpenTofu

This directory holds everything in the house that has an API and _creates objects_: Proxmox VMs and LXCs,
UniFi networks, Cloudflare tunnels, TrueNAS datasets and shares.

Flux cannot see this directory. The root Kustomization is scoped to
`./kubernetes/apps`. Flux never reconciles anything here into the cluster.

## The ownership rule

> Tofu owns everything up to and including the Talos VM.
> Flux owns everything inside the cluster.
> Ansible owns the mutable Linux boxes that are not Talos.

Never let two tools own the same object. Every reported failure with this
layout comes from that.

## Layout

```text
modules/          shared reusable modules
stacks/<name>/    one stack per blast radius, each with its own state
```

Each stack has separate state. A UniFi mistake cannot corrupt Proxmox state, and a DNS
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
`TF_ENCRYPTION`. To test without 1Password, set `TOFU_PASSPHRASE` directly. To point
at a different item, set `TOFU_PASSPHRASE_REF`.

## State

The repo contains the state, encrypted with the native state
encryption of OpenTofu. `terraform/stacks/<name>/terraform.tfstate` is a tracked file and is
always ciphertext.

`terraform/mod.just` reads the passphrase from 1Password at run time and
injects it as `TF_ENCRYPTION`. The passphrase never lands in a file.

A pre-commit hook (`hooks/tfstate_encrypted.py`) refuses to commit plaintext state.
`just tofu ...` sets up encryption. A bare `tofu apply` does not. Use the
recipes, and the hook catches the mistake if you forget.

If you lose the passphrase, every state file is unrecoverable. The passphrase lives in two vaults.

The full reasoning, including why the team rejected an NFS share on `atlas`, is in
`.agents/references/terraform.md`.

## Adding a stack

1. Run `mkdir stacks/<name>` and write `main.tf`, `providers.tf`, `versions.tf`.
2. Declare `backend "local" {}`. State lands beside the stack and is committed.
3. Import existing objects. Do not create them. Success is `tofu plan` reporting no changes.
4. Add the stack to the rollout notes in `.agents/references/terraform.md`.

## Warning: UniFi

Always plan first, and keep a console or recovery path available. A bad firewall apply can sever the network path you are applying over and lock you out of
your own network.
