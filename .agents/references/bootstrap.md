# Bootstrap — Order of Operations

How a fresh cluster is brought up. Moved out of `AGENTS.md` on 2026-09-02 because it is only
needed when bootstrapping, not on every session.

---

## Order

1. `just talos render-config <node> > /tmp/<node>.yaml` for each node, then
   `talosctl apply-config --insecure --nodes <node-ip> --file /tmp/<node>.yaml`
2. `just bootstrap cluster` — chains `nodes → k8s → kubeconfig → base → apps → kubeconfig`.
   `base` applies `bootstrap/helmfile.d/00-crds.yaml`; `apps` syncs
   `bootstrap/helmfile.d/01-apps.yaml`, in order: Cilium → CoreDNS → Spegel → cert-manager →
   external-secrets → onepassword-connect → flux-operator → flux-instance.

The recipe is `cluster`, not a bare `just bootstrap` — that only prints the module's recipe list.
It is gated behind a `[confirm]` prompt.

Node configs are Jinja2 templates (`talos/cluster.yaml.j2`, `talos/controlplane.yaml.j2`,
`talos/worker.yaml.j2`, `talos/nodes/<node>.yaml.j2`) — `talosctl apply-config --file` cannot
read a `.j2`. Always go through `just talos render-config`. See `.agents/references/talos.md`.
