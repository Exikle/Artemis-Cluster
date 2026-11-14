---
name: fix-flux
description: Diagnose and repair a stalled Flux reconciliation — a HelmRelease stuck or not progressing, a Kustomization not reconciling, an OCIRepository not resolving, or an ExternalSecret not syncing. Use for "flux is broken", "HelmRelease stuck", "kustomization not reconciling", "ExternalSecret not syncing", or when flux get shows a resource not ready. Scoped to the Artemis cluster.
---

# Skill: Fix Flux

Diagnose and fix Flux reconciliation issues in home-infra.

> Read `.agents/references/flux-patterns.md` before you diagnose. It covers stuck HelmRelease fixes, cross-namespace gotchas, and the CRD timing race.

Goal: find why one Flux resource is not reconciling and fix that cause.

Success means that the named resource reports Ready with the current revision, and you can say
which cause it was. A retry that made it go green is not enough.

Stop when that resource is Ready. Do NOT `flux delete`. Do NOT delete PVCs or namespaces to
clear a stuck state. Do NOT force-reconcile the flux-system OCIRepository straight after a
push, because that can apply a stale tree mid-build. Escalate to the user instead.

The source is the OCIRepository `flux-system`. There is no GitRepository. App Kustomizations
live in the namespace of their app, not `flux-system`. A fix that changes manifests follows
`.agents/instructions/commit-style.md` § The sequence, in a worktree (`just wt new fix/<slug>`).

## Step 1: Identify What Is Broken

```bash
flux get all -A --status-selector ready=false
kubectl get helmrelease -A | grep -v "True"
kubectl get kustomization -A | grep -v "True"
```

## Step 2: Diagnose by Symptom

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

Look up the exact kustomization name first. It is the `metadata.name` in `ks.yaml`, not always `<namespace>-<app>`:

```bash
grep "^  name:" clusters/artemis/kubernetes/apps/<namespace>/<app>/ks.yaml
flux describe kustomization <ks-name> -n <namespace>
```

Common causes:

- A `dependsOn` target is not Ready. Check the dependency chain.
- A schema validation error. Run `just kube render-ks <namespace> <ks-name>` to catch it locally.
- The source is not synced. Run `flux reconcile source oci flux-system -n flux-system`.

### ExternalSecret Not Syncing / Empty Secret

```bash
kubectl describe externalsecret <app> -n <namespace>
just kube sync-flux es <app>
kubectl get secret <app> -n <namespace> -o yaml
```

Common causes:

- A 1Password field name mismatch. The exact field name must match the template `{{ .FIELD_NAME }}`.
- The onepassword-connect pod is unhealthy. Run `kubectl get pods -n external-secrets`.

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

Symptom: resources fail with "no matches for kind X" right after you add a new CRD-bearing app.

Re-trigger once the CRDs are established:

```bash
flux reconcile kustomization <ks-name> -n <namespace>
```

If the cause is dependency ordering, check `dependsOn` in `ks.yaml`. The CRD provider must be listed.

### Image Pull Errors

```bash
kubectl describe pod <pod> -n <namespace> | grep -A3 "Failed"
```

Make sure that the image tag exists in the registry. If the registry rate limits you, wait or check the imagePullSecret.

### HelmRelease Values Not Applying After Git Change

```bash
flux reconcile helmrelease <app> -n <namespace> --with-source
```

## Step 3: Force Reconciliation

```bash
grep "^  name:" clusters/artemis/kubernetes/apps/<namespace>/<app>/ks.yaml
flux reconcile kustomization <ks-name> -n <namespace> --with-source
flux reconcile helmrelease <app> -n <namespace>
```

## Step 4: Verify

```bash
flux get helmrelease <app> -n <namespace>
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl logs -n <namespace> deployment/<app> --tail=20
```
