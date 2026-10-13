---
name: fix-flux
description: Diagnose and repair a stalled Flux reconciliation — a HelmRelease stuck or not progressing, a Kustomization not reconciling, an OCIRepository not resolving, or an ExternalSecret not syncing. Use for "flux is broken", "HelmRelease stuck", "kustomization not reconciling", "ExternalSecret not syncing", or when flux get shows a resource not ready. Scoped to the Artemis cluster.
---

# Skill: Fix Flux

Diagnose and fix Flux reconciliation issues in Artemis-Cluster.

> Read `.agents/references/flux-patterns.md` before diagnosing — it covers stuck HelmRelease fixes, cross-namespace gotchas, and the CRD timing race.

**Goal:** find why one Flux resource is not reconciling and fix that cause.

**Success means:** the named resource reports Ready with the current revision, and you can say
which cause it was — not merely that a retry made it go green.

**Stop when:** that resource is Ready. Do NOT `flux delete`, do NOT delete PVCs or namespaces to
clear a stuck state, and do NOT force-reconcile the flux-system OCIRepository straight after a
push — that can apply a stale tree mid-build. Escalate to the user instead.

The source is the OCIRepository `flux-system`; there is no GitRepository. App Kustomizations
live in their app's namespace, not `flux-system`. A fix that changes manifests follows
`.agents/instructions/commit-style.md` § The sequence, in a worktree (`just wt new fix/<slug>`).

## Step 1 — Identify What's Broken

```bash
flux get all -A --status-selector ready=false
kubectl get helmrelease -A | grep -v "True"
kubectl get kustomization -A | grep -v "True"
```

## Step 2 — Diagnose by Symptom

### Stuck HelmRelease (install/upgrade retrying)

```bash
flux describe helmrelease <app> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

Fix:

```bash
flux suspend helmrelease <app> -n <namespace>
kubectl delete secret -n <namespace> -l name=<app>,owner=helm
flux resume helmrelease <app> -n <namespace>
```

### Kustomization Not Reconciling

Look up the exact kustomization name first — it is the `metadata.name` in `ks.yaml`, not always `<namespace>-<app>`:

```bash
grep "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml
flux describe kustomization <ks-name> -n <namespace>
```

Common causes:

- `dependsOn` target not Ready — check dependency chain
- Schema validation error — run `just kube render-ks <namespace> <ks-name>` to catch it locally
- Source not synced — `flux reconcile source oci flux-system -n flux-system`

### ExternalSecret Not Syncing / Empty Secret

```bash
kubectl describe externalsecret <app> -n <namespace>
just kube sync-flux es <app>
kubectl get secret <app> -n <namespace> -o yaml
```

Common causes:

- 1Password field name mismatch — exact field name must match template `{{ .FIELD_NAME }}`
- onepassword-connect pod unhealthy — `kubectl get pods -n external-secrets`

### Pod Stuck in ContainerCreating (miroir volume)

```bash
kubectl describe pod <pod> -n <namespace> | grep -A5 Events
```

If you see `rpc error` or `volume attachment`:

```bash
kubectl delete pod -n miroir-system -l app.kubernetes.io/component=agent --field-selector spec.nodeName=<node>
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>
# If still stuck:
talosctl reboot -n <node-ip> --wait
```

### CRD Timing Race (Kustomization fails immediately after new CRDs deployed)

Symptom: resources fail with "no matches for kind X" right after a new CRD-bearing app was added.

Re-trigger once the CRDs are established:

```bash
flux reconcile kustomization <ks-name> -n <namespace>
```

If it is a dependency ordering issue, check `dependsOn` in `ks.yaml` — the CRD provider must be listed.

### Image Pull Errors

```bash
kubectl describe pod <pod> -n <namespace> | grep -A3 "Failed"
```

Verify image tag exists in registry. If rate limited: wait or check imagePullSecret.

### HelmRelease Values Not Applying After Git Change

```bash
flux reconcile helmrelease <app> -n <namespace> --with-source
```

## Step 3 — Force Reconciliation

```bash
grep "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml
flux reconcile kustomization <ks-name> -n <namespace> --with-source
flux reconcile helmrelease <app> -n <namespace>
```

## Step 4 — Verify

```bash
flux get helmrelease <app> -n <namespace>
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl logs -n <namespace> deployment/<app> --tail=20
```
