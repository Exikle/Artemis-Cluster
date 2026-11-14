# Ansible — home-infra

This file covers the `ansible/` tree. It holds everything in the house that has an _operating system_ that needs
configuration. `ansible/README.md` covers operational usage. This file carries the
reasoning and the traps.

## Scope — what belongs here

| Host                      | What Ansible owns                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pantheon` (10.10.99.104) | Proxmox host OS: ZFS dataset properties (`roles/zfs`), `node_exporter`, tap/net tuning, `lldpd`, the Sunday pre-update snapshot of CT 105 (`roles/pve_guest_snapshots`) and the nightly off-site mirror of `/bulkpool/backups` to atlas (`roles/offsite_backup`). `playbooks/pantheon.yml` applies only these. Hand-managed on the host and in no repo: apt `.sources`, `sshd_config.d/10-hardening.conf`, `modprobe.d/zfs.conf` (ARC cap), the ZED→Alertmanager zedlet, `smartctl_exporter.service`, `/etc/pve/notifications.cfg`, the `pve-etc-backup` timer, `/etc/network/interfaces`, PCI mappings. No NUT (no UPS), no `ssacli` (LSI HBA, not Smart Array). Bringing these under roles is owed. Until then the daily `/etc` tarball on `bulkpool` is the only copy. |
| `atlas` (10.10.99.100)    | TrueNAS: the netdata `[web]` bind in `/etc/netdata/netdata.conf` and its POSTINIT restore hook (`roles/netdata_exporter`). `playbooks/atlas.yml` applies only these. Datasets, NFS shares and snapshot/scrub tasks belong to tofu (`terraform/stacks/truenas`). Neither tool manages the `media` SMB share. `terraform/stacks/truenas/main.tf` says why.                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `forgejo` (10.10.99.24)   | Forgejo LXC (CT 105, created by tofu in `terraform/stacks/proxmox/forgejo.tf`): OS baseline (`roles/lxc_base`), release binary, `app.ini`, systemd unit, scripts (`roles/forgejo`, `playbooks/forgejo.yml`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `grimoire` (10.10.1.157)  | MacBook workstation: `roles/macos_workstation`, `playbooks/grimoire.yml`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `ucg-max` (10.10.99.1)    | UCG Max gateway: the Tailscale subnet router (`roles/ucg_tailscale`, `playbooks/ucg-max.yml`). See the UCG Max section below. UniFi owns everything else on the box.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `crs309` (10.10.99.2)     | Mikrotik switch: inventory only, no playbook. Tofu owns its config (`terraform/stacks/mikrotik`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

## What does NOT belong here

- Talos nodes. They have no SSH, no package manager, and no Python interpreter. There is no
  `siderolabs` Ansible collection. People build `command:` wrappers around
  `talosctl`, which is Ansible as a shell script with none of the value of Ansible. Talos machine
  config _is_ the declarative state. `just talos render-config` already does this, and
  the wider home-operations community converged on it after dropping Ansible.
- Anything inside Kubernetes. Flux owns it.
- Restore drills and runbooks. They are interactive, branching procedures that need human judgment,
  the opposite of convergent state. They stay as `just` recipes and `.agents/skills/`.
- Windows / Arcana. It is one GUI-managed desktop, and WinRM plumbing has negative payback.
- The WSL2 dev machine. mise owns both dotfiles and tools. It manages dotfiles with `symlink-each`
  in `~/dotfiles/mise.toml`, applied with `mise bootstrap dotfiles apply`. The only genuine
  gap is sudo-level system config (`/etc/wsl.conf`, linuxbrew removal). The post-dotfiles hooks of mise
  cover that without a third owner of the same box.

## Collections

`ansible/requirements.yml` pins the collections. `just ansible deps` installs them into the gitignored
`collections` directory under `ansible`. That directory is absent in a fresh worktree until the command runs.

`community.proxmox` is the current home of the `proxmox_*` modules. They were split
out of `community.general`, which now keeps deprecated redirects. Write new code against
`community.proxmox`.

`arensb.truenas` is the only viable TrueNAS collection. It does
_not_ call the REST API from the control node. It runs on the box over SSH and shells to
`midclt`, so `atlas` needs SSH access. It has no replication-task, cloud-sync, or Apps
modules. It covers snapshot tasks but not replication.

For the CRS309 use `community.routeros.api_modify` (idempotent), not `command`.

## The forgejo role — why `app.ini` is edited key-by-key

`roles/forgejo` builds a host from bare Debian and converges an existing one. Since
2026-10-10 it installs packages, creates the `git` user at the pinned UID/GID (103/112, the
IDs that the original community-scripts install used, so carried-over data keeps its owner),
installs the latest release, and creates an instance signing key if there is none. It never
replaces an existing signing key, because that would break verification of every commit it signed.
The play ends with an `/api/healthz` check. systemd reports "started" before Forgejo
has read its config, and a fatal config error would otherwise pass. A fresh instance still
needs someone to create its admin account by hand.

The role converges the file with `community.general.ini_file`, one key at a time, not with a
template. This is deliberate. Understand it before you change the role. A
`template:` task renders the whole file, so every key it fails to reproduce is a key it
silently deletes. `app.ini` contains at least one key whose value is recorded nowhere:
`[database] PASSWD`, a dead MySQL leftover that is inert under `DB_TYPE = sqlite3`. `ini_file`
touches only the keys that the role names and leaves everything else byte-identical.

The cost is real. The role does not converge keys that are absent from `forgejo_settings`.
Drift in an unmanaged setting is invisible to the role. That is the trade: the role leaves undeclared settings
alone and does not destroy them.

### The secrets live in 1Password

Four `app.ini` values are secrets that Forgejo generated at install time. They live in the `server`
section of `op://infrastructure/forgejo` beside `METRICS_TOKEN`. A second
`no_log: true` `ini_file` task applies them from there. The task uses `forgejo_secret_settings`:

| app.ini                         | 1Password field      |
| ------------------------------- | -------------------- |
| `[security] INTERNAL_TOKEN`     | `INTERNAL_TOKEN`     |
| `[security] PASSWORD_HASH_ALGO` | `PASSWORD_HASH_ALGO` |
| `[oauth2] JWT_SECRET`           | `OAUTH2_JWT_SECRET`  |
| `[server] LFS_JWT_SECRET`       | `LFS_JWT_SECRET`     |

A separate item would not hide them from the cluster. The 1Password Connect
tokens of both clusters read the `infrastructure` vault, because the Forgejo tokens of the cluster live there too. To keep
them from the cluster, you would need a vault that Connect cannot read, not a separate item.

This instance does not set `SECRET_KEY`, and you must not add it. It is absent from `app.ini`
entirely, and Forgejo falls back to its own default. If you introduce one, it invalidates anything encrypted
under the old value.

The role applies these values and does not template them. A `--check` run is therefore a live consistency test. If
all four report `ok`, what is in the vault matches what is on the box. If one reports `changed`,
the vault and the host have diverged. Find out which is right before you apply.

### Themes are shipped by the role, and the THEMES list is derived

Forgejo shows a custom theme only when both of these are true: `theme-<name>.css` exists in
`$WORK_PATH/custom/public/assets/css/`, and `<name>` appears in `[ui] THEMES`. If only one is true, nothing tells you. There is no error, and the theme is not offered.

For this reason `forgejo_custom_themes` lists the filenames, and `forgejo_theme_names` derives the
app.ini value from them by stripping the `theme-` / `.css` wrapper. To add a theme, you add one line
to one list. The two halves cannot drift apart.

The stylesheets live in `roles/forgejo/files/themes/`. Forgejo serves them straight off disk, so the CSS needs no restart. A change to the THEMES list does need a restart,
because Forgejo reads `app.ini` once at boot. The task notifies
the restart handler. That is enough only when the play runs to completion. See the partial-apply
trap below for the case where it does not.

Symptom when the restart is missed: the files are on disk, `THEMES` is correct in `app.ini`, the
stylesheet serves `200`, and the theme still does not appear in Settings. The running
process still holds the list that it read at boot. Check it with
`systemctl show forgejo -p ActiveEnterTimestamp --value` against the `app.ini` mtime.

`anthracite` is the theme of Erwan Leboucher (`eleboucher/homelab`), already in use here. Each
file is a compiled Forgejo base followed by a trailing `:root` block. That block remaps the `--steel-*` (dark) or `--zinc-*` (light) ramp of the base onto a named palette. That trailing block is the
whole theme. The base above it is untouched upstream output.

The base is from Forgejo 16, so a Forgejo major can add variables that the base never defines. Forgejo 17 builds
`--color-thin-*` (callouts, danger buttons, coloured text) from `--hue-*`, and in light mode from
`--thin-lightness` and `--regular-chroma` too. A last `:root` block in each file carries the values of Forgejo 17
for those. After a major upgrade, diff the variables that `index.css` references against what
`index.css` plus each theme defines. Compare the result with the built-in `forgejo-dark`/`-light`.

The team built `ayu` by swapping only that block for the official ayu palette
(`ayu-theme/ayu-colors`, `themes/dark.yaml` and `themes/light.yaml`). No ayu theme for
Forgejo or Gitea exists upstream. This is the adaptation, not a port.

There is one deliberate deviation. The light accent `#f29718` of ayu measures 2.22:1 on the light
background, far under WCAG AA, so it is unusable as link text. `--color-primary` is a darkened
ayu orange (`#a35f00`, 4.75:1), and the true accent stays on `--color-accent` for non-text
use. The dark theme needs no such change: `#e6b450` on `#0d1017` is 9.98:1.

### The host updates itself — do not let the role fight it

| Cron file                | When (UTC)  | What it does                                                                   |
| ------------------------ | ----------- | ------------------------------------------------------------------------------ |
| `forgejo-update`         | Sun 03:00   | Installs the `latest` release from Codeberg, majors included (the user's call) |
| `forgejo-status-cleanup` | Daily 04:30 | `forgejo doctor cleanup-commit-status`, then a 90-day age trim in SQLite       |

`forgejo-update.sh` and the role cannot both own the binary. Cron upgrades
on Sunday, the next Ansible run puts `forgejo_version` back, and this repeats forever. For this reason `forgejo_manage_binary`
defaults to false, and an `assert` fails the play if it is ever true at the same time as
`forgejo_update_cron_enabled`. Pick one owner.

How an upgrade is made safe (since 2026-10-10): The updater verifies the `.sha256` of the release,
flushes queues, stops Forgejo, takes `sqlite3 .backup` into
`/var/lib/forgejo/backups` (newest 3 kept), swaps the binary, and waits for `/api/healthz`. If
that check fails, it puts back both the old binary and the pre-upgrade database, so it also undoes the migration of a major
version. Behind that, pantheon snapshots CT 105 at Sun 02:55 UTC
(`roles/pve_guest_snapshots`, `auto_*`, newest 4 kept). `pct rollback 105 <name>` restores the
whole container if both of those fail. Any other failure with the service stopped (a failed
backup, a failed start) puts the old binary and database back if they were already swapped,
starts Forgejo again, and only then alerts. A failed run therefore does not leave Forgejo down.

Both cron scripts set their own `PATH`, and the updater runs `set -E`. The `PATH` of cron is
`/usr/bin:/bin`, which has no `runuser`. Without `-E`, functions do not inherit the `ERR` trap,
so a failure inside `as_git` exited with no alert and no restart. On 2026-10-18
those two together left Forgejo stopped for 2.5 hours (#2809).

The updater reports every outcome. It posts `alertname=ForgejoUpdate` to Alertmanager (the
same path as the ZED bridge of pantheon. chaski itself is cluster-internal). The severity is `info` when it upgraded,
`warning` when it did not upgrade but Forgejo is still serving (no asset, bad checksum, rolled
back, or an unexpected exit with the service up), and `critical` when Forgejo is left down. "Nothing
to do" sends nothing. Info alerts expire after an hour, and the rest after a day.

Why the age trim stays raw SQL: `doctor cleanup-commit-status` of Forgejo removes duplicates
only. It has no age retention, and CI writes
several thousand statuses a day, so the 90-day `DELETE` keeps the table flat.

### `section: DEFAULT` is a trap in `ini_file`

`app.ini` opens with five keys (`APP_NAME`, `APP_SLOGAN`, `RUN_USER`, `WORK_PATH`, `RUN_MODE`)
above the first section header. `community.general.ini_file` does not treat `section: DEFAULT`
as that area. It appends a literal `[DEFAULT]` block to the end of the file and leaves the real
keys untouched, so the settings silently do not take. `section: null` edits the
pre-section area in place. A `--check --diff` run caught this, which is the argument for always
doing one.

## Rebuilding the Forgejo container

This sequence replaces the container with a fresh tofu-built one that takes over its identity.

1. Run `pct snapshot 105 <name>` first.
2. Run `tofu apply` on `terraform/stacks/proxmox/forgejo.tf` with `vm_id = 106` and a free LAB address.
   The `.20`–`.49` range is outside DHCP (`.50`–`.70`) and the Cilium pool (`.71`–`.99`). ARP cannot
   find a free address, because the UCG proxy-ARPs every unused address with its own MAC.
3. Run `just --yes ansible apply forgejo -e ansible_host=<temp IP>`. It builds and starts a fresh
   instance, which the copy then overwrites.
4. On pantheon, copy at the ZFS level with `rsync -aHAX --numeric-ids --delete` from
   `/vmpool/subvol-105-disk-0/{var/lib/forgejo,etc/forgejo,home/git}` into the rootfs and data
   volume of 106. Both are unprivileged with the same offset, so owners survive. Keep Forgejo
   stopped on 106. A second live copy would run push mirrors and webhooks from stale data.
5. Cut over. Stop Forgejo on 105. Make a final copy plus `/etc/ssh/ssh_host_*` (so git clients see no
   host-key change). Shut both down, then `zfs rename` the subvols and `mv` the configs:
   105 → 905 (`onboot: 0`, `link_down=1`) and 106 → 105 with the old MAC and IP. This causes about 2 minutes
   of downtime.
6. Run the playbook again against `.24`. The copy brought the old `app.ini`, so the newer
   keys of the role are not live until it runs.
7. Run `tofu state rm` on the container, set `vm_id = 105` and the final address/MAC, run `tofu import
   … pantheon/105`, apply the state-only diff, and make sure that the next plan is empty.
8. Delete 905 (`pct destroy 905`) after the new container has run cleanly for two weeks.

## The UCG Max role — Tailscale on a box UniFi owns

`roles/ucg_tailscale` installs the community
[`SierraSoftworks/tailscale-unifi`](https://github.com/SierraSoftworks/tailscale-unifi) package
so the gateway can be a subnet router to the tailnet. UniFi has no native Tailscale. The team applied it
2026-10-02 against Headscale. `host_vars/ucg-max.yml` sets `ucg_tailscale_up: true` and the
login server, so a plain `just ansible apply ucg-max` also brings the node up and re-applies any
drifted pref (routes, hostname, SNAT). The role default stays `ucg_tailscale_up: false`.

- Pinned, not `curl | sh latest`. The role does what the `install.sh` of upstream does. It unpacks
  the release tarball into `/data`, then runs `manage.sh install`, but from a pinned tag. The tarball
  carries no version file, so the role writes `/data/tailscale/.tailscale-unifi-version`. Pinned
  tag: `grep unifi_version: ansible/roles/ucg_tailscale/defaults/main.yml`. That pins the
  _wrapper_. The `tailscale` .deb itself follows `TAILSCALE_AUTOUPDATE` of upstream (daily, on by
  default) unless `ucg_tailscale_package_version` is set.
- Firmware updates can wipe the install. The package lives in `/data` (survives), but the
  `.deb` lands in the overlay root. The `tailscale-install.timer` of upstream runs `manage.sh on-boot`
  after boot and daily and reinstalls it. It has still failed before (upstream issues #38, #96,
  #118), so watch tunnel reachability after every UniFi OS update. Do not trust the timer.
  Prefs (login server, routes) live in `/data/tailscale/tailscaled.state` and survive a reinstall.
- Config changes go through `manage.sh install!`, not `restart`. `TS_*` lines in
  `tailscale-env` reach `/etc/default/tailscaled` only during install, so the handler runs
  `install!`. That runs apt, so the gateway needs internet for the handler to succeed.
- `TS_TUN_DISABLE_TCP_GRO=1` works around the TSO engine of the UCG Max LAN port, which mangles the
  GRO super-packets of Tailscale. Subnet-router TCP collapses to hundreds of kbps while ping looks
  fine (upstream issue #205).
- Kernel (TUN) mode is required. Userspace mode NATs everything and cannot route LAN →
  tailnet. Upstream silently falls back to userspace when `/dev/net/tun` is missing. The role
  fails instead.
- `--snat-subnet-routes=false` keeps real LAN source IPs on the far side. You must set it on
  _both_ subnet routers, and each must accept the routes of the other, or return traffic breaks (upstream
  issue #161). `--accept-dns=false` stops Tailscale from taking over the dnsmasq of UniFi.
- dnsmasq must also listen on `tailscale0`, or split DNS fails for every Headscale client.
  UniFi runs dnsmasq with `bind-dynamic` and an `interface=` list of LAN bridges only, so dnsmasq ignores (UDP) or resets (TCP) a
  `dcunha.io` query that arrives over the tailnet. The role installs
  `dnsmasq-tailscale.{service,path}`. They write `interface=tailscale0` to
  `/run/dnsmasq.dhcp.conf.d/zz-tailscale.conf` and restart dnsmasq, but only when the file was
  missing. `/run` is tmpfs, so the path unit re-applies it after boot and whenever UniFi rewrites
  its dnsmasq config. Each re-apply is a ~1 s DNS blip on the LAN. Check:
  `ss -lun | grep ':53'` on the UCG must list the `100.64.x` address.
- The role clamps TCP MSS across `tailscale0`. Without it, Frostlink pods stall ~7 s on every TLS
  handshake to an Artemis LoadBalancer IP. Pods are MTU 1500, and their SYNs leave the VPS through
  a BPF redirect that skips netfilter, so they advertise MSS 1460. Envoy on `.90`/`.98` then sends
  1500-byte segments. The UCG answers `need to frag (mtu 1280)`, but the Cilium-LB VIP never acts
  on it, and TCP recovers only after 1+2+4 s of retransmits (packet capture, 2026-10-03). The role
  installs `tailscale-mss.{service,timer}`: two `mangle FORWARD` TCPMSS rules (`-i tailscale0`
  set to 1240, `-o tailscale0` clamp-to-pmtu). The timer re-adds them every minute, because iptables is not
  persistent and UniFi rewrites its rules. Check: `iptables -t mangle -S FORWARD | grep TCPMSS`.
- `tailscale up` is idempotent by comparison. The role reads `tailscale status --json` and
  `tailscale debug prefs` and runs `tailscale up --reset …` only when the node is logged out or a
  pref drifted. The 1Password lookup sits in the `vars` of that task, so it resolves only when the task
  runs. A check run with `ucg_tailscale_up: false` never needs the item to exist.
- The tag comes from the pre-auth key, never from `--advertise-tags`. Create the key with
  `headscale preauthkeys create --user <id> --tags tag:home-router`. Headscale rejects _any_
  requested tag on a pre-auth-key registration, even one identical to the key, with
  `requested tags [tag:home-router] are invalid or not permitted`, and the node stays logged out.
  The first real apply hit this (2026-10-02). The failed attempt does not consume the key.
- The key in `infrastructure/headscale` → `ucg-max router` is single-use and already spent. The role reads it only
  when the node is logged out (a reset UCG, or a deleted Headscale node). Before you run the role again
  in that case, mint a fresh key on Frostlink with
  `kubectl -n network exec deploy/headscale -c app -- headscale preauthkeys create --user <id> --tags tag:home-router --expiration 1h`
  and store it in the `UCG_AUTHKEY` field of that item.
- `ucg_tailscale_login_server` has no default on purpose. If it is unset, `tailscale up` would join
  Tailscale SaaS. The role asserts that it is set before it runs `up`.
- The role probes for Python and does not assume it. Whether UniFi OS ships `python3` is undocumented. The
  playbook runs with `gather_facts: false`, and the first task of the role is a `raw` probe that fails
  with a clear message if Python is missing. If that ever fires, do not `apt install python3`. It
  would land in the overlay that a firmware update replaces.
- Manual, not Ansible: turn off the IPS "Peer to Peer and Dark Web" category
  (Network → Security → Protection), or it can block NAT traversal to the VPS. That is UniFi
  controller config, outside this role.
- The zone firewall of UniFi cannot see `tailscale0`, because UniFi does not manage that interface.
  Access control for the routes lives in the Headscale policy, not in ZBF.

## Secrets

Use the `community.general.onepassword` lookup, which supports both service-account tokens and
1Password Connect. Pass vault, item and field separately. Do not use an `op://` URI:

```yaml
forgejo_runner_token: "{{ lookup('community.general.onepassword',
    'forgejo', field='RUNNER_TOKEN', vault='artemis') }}"
```

The `op://` URI form fails under a service-account token with
`'vault' is required with 'service_account_token'`, and laptop runs are exactly that case.

Use a service account for laptop runs and Connect for CI. Put `no_log: true` on tasks that consume
secrets. Do not use ansible-vault: `AGENTS.md` rule 3 (1Password only, no SOPS) wins.

## The netdata.conf chore, solved properly

TrueNAS wipes `/etc/netdata/netdata.conf` on every update. If you re-template the file, you lose the
race with the next update.

How netdata reaches the cluster now: Nothing is pushed. VMStaticScrape
`observability/netdata-atlas`
(`clusters/artemis/kubernetes/apps/observability/victoria/agent/vmstaticscrape-atlas.yaml`) scrapes the Prometheus endpoint of netdata,
`10.10.99.100:19999/api/v1/allmetrics?format=prometheus`, as
`job=netdata, instance=atlas`. That endpoint exists only because the role rewrites the `[web]`
section of `/etc/netdata/netdata.conf` to bind `10.10.99.100:19999` (`netdata_exporter_bind`,
and it keeps the loopback bind that the Reporting tab of TrueNAS reads). The update wipes that too.

The team retired the `truenas-exporter` graphite bridge in `d1fb5e655`. `exporting.conf` does not belong to
the role. TrueNAS middleware renders it from Reporting → Exporters
(`midclt call reporting.exporters.query`), so the team configured the graphite push there, not in
any file. The role used to stage its own copy as well. The team removed that in #2762, along with
the middleware exporter, whose destination `10.10.99.93` had become the ClusterMesh apiserver
LoadBalancer (`networking.md` § ClusterMesh with Frostlink).

`roles/netdata_exporter` implements the fix. The canonical config and a restore script live
on a dataset (`/mnt/atlas/config/netdata/`). They must not live in `/etc`, which is what
the update replaces. `arensb.truenas.initscript` registers the script as POSTINIT, so
the box repairs itself at boot.

`arensb.truenas.initscript` is not idempotent on TrueNAS 25.04. A second run raises
`Module failed: 'script_text'` on an entry that already exists. The role queries
`initshutdownscript.query` through `midclt` first and calls the module only when the entry is absent. The parameters of the module also differ from what the docs suggest. It takes `cmd`, `name`, `when`, `state`,
`timeout`. It has no `type` or `enabled`.

## Apply by hand, never from CI

Ansible is push-based and non-transactional. A half-applied run against the only
hypervisor in the house leaves an undefined state with no reconcile loop to heal it. Flux
can apply continuously because Kubernetes self-heals. Bare metal does not. An
unattended run after a Renovate bump could reboot the box that holds the ZFS pools.

Always run `just ansible check <playbook>` first. Modules without check-mode
support skip or report inaccurately, so a clean check run is a strong hint, not proof.

CI runs `ansible-lint` and `--syntax-check`, and it resolves `requirements.yml`. A human applies
from the laptop.

## Traps

- A run through the `!` prefix of Claude Code can half-apply and report failure. Ansible refuses
  non-blocking stdio (`ERROR: Ansible requires blocking IO on stdin/stdout/stderr`), but that
  guard lives in the display layer, so it can fire _after_ tasks have already changed the
  host. Because the play aborted, its handlers never ran, so nothing restarts the service. The follow-up run finds the config already correct, so it has nothing to notify
  either.

    Treat that error as an unknown partial apply, never a no-op. Run again, then make sure that the
    service actually restarted. Do not trust the recap. Redirecting to a file
    (`> out 2>&1`) gives blocking handles and avoids it. A normal terminal tab has none of this.

- TrueNAS keeps the SSH keys of root in its middleware, not in `authorized_keys`. A key written to
  the file is lost on update. `roles/offsite_backup` adds its key through `midclt user.update`
  (`files/authorize-key.py`, delegated to atlas), behind `command="rrsync …",restrict` so it can
  only write under `/mnt/atlas/backups/pantheon`.
- Do not create Proxmox guests with Ansible. Tofu owns guest creation, and Ansible
  configures what is inside them. Two creators guarantee drift.
- LXC containers have no cloud-init, so they need `ansible_user: root` while VMs use a
  normal user. The inventory diverges on that line. `inventory/hosts.yml` already reflects this for the Forgejo container.
- ZFS: set dataset properties, and never create or destroy pools. Pool operations are
  one-shot and reboot-bearing. Encode them as a check-and-assert, not enforced state.
- Reports say `community.proxmox.proxmox_cluster` is not reliably idempotent. Prefer
  the module set for guests, ACLs and backup schedules. Use plain `ansible.builtin` for host OS.
- Run `ansible` directly. You do not need `mise exec`. The shims directory is on PATH through
  `~/.zshenv`, so any tool added to `.mise/config.toml` resolves automatically.
- `.mise/config.toml` sets `ANSIBLE_CONFIG` and its related variables, as absolute paths. Without
  them, running `ansible` from the repo root silently picks up `/etc/ansible/ansible.cfg`,
  with the wrong inventory, the wrong roles path, and no error. The env vars are absolute
  (`{{config_root}}/...`) so they hold from any directory. The relative paths inside
  `ansible/ansible.cfg` are only a fallback for someone who already ran `cd` into `ansible/`.
- The `ansible` binary needs a generated UTF-8 locale. This box exports
  `LANG=en_US.utf-8` but has only `C.utf8` generated, which makes ansible refuse to start.
  `.mise/config.toml` pins `LANG`/`LC_ALL` to `C.UTF-8` for the repo.

## Formatting

Ansible YAML goes through the same `oxfmt` pre-commit hook as every other YAML file in the
repo. The team tested this, and `ansible-lint` at the `production` profile passes on the output of oxfmt. The one thing oxfmt changes is that it explodes long inline flow collections across
multiple lines, both lists (`[a, b, c, ...]`) and mappings (`{k: v, k: v}`).

Use block form, which is idiomatic Ansible anyway. oxfmt and `ansible-lint` disagree about
how to indent an exploded flow collection, so anything oxfmt explodes fails `yaml[indentation]`
on the very next lint. Because oxfmt runs as a pre-commit hook, that failure lands _after_ a clean
pre-commit lint run and shows up only if you lint the committed state again.
