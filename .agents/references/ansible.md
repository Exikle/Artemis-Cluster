# Ansible — Artemis-Cluster

The `ansible/` tree. Everything in the house that has an _operating system_ needing
configuration. Operational usage lives in `ansible/README.md`; this file carries the
reasoning and the traps.

## Scope — what belongs here

| Host                      | What Ansible owns                                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `pantheon` (10.10.99.104) | Proxmox host OS: apt, sysctl, IOMMU/vfio, ZFS dataset properties, NUT, node_exporter, SSH hardening, `ssacli` |
| `atlas` (10.10.99.100)    | TrueNAS: datasets, NFS/SMB shares, users, snapshot and scrub tasks, SMART                                     |
| `forgejo` (10.10.99.24)   | Forgejo LXC: release binary, `app.ini`, systemd unit, runner registration                                     |
| `crs309` (172.16.99.2)    | Mikrotik switch: config export, backups, firewall                                                             |

## What does NOT belong here

- **Talos nodes.** No SSH, no package manager, no Python interpreter. There is no
  `siderolabs` Ansible collection; what people build are `command:` wrappers around
  `talosctl`, which is Ansible-as-shell-script with none of Ansible's value. Talos machine
  config **is** the declarative state — `just talos render-config` already does this, and
  it is what the wider home-operations community converged on after dropping Ansible.
- **Anything inside Kubernetes.** Flux owns it.
- **Restore drills and runbooks.** Interactive, branching, human-judgement procedures —
  the opposite of convergent state. They stay as `just` recipes and `.agents/skills/`.
- **Windows / Arcana.** One GUI-managed desktop; WinRM plumbing has negative payback.
- **The WSL2 dev machine.** chezmoi owns dotfiles, mise owns tools. The only genuine gap
  is sudo-level system config (`/etc/wsl.conf`, linuxbrew removal), and a chezmoi
  `run_onchange_before_*.sh` covers that without a third owner of the same box.

## Collections

Pinned in `ansible/requirements.yml`, installed with `just ansible deps` into a gitignored
`ansible/collections/`.

**`community.proxmox` is the current home of the `proxmox_*` modules** — they were split
out of `community.general`, which now keeps deprecated redirects. Write new code against
`community.proxmox`.

**`arensb.truenas` is the only viable TrueNAS collection.** Note how it works: it does
_not_ call the REST API from the control node. It runs on the box over SSH and shells to
`midclt`, so `atlas` needs SSH access. It has no replication-task, cloud-sync, or Apps
modules — snapshot tasks are covered, replication is not.

For the CRS309 use `community.routeros.api_modify` (idempotent), not `command`.

## Secrets

`community.general.onepassword` lookup, which accepts full `op://` references and supports
both service-account tokens and 1Password Connect:

```yaml
forgejo_runner_token: "{{ lookup('community.general.onepassword',
    'op://artemis/forgejo/RUNNER_TOKEN') }}"
```

Service account for laptop runs, Connect for CI. Put `no_log: true` on tasks consuming
secrets. **Never introduce ansible-vault or SOPS** — this repo deliberately runs exactly
one secrets system.

## The netdata.conf chore, solved properly

TrueNAS wipes `/etc/netdata/netdata.conf` on every update, which is why it is listed as a
recurring manual chore in `AGENTS.md`. Re-templating the file loses the race with the next
update.

**The file is `/etc/netdata/exporting.conf`, not `netdata.conf`.** The exporting config is
a `[graphite:prometheus]` block pointing at the `truenas-exporter` LoadBalancer
(`10.10.99.93:9109`); `netdata.conf` itself is stock TrueNAS. An older note in `AGENTS.md`
named the wrong file.

`roles/netdata_exporter` implements the fix: the canonical config and a restore script live
on a dataset (`/mnt/atlas/config/netdata/`) — **they must not live in `/etc`, which is what
the update replaces** — and `arensb.truenas.initscript` registers the script as POSTINIT so
the box repairs itself at boot. Verified by deleting the live file and running the hook: it
was restored byte-identical.

**`arensb.truenas.initscript` is not idempotent on TrueNAS 25.04.** A second run raises
`Module failed: 'script_text'` on an entry that already exists. The role queries
`initshutdownscript.query` via `midclt` first and only calls the module when absent. Its
parameters are also not what the docs suggest — it takes `cmd`, `name`, `when`, `state`,
`timeout`; there is no `type` or `enabled`.

## Apply by hand, never from CI

Ansible is push-based and non-transactional. A half-applied run against the only
hypervisor in the house leaves an undefined state with no reconcile loop to heal it. Flux
gets away with continuous apply because Kubernetes self-heals; bare metal does not. An
unattended run after a Renovate bump could reboot the box holding the ZFS pools.

**`just ansible check <playbook>` first, always.** Caveat: modules without check-mode
support skip or report inaccurately, so a clean check run is a strong hint, not proof.

CI's job is `ansible-lint`, `--syntax-check`, and resolving `requirements.yml`. Applying is
a human, from the laptop.

## Traps

- **Do not create Proxmox guests with Ansible.** Tofu owns guest creation; Ansible
  configures what is inside them. Two creators means guaranteed drift.
- **LXC containers have no cloud-init**, so they need `ansible_user: root` while VMs use a
  normal user. The inventory diverges on that line — this is already reflected in
  `inventory/hosts.yml` for the Forgejo container.
- **ZFS: set dataset properties, never create or destroy pools.** Pool operations are
  one-shot and reboot-bearing — encode them as a check-and-assert, not enforced state.
- **`community.proxmox.proxmox_cluster` is reported as not reliably idempotent.** Prefer
  the module set for guests, ACLs and backup schedules; plain `ansible.builtin` for host OS.
- **Flipping the HBA out of RAID mode** is a manual, reboot-bearing operation. Assert it,
  do not enforce it.
- **Run `ansible` directly — no `mise exec` needed.** The shims directory is on PATH via
  `~/.zshenv`, so any tool added to `.mise/config.toml` resolves automatically.
- **`ANSIBLE_CONFIG` and friends are set in `.mise/config.toml`, absolutely.** Without
  them, running `ansible` from the repo root silently picks up `/etc/ansible/ansible.cfg`
  — wrong inventory, wrong roles path, no error. The env vars are absolute
  (`{{config_root}}/...`) so they hold from any directory; the relative paths inside
  `ansible/ansible.cfg` are only a fallback for someone already `cd`'d into `ansible/`.
- **The `ansible` binary needs a generated UTF-8 locale.** This box exports
  `LANG=en_US.utf-8` but only has `C.utf8` generated, which makes ansible refuse to start.
  `.mise/config.toml` pins `LANG`/`LC_ALL` to `C.UTF-8` for the repo.

## Formatting

Ansible YAML goes through the same `oxfmt` pre-commit hook as every other YAML file in the
repo — this was tested, and `ansible-lint` at the `production` profile passes on oxfmt's
output. The one thing oxfmt changes is exploding long _inline_ flow lists
(`[a, b, c, ...]`) across multiple lines. Use block lists instead, which is idiomatic
Ansible anyway.
