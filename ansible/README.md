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

## Secrets

Secrets come from 1Password via the `community.general.onepassword` lookup, which accepts
full secret references:

```yaml
forgejo_runner_token: "{{ lookup('community.general.onepassword',
    'op://artemis/forgejo/RUNNER_TOKEN') }}"
```

Recipes run under `op run`, so a service-account token or an active `op` session is
required. **Do not introduce ansible-vault or SOPS** — this repo deliberately has exactly
one secrets system. Put `no_log: true` on tasks that consume secrets.

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
