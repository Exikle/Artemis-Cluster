# Ansible — Artemis-Cluster

The `ansible/` tree. Everything in the house that has an _operating system_ needing
configuration. Operational usage lives in `ansible/README.md`; this file carries the
reasoning and the traps.

## Scope — what belongs here

| Host                      | What Ansible owns                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pantheon` (10.10.99.104) | Proxmox host OS: ZFS dataset properties (`roles/zfs`), `node_exporter`, tap/net tuning, `lldpd`, the Sunday pre-update snapshot of CT 105 (`roles/pve_guest_snapshots`) and the nightly off-site mirror of `/bulkpool/backups` to atlas (`roles/offsite_backup`) — that is all `playbooks/pantheon.yml` applies. Hand-managed on the host and in no repo as of 2026-09-13: apt `.sources`, `sshd_config.d/10-hardening.conf`, `modprobe.d/zfs.conf` (ARC cap), the ZED→Alertmanager zedlet, `smartctl_exporter.service`, `/etc/pve/notifications.cfg`, the `pve-etc-backup` timer, `/etc/network/interfaces`, PCI mappings. No NUT (no UPS), no `ssacli` (LSI HBA, not Smart Array). Bringing these under roles is owed; until then the daily `/etc` tarball on `bulkpool` is the only copy. |
| `atlas` (10.10.99.100)    | TrueNAS: netdata's `[web]` bind in `/etc/netdata/netdata.conf`, the legacy `/etc/netdata/exporting.conf`, and their POSTINIT restore hook — `roles/netdata_exporter`, and that is all `playbooks/atlas.yml` applies. Datasets, NFS shares and snapshot/scrub tasks are **tofu's** as of 2026-09-18 (`terraform/stacks/truenas`); this row claimed them before that and the playbook never applied them. The `media` SMB share is unmanaged by either tool — `terraform/stacks/truenas/main.tf` says why.                                                                                                                                                                                                                                                                                     |
| `forgejo` (10.10.99.24)   | Forgejo LXC (CT 105, created by tofu — `terraform/stacks/proxmox/forgejo.tf`): OS baseline (`roles/lxc_base`), release binary, `app.ini`, systemd unit, scripts — `roles/forgejo`, `playbooks/forgejo.yml`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `grimoire` (10.10.1.157)  | MacBook workstation: `roles/macos_workstation`, `playbooks/grimoire.yml`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `ucg-max` (10.10.99.1)    | UCG Max gateway: the Tailscale subnet router — `roles/ucg_tailscale`, `playbooks/ucg-max.yml`; see the UCG Max section below. Everything else on the box is UniFi's.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `crs309` (172.16.99.2)    | Mikrotik switch: config export, backups, firewall — **inventory only, no playbook yet**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

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

Pinned in `ansible/requirements.yml`, installed with `just ansible deps` into the gitignored
`collections` directory under `ansible` (absent in a fresh worktree until that runs).

**`community.proxmox` is the current home of the `proxmox_*` modules** — they were split
out of `community.general`, which now keeps deprecated redirects. Write new code against
`community.proxmox`.

**`arensb.truenas` is the only viable TrueNAS collection.** Note how it works: it does
_not_ call the REST API from the control node. It runs on the box over SSH and shells to
`midclt`, so `atlas` needs SSH access. It has no replication-task, cloud-sync, or Apps
modules — snapshot tasks are covered, replication is not.

For the CRS309 use `community.routeros.api_modify` (idempotent), not `command`.

## The forgejo role — why `app.ini` is edited key-by-key

`roles/forgejo` **builds a host from bare Debian and converges an existing one.** Since
2026-10-10 it installs packages, creates the `git` user at the pinned UID/GID (103/112, the
IDs the original community-scripts install used, so carried-over data keeps its owner),
installs the latest release, and creates an instance signing key if there is none. It never
replaces an existing signing key — that would break verification of every commit it signed.
The play ends with an `/api/healthz` check, because systemd reports "started" before Forgejo
has read its config and a fatal config error would otherwise pass. A fresh instance still
needs its admin account created by hand.

**In service since 2026-09-07**, rebuilt onto Debian 13 on 2026-10-10 — see § Rebuilding the
Forgejo container.

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

### The host updates itself — do not let the role fight it

| Cron file                | When (UTC)  | What it does                                                                |
| ------------------------ | ----------- | --------------------------------------------------------------------------- |
| `forgejo-update`         | Sun 03:00   | Installs Codeberg's `latest` release, **majors included** (the user's call) |
| `forgejo-status-cleanup` | Daily 04:30 | `forgejo doctor cleanup-commit-status`, then a 90-day age trim in SQLite    |

`forgejo-update.sh` owning the binary is **incompatible** with the role owning it: cron upgrades
on Sunday, the next Ansible run puts `forgejo_version` back, forever. So `forgejo_manage_binary`
defaults to **false** and an `assert` fails the play if it is ever true at the same time as
`forgejo_update_cron_enabled`. Pick one owner.

**How an upgrade is made safe (since 2026-10-10).** The updater verifies the release's
`.sha256`, flushes queues, stops Forgejo, takes `sqlite3 .backup` into
`/var/lib/forgejo/backups` (newest 3 kept), swaps the binary, and waits for `/api/healthz`. If
that check fails it puts back **both** the old binary and the pre-upgrade database, so a major
version's migration is undone too. Behind that, pantheon snapshots CT 105 at **Sun 02:55 UTC**
(`roles/pve_guest_snapshots`, `auto_*`, newest 4 kept) — `pct rollback 105 <name>` restores the
whole container if both of those fail.

**Every outcome is reported.** The updater posts `alertname=ForgejoUpdate` to Alertmanager (the
same path as pantheon's ZED bridge; chaski itself is cluster-internal): `info` when it upgraded,
`warning` when it did not upgrade but Forgejo is still serving (no asset, bad checksum, rolled
back, or an unexpected exit with the service up), `critical` when Forgejo is left down. "Nothing
to do" sends nothing. Info alerts expire after an hour, the rest after a day.

**Why the age trim stays raw SQL.** Forgejo's `doctor cleanup-commit-status` removes duplicates
only — a dry run on 2026-10-10 found 303 in 240k rows. It has no age retention, and CI writes
several thousand statuses a day, so the 90-day `DELETE` is what keeps the table flat.

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

## Rebuilding the Forgejo container

Done once on 2026-10-10: the community-scripts Debian 12 container was replaced by a tofu-built
Debian 13 one that took over its identity. The same sequence works for any future rebuild.

1. `pct snapshot 105 <name>` first.
2. `tofu apply` `terraform/stacks/proxmox/forgejo.tf` with `vm_id = 106` and a free LAB address.
   The `.20`–`.49` range is outside DHCP (`.50`–`.70`) and the Cilium pool (`.71`–`.99`). ARP is
   no use for finding a free one: the UCG proxy-ARPs every unused address with its own MAC.
3. `just --yes ansible apply forgejo -e ansible_host=<temp IP>` — builds and starts a fresh
   instance, which the copy then overwrites.
4. On pantheon, copy at the ZFS level with `rsync -aHAX --numeric-ids --delete` from
   `/vmpool/subvol-105-disk-0/{var/lib/forgejo,etc/forgejo,home/git}` into 106's rootfs and data
   volume. Both are unprivileged with the same offset, so owners survive. Keep Forgejo
   **stopped** on 106 — a second live copy would run push mirrors and webhooks from stale data.
5. Cutover: stop Forgejo on 105, final copy plus `/etc/ssh/ssh_host_*` (so git clients see no
   host-key change), shut both down, then `zfs rename` the subvols and `mv` the configs:
   105 → 905 (`onboot: 0`, `link_down=1`) and 106 → 105 with the old MAC and IP. About 2 minutes
   of downtime.
6. Re-run the playbook against `.24` — the copy brought the old `app.ini`, so the role's newer
   keys are not live until it runs.
7. `tofu state rm` the container, set `vm_id = 105` and the final address/MAC, `tofu import
   … pantheon/105`, apply the state-only diff, and confirm the next plan is empty.
8. Delete 905 (`pct destroy 905`) once the new one has run cleanly for two weeks.

## The UCG Max role — Tailscale on a box UniFi owns

`roles/ucg_tailscale` installs the community
[`SierraSoftworks/tailscale-unifi`](https://github.com/SierraSoftworks/tailscale-unifi) package
so the gateway can be a subnet router to the tailnet. UniFi has no native Tailscale. Applied
2026-10-02 against Headscale. `host_vars/ucg-max.yml` sets `ucg_tailscale_up: true` and the
login server, so a plain `just ansible apply ucg-max` also brings the node up and re-applies any
drifted pref (routes, hostname, SNAT). The role default stays `ucg_tailscale_up: false`.

- **Pinned, not `curl | sh latest`.** The role does what upstream's `install.sh` does — unpack
  the release tarball into `/data`, then `manage.sh install` — but from a pinned tag. The tarball
  carries no version file, so the role writes `/data/tailscale/.tailscale-unifi-version`. Pinned
  tag: `grep unifi_version: ansible/roles/ucg_tailscale/defaults/main.yml`. That pins the
  _wrapper_; the `tailscale` .deb itself follows upstream's `TAILSCALE_AUTOUPDATE` (daily, on by
  default) unless `ucg_tailscale_package_version` is set.
- **Firmware updates can wipe the install.** The package lives in `/data` (survives) but the
  `.deb` lands in the overlay root. Upstream's `tailscale-install.timer` runs `manage.sh on-boot`
  after boot and daily and reinstalls it. It has still failed before (upstream issues #38, #96,
  #118), so watch tunnel reachability after every UniFi OS update rather than trusting the timer.
  Prefs (login server, routes) live in `/data/tailscale/tailscaled.state` and survive a reinstall.
- **Config changes go through `manage.sh install!`, not `restart`.** `TS_*` lines in
  `tailscale-env` reach `/etc/default/tailscaled` only during install, so the handler runs
  `install!`. That runs apt, so the gateway needs internet for the handler to succeed.
- **`TS_TUN_DISABLE_TCP_GRO=1`** works around the UCG Max LAN-port TSO engine mangling
  Tailscale's GRO super-packets: subnet-router TCP collapses to hundreds of kbps while ping looks
  fine (upstream issue #205).
- **Kernel (TUN) mode is required.** Userspace mode NATs everything and cannot route LAN →
  tailnet. Upstream silently falls back to userspace when `/dev/net/tun` is missing; the role
  fails instead.
- **`--snat-subnet-routes=false`** keeps real LAN source IPs on the far side. It must be set on
  _both_ subnet routers, each accepting the other's routes, or return traffic breaks (upstream
  issue #161). `--accept-dns=false` stops Tailscale taking over UniFi's dnsmasq.
- **dnsmasq must also listen on `tailscale0`, or split DNS fails for every Headscale client.**
  UniFi runs dnsmasq with `bind-dynamic` and an `interface=` list of LAN bridges only, so a
  `dcunha.io` query arriving over the tailnet is ignored (UDP) or reset (TCP). The role installs
  `dnsmasq-tailscale.{service,path}`: they write `interface=tailscale0` to
  `/run/dnsmasq.dhcp.conf.d/zz-tailscale.conf` and restart dnsmasq, but only when the file was
  missing. `/run` is tmpfs, so the path unit re-applies it after boot and whenever UniFi rewrites
  its dnsmasq config. Each re-apply is a ~1 s DNS blip on the LAN. Check:
  `ss -lun | grep ':53'` on the UCG should list the `100.64.x` address.
- **TCP MSS is clamped across `tailscale0`, or Frostlink pods stall ~7 s on every TLS
  handshake to an Artemis LoadBalancer IP.** Pods are MTU 1500 and their SYNs leave the VPS via
  a BPF redirect that skips netfilter, so they advertise MSS 1460. Envoy on `.90`/`.98` then sends
  1500-byte segments; the UCG answers `need to frag (mtu 1280)` but the Cilium-LB VIP never acts
  on it, and TCP recovers only after 1+2+4 s of retransmits (packet capture, 2026-10-03). The role
  installs `tailscale-mss.{service,timer}`: two `mangle FORWARD` TCPMSS rules (`-i tailscale0`
  set to 1240, `-o tailscale0` clamp-to-pmtu), re-added every minute because iptables is not
  persistent and UniFi rewrites its rules. Check: `iptables -t mangle -S FORWARD | grep TCPMSS`.
- **`tailscale up` is idempotent by comparison.** The role reads `tailscale status --json` and
  `tailscale debug prefs` and only runs `tailscale up --reset …` when the node is logged out or a
  pref drifted. The 1Password lookup sits in that task's `vars`, so it only resolves when the task
  runs — a check run with `ucg_tailscale_up: false` never needs the item to exist.
- **The tag comes from the pre-auth key, never from `--advertise-tags`.** Create the key with
  `headscale preauthkeys create --user <id> --tags tag:home-router`. Headscale rejects _any_
  requested tag on a pre-auth-key registration — even one identical to the key's — with
  `requested tags [tag:home-router] are invalid or not permitted`, and the node stays logged out.
  Hit on the first real apply (2026-10-02); the key is not consumed by the failed attempt.
- **The key in `infrastructure/headscale-preauth` is single-use and already spent.** It is only
  read when the node is logged out (a reset UCG, or a deleted Headscale node). Before re-running
  in that case, mint a fresh one on Frostlink —
  `kubectl -n network exec deploy/headscale -c app -- headscale preauthkeys create --user <id> --tags tag:home-router --expiration 1h`
  — and store it in that item's `UCG_AUTHKEY` field.
- **`ucg_tailscale_login_server` has no default** on purpose: unset, `tailscale up` would join
  Tailscale SaaS. The role asserts it is set before running `up`.
- **Python is probed, not assumed.** Whether UniFi OS ships `python3` is undocumented. The
  playbook runs with `gather_facts: false` and the role's first task is a `raw` probe that fails
  with a clear message if it is missing. If that ever fires, do not `apt install python3` — it
  would land in the overlay a firmware update replaces.
- **Manual, not Ansible: the IPS "Peer to Peer and Dark Web" category must be off**
  (Network → Security → Protection), or NAT traversal to the VPS can be blocked. That is UniFi
  controller config, outside this role.
- **UniFi's zone firewall cannot see `tailscale0`** — it is not a UniFi-managed interface.
  Access control for the routes lives in the Headscale policy, not in ZBF.

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

**How netdata reaches the cluster now.** Nothing is pushed. VMStaticScrape
`observability/netdata-atlas`
(`kubernetes/apps/observability/victoria/agent/vmstaticscrape-atlas.yaml`) scrapes netdata's own
Prometheus endpoint, `10.10.99.100:19999/api/v1/allmetrics?format=prometheus`, as
`job=netdata, instance=atlas`. That endpoint only exists because the role rewrites the `[web]`
section of `/etc/netdata/netdata.conf` to bind `10.10.99.100:19999` (`netdata_exporter_bind`,
keeping the loopback bind TrueNAS's Reporting tab reads) — the update wipes that too.

The `truenas-exporter` graphite bridge it replaced was retired in `d1fb5e655`. The role still
stages `/etc/netdata/exporting.conf`, a `[graphite:prometheus]` block whose
`netdata_exporter_destination` default is still `10.10.99.93:9109` — **stale**: nothing listens
for graphite there, and `10.10.99.93` is now the ClusterMesh apiserver LoadBalancer
(`networking.md` § ClusterMesh with Frostlink).

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

- **TrueNAS keeps root's SSH keys in its middleware, not in `authorized_keys`.** A key written to
  the file is lost on update. `roles/offsite_backup` adds its key through `midclt user.update`
  (`files/authorize-key.py`, delegated to atlas), behind `command="rrsync …",restrict` so it can
  only write under `/mnt/atlas/backups/pantheon`.
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
