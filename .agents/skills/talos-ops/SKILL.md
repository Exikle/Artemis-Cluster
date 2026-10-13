---
name: talos-ops
description: Perform Talos node operations — apply a config change, add or change a system extension, upgrade Talos or Kubernetes, reboot or reset a node. Use for "apply talos config", "upgrade talos node", "reboot node", "add a talos extension", or "node config change". Scoped to the Artemis cluster.
compatibility: Requires `talosctl` (mise pins it to the cluster's running Talos version — a mismatched client is the usual failure) and a working talosconfig. Node operations are disruptive — never widen the blast radius beyond the node the user named.
---

# Skill: Talos Operations

Node operations for Artemis-Cluster (Talos Linux with render-config / Jinja2 templates).

> Also read `.agents/references/talos.md` for node IPs and config background.

**Goal:** apply one Talos change to the named node(s) and confirm the node came back healthy.

**Success means:** the node reports the intended config, is `Ready`, and its static pods are
running (`talosctl get staticpods`) — a Ready node with missing control-plane static pods is the
failure this repo has hit before, and it only surfaces on the next reboot.

**Stop when:** the change is applied and verified on the node(s) the user named. Do NOT roll on
to other nodes, do NOT start a version upgrade the user did not ask for, and do NOT reboot a
second node until the first is back and healthy.

Edit in a worktree (`just wt new <type>/<slug>`, `AGENTS.md` rule 7). Every write verb below is
confirm-gated, so from a non-interactive shell put `--yes` before the module:
`just --yes talos apply-node <node>` (`.agents/instructions/tooling.md`).

## Config Changes (no reboot)

1. Edit `talos/nodes/<node>.yaml.j2`
2. `just talos render-config <node>`, then `just talos diff-node <node>` for a dry run
3. `just --yes talos apply-node <node>`

## Config Changes (with reboot)

```bash
just talos render-config <node>
just --yes talos apply-node <node> --mode=reboot
```

Drain the node first if it runs stateful workloads:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# apply + reboot
kubectl uncordon <node>
```

Use `drain` when you mean to empty the node, not a bare `cordon` (`.agents/references/scheduling.md`).

## Extension Changes

Schematics are per node type, not per node: `ls talos/schematics`. `just talos schematic-type <node>`
(`[private]`, in `talos/mod.just`) maps a node name to its type. Extensions need a new schematic ID
and a reboot:

1. Edit `talos/schematics/<type>.yaml`
2. `just talos schematic-id <type>` registers it with Sidero Image Factory and prints the ID. It is
   `[private]`, so it does not appear in `just talos`; it is still a real recipe.
3. Nothing to hand-edit: `render-config` computes the ID and injects it into `cluster.yaml.j2` as
   `ENV.SCHEMATIC`.
4. `just --yes talos apply-node <node> --mode=reboot`

## NEVER use `talosctl patch machineconfig` with a full config

Full config passed as a patch causes array fields (`machine.files`, `machine.certSANs`) to be **duplicated** in the merge, which can produce a read-only filesystem on next boot. Always use:

- `just talos apply-node <node>` — for full config replacement (render-config output)
- A minimal 6-line delta patch file for targeted changes (e.g., certSANs only)

Minimal certSANs patch example:

```yaml
machine:
    certSANs:
        - <ip-or-hostname>
cluster:
    apiServer:
        certSANs:
            - <ip-or-hostname>
```

Apply: `talosctl apply-config --file patch.yaml -n <node-ip>`

## Node Health

```bash
talosctl health -n <node-ip>
talosctl dmesg -n <node-ip> | tail -30
talosctl version -n <node-ip>
talosctl get machineconfig -n <node-ip> -o yaml
```

## Automated Upgrades (tuppr)

Check tuppr before upgrading by hand; it manages Talos and Kubernetes upgrades through cluster-scoped
CRDs:

```bash
kubectl get talosupgrades,kubernetesupgrades
```

## Manual Talos Upgrade (single node)

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
just --yes talos upgrade-node <node>
kubectl uncordon <node>
```

The recipe resolves the installer image (schematic plus version) from the rendered config. Kubernetes:
`just --yes talos upgrade-k8s <version>`.

## Nodes

`ls talos/nodes` lists them and `kubectl get nodes -o wide` gives roles and IPs.
