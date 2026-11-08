# ansible/ — host configuration

This directory holds everything in the house that has an _operating system_ needing configuration: the Proxmox
host `pantheon`, TrueNAS `atlas`, the Forgejo LXC, the Mikrotik CRS309.

Flux cannot see this directory. The root Kustomization is scoped to
`./kubernetes/apps`. Flux never reconciles anything here into the cluster.

## What does NOT belong here

- Talos nodes. Talos is immutable and API-driven, with no SSH and no package manager. Its
  machine config is already the declarative state. Use `just talos render-config`.
- Anything inside Kubernetes. Flux owns that.
- Restore drills and runbooks. Those are interactive, branching procedures. They stay
  as `just` recipes and `.agents/skills/`.

## Usage

Playbooks: `atlas` (TrueNAS), `pantheon` (Proxmox host), `forgejo` (the Forgejo LXC),
`grimoire` (macOS workstation), `ucg-max` (Tailscale subnet router on the UniFi gateway,
not applied yet). `crs309` is in the inventory but has no playbook yet.

```bash
just ansible deps               # install pinned Galaxy collections
just ansible playbooks          # list playbooks
just ansible lint
just ansible syntax-check
just ansible check <playbook>   # --check --diff, changes nothing
just ansible apply <playbook>   # prompts for confirmation
```

Always run `check` before `apply`. Modules without check-mode support skip or report inaccurately. A clean check run is a strong hint, but it is not proof.

A `[confirm]` prompt gates `apply`. `just --yes ansible apply <playbook>` bypasses it for
a non-interactive run.

Run these commands in a real terminal. Ansible refuses non-blocking stdio, and some non-interactive
paths (notably the `!` prefix of Claude Code) provide exactly that. The run then dies with
`ERROR: Ansible requires blocking IO`. It can die _after_ it changes the host and without
firing its handlers. If you must run it that way, redirect to a file (`> out 2>&1`). Treat
that error as a partial apply, not a no-op.

## Secrets

Secrets come from 1Password through the `community.general.onepassword` lookup. Pass vault,
item and field separately, not as an `op://` URI:

```yaml
forgejo_runner_token: "{{ lookup('community.general.onepassword',
    'forgejo', field='RUNNER_TOKEN', vault='artemis') }}"
```

The `op://vault/item/field` URI form fails under a service-account token with
`'vault' is required with 'service_account_token'`. It works only in an interactive session.
Laptop runs are exactly the service-account case, so the URI form is broken in the common
path. (This file documented the URI form until 2026-09-07.)

Recipes run under `op run`, so a service-account token or an active `op` session is
required. Do not introduce ansible-vault or SOPS. This repo deliberately has exactly
one secrets system. Put `no_log: true` on tasks that consume secrets.

Vaults are split by blast radius, not by tool. Host secrets that a cluster compromise must
not reach go in `infrastructure`, not `artemis`. The in-cluster 1Password Connect token can read the `artemis` vault.

## Apply by hand, not from CI

Ansible is push-based and non-transactional. A half-applied run against the only
hypervisor in the house leaves an undefined state with no reconcile loop to heal it. Flux
can apply continuously because Kubernetes self-heals. Bare metal does not.

CI lints, syntax-checks, and resolves collections. A human applies from the laptop.

## Collections

`requirements.yml` pins the collections. The `proxmox_*` modules were split out of
`community.general` into `community.proxmox`. The old paths are deprecated redirects,
so write new code against `community.proxmox`.

`collections/` is gitignored. `requirements.yml` is the tracked source of truth.
