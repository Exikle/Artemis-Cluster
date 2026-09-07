# Ansible — Artemis-Cluster

The `ansible/` tree. Everything in the house that has an _operating system_ needing
configuration. Operational usage lives in `ansible/README.md`; this file carries the
reasoning and the traps.

## Scope — what belongs here

| Host                      | What Ansible owns                                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `pantheon` (10.10.99.104) | Proxmox host OS: apt, sysctl, IOMMU/vfio, ZFS dataset properties, NUT, node_exporter, SSH hardening, `ssacli` |
| `atlas` (10.10.99.100)    | TrueNAS: datasets, NFS/SMB shares, users, snapshot and scrub tasks, SMART                                     |
| `forgejo` (10.10.99.24)   | Forgejo LXC: release binary, `app.ini`, systemd unit — `roles/forgejo`, `playbooks/forgejo.yml`               |
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
- **The WSL2 dev machine.** mise owns both dotfiles and tools — dotfiles via `symlink-each`
  in `~/dotfiles/mise.toml`, applied with `mise bootstrap dotfiles apply`. The only genuine
  gap is sudo-level system config (`/etc/wsl.conf`, linuxbrew removal), and mise's
  post-dotfiles hooks cover that without a third owner of the same box.

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

## The forgejo role — why `app.ini` is edited key-by-key

`roles/forgejo` **adopts** the running instance; it does not install one. It asserts
`/etc/forgejo/app.ini` already exists and fails if it does not, because creating the instance
(`forgejo migrate`, admin bootstrap, flipping `INSTALL_LOCK`) is a one-shot done by hand.

**Applied to the live host on 2026-09-07** — this role is in service, not aspirational.

**The file is converged with `community.general.ini_file`, one key at a time, not with a
template.** This is deliberate and is the thing to understand before changing the role. A
`template:` task renders the **whole** file, so every key it fails to reproduce is a key it
silently deletes — and `app.ini` contains at least one whose value is recorded nowhere:
`[database] PASSWD`, a dead MySQL leftover that is inert under `DB_TYPE = sqlite3`. `ini_file`
touches only the keys the role names and leaves everything else byte-identical.

The cost is real and worth stating: **keys absent from `forgejo_settings` are not converged.**
Drift in an unmanaged setting is invisible to the role. That is the trade — undeclared settings
are left alone rather than destroyed.

### The secrets live in 1Password

Four `app.ini` values are secrets Forgejo generated at install time. They were lifted into
`op://infrastructure/forgejo-host` on 2026-09-07 and are now applied from there by a second,
`no_log: true` `ini_file` task driven by `forgejo_secret_settings`:

| app.ini                         | 1Password field      |
| ------------------------------- | -------------------- |
| `[security] INTERNAL_TOKEN`     | `INTERNAL_TOKEN`     |
| `[security] PASSWORD_HASH_ALGO` | `PASSWORD_HASH_ALGO` |
| `[oauth2] JWT_SECRET`           | `OAUTH2_JWT_SECRET`  |
| `[server] LFS_JWT_SECRET`       | `LFS_JWT_SECRET`     |

**`infrastructure`, not `artemis`** — the `artemis` vault is readable by the in-cluster
1Password Connect token, and these protect the host serving the GitOps repo the cluster pulls
from. Blast radius, not tool, decides the vault.

**`SECRET_KEY` is not set on this instance and must not be added.** It is absent from `app.ini`
entirely; Forgejo falls back to its own default. Introducing one invalidates anything encrypted
under the old value.

Because these are applied rather than templated, a `--check` run is a live consistency test: if
all four report `ok`, what is in the vault matches what is on the box. If one reports `changed`,
the vault and the host have diverged — find out which is right before applying.

### Themes are shipped by the role, and the THEMES list is derived

Forgejo shows a custom theme only when **both** are true: `theme-<name>.css` exists in
`$WORK_PATH/custom/public/assets/css/`, and `<name>` appears in `[ui] THEMES`. Getting one
without the other is silent — no error, the theme simply is not offered.

So `forgejo_custom_themes` lists the **filenames**, and `forgejo_theme_names` derives the
app.ini value from them by stripping the `theme-` / `.css` wrapper. Adding a theme is one line
in one list; the two halves cannot drift apart.

The stylesheets live in `roles/forgejo/files/themes/` and were pulled off the host, where they
were the only copy. Forgejo serves them straight off disk so the CSS needs no restart — **but
changing the THEMES list does**, because Forgejo reads `app.ini` once at boot. The task notifies
the restart handler, which is enough only when the play runs to completion; see the partial-apply
trap below for the case where it is not.

Symptom when the restart is missed: the files are on disk, `THEMES` is correct in `app.ini`, the
stylesheet serves `200` — and the theme still does not appear in Settings, because the running
process is still holding the list it read at boot. Check it with
`systemctl show forgejo -p ActiveEnterTimestamp --value` against the `app.ini` mtime.

**`anthracite` is Erwan Leboucher's theme** (`eleboucher/homelab`), already in use here. Each
file is a compiled Forgejo base followed by a trailing `:root` block that remaps the base's
`--steel-*` (dark) or `--zinc-*` (light) ramp onto a named palette. That trailing block is the
whole theme — the base above it is untouched upstream output.

**`ayu` was built by swapping only that block** for the official ayu palette
(`ayu-theme/ayu-colors`, `themes/dark.yaml` and `themes/light.yaml`). No ayu theme for
Forgejo or Gitea exists upstream — this is the adaptation, not a port.

One deliberate deviation: ayu's light accent `#f29718` measures **2.22:1** on the light
background, far under WCAG AA, so it is unusable as link text. `--color-primary` is a darkened
ayu orange (`#a35f00`, 4.75:1) and the true accent is kept on `--color-accent` for non-text
use. The dark theme needs no such fudge — `#e6b450` on `#0d1017` is 9.98:1.

### The host already updates itself — do not let the role fight it

Two cron jobs were found on the box and are now adopted into the role, because they existed
**only** in `/usr/local/sbin` and nowhere in git:

| Cron file                | When        | What it does                                                     |
| ------------------------ | ----------- | ---------------------------------------------------------------- |
| `forgejo-update`         | Sun 03:00   | Follows the Codeberg `latest` release and swaps the binary       |
| `forgejo-status-cleanup` | Daily 04:30 | Prunes `commit_status` in the SQLite DB — dedupe + 90-day cutoff |

`forgejo-update.sh` owning the binary is **incompatible** with the role owning it: cron upgrades
on Sunday, the next Ansible run puts `forgejo_version` back, forever. So `forgejo_manage_binary`
defaults to **false** and an `assert` fails the play if it is ever true at the same time as
`forgejo_update_cron_enabled`. Pick one owner. Flipping to the Ansible side means setting
`forgejo_manage_binary: true`, `forgejo_update_cron_enabled: false`, and letting Renovate bump the
pinned version — upgrades then happen when a human applies, not at 3am Sunday.

**The updater has no rollback.** It stops the service, keeps one `.bak`, moves the new binary in,
and starts. `set -e` means a failed start exits the script with the service **down** and nothing
restoring `.bak` — on a Sunday morning, on the box that serves the GitOps repo Flux pulls from.
Adopted as-is because that is what is running; worth fixing separately.

### `section: DEFAULT` is a trap in `ini_file`

`app.ini` opens with five keys (`APP_NAME`, `APP_SLOGAN`, `RUN_USER`, `WORK_PATH`, `RUN_MODE`)
above the first section header. `community.general.ini_file` does **not** treat `section: DEFAULT`
as that area — it appends a literal `[DEFAULT]` block to the end of the file and leaves the real
keys untouched, so the settings silently do not take. `section: null` is the one that edits the
pre-section area in place. Caught by a `--check --diff` run, which is the argument for always
doing one.

`forgejo_config_mode` is `0640`, applied 2026-09-07 (the file was `0644` before). The
`0770 root:git` parent directory is what actually keeps it away from other accounts, so that was
a tightening rather than a fix for live exposure.

## Secrets

`community.general.onepassword` lookup, supporting both service-account tokens and
1Password Connect. **Pass vault, item and field separately** — do not use an `op://` URI:

```yaml
forgejo_runner_token: "{{ lookup('community.general.onepassword',
    'forgejo', field='RUNNER_TOKEN', vault='artemis') }}"
```

The `op://artemis/forgejo/RUNNER_TOKEN` URI form documented here previously **fails under a
service-account token** with `'vault' is required with 'service_account_token'`. It only
works interactively, and laptop runs are exactly the service-account case — so the URI form
is broken in the common path. Corrected 2026-08-23 after it blocked the grimoire onboarding.

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

- **A run through Claude Code's `!` prefix can half-apply and report failure.** Ansible refuses
  non-blocking stdio (`ERROR: Ansible requires blocking IO on stdin/stdout/stderr`), but that
  guard lives in the **display** layer, so it can fire _after_ tasks have already changed the
  host. On 2026-09-07 a `just --yes ansible apply forgejo` that reported this error had already
  written the theme files, the THEMES line and the app.ini mode before dying — and because the
  play aborted, **its handlers never ran**, so Forgejo was never restarted and the new themes
  did not appear. The follow-up run found app.ini already correct, so it had nothing left to
  notify either.

    Treat that error as an **unknown partial apply**, never a no-op: re-run, then verify the
    service actually restarted rather than trusting the recap. Redirecting to a file
    (`> out 2>&1`) gives blocking handles and avoids it; a normal terminal tab has none of this.

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
output. The one thing oxfmt changes is exploding long **inline flow collections** across
multiple lines — both lists (`[a, b, c, ...]`) and mappings (`{k: v, k: v}`).

**Use block form, which is idiomatic Ansible anyway.** oxfmt and `ansible-lint` disagree about
how to indent an exploded flow collection, so anything oxfmt explodes fails `yaml[indentation]`
on the very next lint — and because oxfmt runs as a pre-commit hook, that lands _after_ a clean
pre-commit lint run and only shows up if you re-lint the committed state. This bit
`roles/forgejo/defaults/main.yml` on 2026-09-07 with 79 one-line `{section:, option:, value:}`
entries; they are block form now.
