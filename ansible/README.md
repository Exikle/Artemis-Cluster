# ansible/ — host configuration

Everything in the house that has an _operating system_ needing configuration: the Proxmox
host `pantheon`, TrueNAS `atlas`, the Forgejo LXC, the Mikrotik CRS309.

**This directory is invisible to Flux.** The root Kustomization is scoped to
`./kubernetes/apps`. Nothing here is ever reconciled into the cluster.

## What does NOT belong here

- **Talos nodes.** Talos is immutable and API-driven — no SSH, no package manager. Its
  machine config is already the declarative state. Use `just talos render-config`.
- **Anything inside Kubernetes.** Flux owns that.
- **Restore drills and runbooks.** Those are interactive, branching procedures. They stay
  as `just` recipes and `.agents/skills/`.

## Usage

Playbooks: `atlas` (TrueNAS), `pantheon` (Proxmox host), `forgejo` (the Forgejo LXC),
`grimoire` (macOS workstation). `crs309` is in the inventory but has no playbook yet.

```bash
just ansible deps               # install pinned Galaxy collections
just ansible playbooks          # list playbooks
just ansible lint
just ansible syntax-check
just ansible check <playbook>   # --check --diff, changes nothing
just ansible apply <playbook>   # prompts for confirmation
```

**Always `check` before `apply`.** One caveat: modules without check-mode support will
skip or report inaccurately, so a clean check run is not proof — it is a strong hint.

`apply` is gated by a `[confirm]` prompt; `just --yes ansible apply <playbook>` bypasses it for
a non-interactive run.

**Run these in a real terminal.** Ansible refuses non-blocking stdio, and some non-interactive
paths (notably Claude Code's `!` prefix) provide exactly that — the run dies with
`ERROR: Ansible requires blocking IO`, but it can do so _after_ changing the host and without
firing its handlers. Redirect to a file (`> out 2>&1`) if you must run it that way, and treat
that error as a partial apply rather than a no-op.

## Secrets

Secrets come from 1Password via the `community.general.onepassword` lookup. **Pass vault,
item and field separately — not as an `op://` URI:**

```yaml
forgejo_runner_token: "{{ lookup('community.general.onepassword',
    'forgejo', field='RUNNER_TOKEN', vault='artemis') }}"
```

The `op://vault/item/field` URI form **fails under a service-account token** with
`'vault' is required with 'service_account_token'`. It works only in an interactive session,
and laptop runs are exactly the service-account case, so the URI form is broken in the common
path. (This file documented the URI form until 2026-09-07.)

Recipes run under `op run`, so a service-account token or an active `op` session is
required. **Do not introduce ansible-vault or SOPS** — this repo deliberately has exactly
one secrets system. Put `no_log: true` on tasks that consume secrets.

Vaults are split by **blast radius**, not by tool. Host secrets that a cluster compromise must
not reach go in `infrastructure`, not `artemis` — the `artemis` vault is readable by the
in-cluster 1Password Connect token.

## Apply by hand, not from CI

Ansible is push-based and non-transactional. A half-applied run against the only
hypervisor in the house leaves an undefined state with no reconcile loop to heal it. Flux
gets away with continuous apply because Kubernetes self-heals; bare metal does not.

CI lints, syntax-checks, and resolves collections. Applying is a human, from the laptop.

## Collections

Pinned in `requirements.yml`. Note that the `proxmox_*` modules were **split out of
`community.general`** into `community.proxmox` — the old paths are deprecated redirects,
so write new code against `community.proxmox`.

`collections/` is gitignored; `requirements.yml` is the tracked source of truth.
