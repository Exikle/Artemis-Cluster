# Bootstrap — Order of Operations

How a fresh cluster is brought up. Moved out of `AGENTS.md` on 2026-09-02 because it is only
needed when bootstrapping, not on every session.

---

## Order

`just bootstrap cluster` does the whole thing — chains
`nodes → k8s → kubeconfig → base → apps → kubeconfig`, and `base` waits on `api-ready` and
`nodes-ready` first. `base` applies `bootstrap/helmfile.d/00-crds.yaml`; `apps` syncs
`bootstrap/helmfile.d/01-apps.yaml`, in order: Cilium → CoreDNS → Spegel → cert-manager →
external-secrets → onepassword-connect → flux-operator → flux-instance.

Applying node configs by hand first is no longer needed. That step was here because the `nodes`
stage was broken: it took its list from `talosctl config info`, whose `.nodes` is one hand-set
IP, and fed IPs to `just talos apply-node`, which is keyed on hostname. The list now comes from
`talos/nodes/*.yaml.j2`, control planes first (fixed 2026-09-10).

The recipe is `cluster`, not a bare `just bootstrap` — that only prints the module's recipe list.
It is gated behind a `[confirm]` prompt.

Two lists, and they are not interchangeable: **the fleet** is `talos/nodes/*.yaml.j2` (7 nodes,
hostnames — `just bootstrap node-list`), and **the control planes** are `talosctl config info`
`.endpoints` (3 IPs). `api-ready` polls `:6443/readyz` and must use the second — upstream
onedr0p runs control planes only, so it iterates every node there and a straight copy of that
loop waits forever on a worker.

The module pins `KUBECONFIG` to the repo's own file and every `kubectl`/`helmfile` call to
`--context artemis` (override with `KUBE_CONTEXT`), including the hooks inside
`helmfile.d/01-apps.yaml`. Without that, `just bootstrap base` with `frostlink` selected applies
Artemis namespaces, CRDs and 1Password secrets into frostlink with no prompt.

Node configs are Jinja2 templates (`talos/cluster.yaml.j2`, `talos/controlplane.yaml.j2`,
`talos/worker.yaml.j2`, `talos/nodes/<node>.yaml.j2`) — `talosctl apply-config --file` cannot
read a `.j2`. Always go through `just talos render-config`. See `.agents/references/talos.md`.
