# Skill: Fix Flux

Diagnose and fix Flux reconciliation issues in Artemis-Cluster.

> Read `.agents/references/flux-patterns.md` before diagnosing — it covers stuck HelmRelease fixes, cross-namespace gotchas, and the CRD timing race.

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

```bash
flux describe kustomization <namespace>-<app> -n flux-system
```

Common causes:

- `dependsOn` target not Ready — check dependency chain
- Schema validation error — run `mise exec -- flux-local test kubernetes/apps/<namespace>/<app>/app`
- Git source not synced — `flux reconcile source git flux-system`

### ExternalSecret Not Syncing / Empty Secret

```bash
kubectl describe externalsecret <app> -n <namespace>
mise exec -- just kube sync-es
kubectl get secret <app> -n <namespace> -o yaml
```

Common causes:

- 1Password field name mismatch — exact field name must match template `{{ .FIELD_NAME }}`
- onepassword-connect pod unhealthy — `kubectl get pods -n external-secrets`

### Pod Stuck in ContainerCreating (RBD CSI)

```bash
kubectl describe pod <pod> -n <namespace> | grep -A5 Events
```

If you see `rpc error` or `volume attachment`:

```bash
kubectl delete pod -n rook-ceph -l app=csi-rbdplugin --field-selector spec.nodeName=<node>
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>
# If still stuck:
talosctl reboot -n <node-ip> --wait
```

### Image Pull Errors

```bash
kubectl describe pod <pod> -n <namespace> | grep -A3 "Failed"
```

Verify image tag exists in registry. If rate limited: wait or check imagePullSecret.

### HelmRelease Values Not Applying After Git Change

```bash
flux reconcile helmrelease <app> -n <namespace> --with-source
```

## Step 3 — Force Full Reconciliation

```bash
mise exec -- just kube sync-git
mise exec -- flux reconcile kustomization <namespace>-<app> -n flux-system --with-source
mise exec -- flux reconcile helmrelease <app> -n <namespace>
```

## Step 4 — Verify

```bash
flux get helmrelease <app> -n <namespace>
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl logs -n <namespace> deployment/<app> --tail=20
```

## Nuclear Option — Full Namespace Reconcile

Only if multiple apps in a namespace are broken:

```bash
flux reconcile kustomization <namespace> -n flux-system --with-source
```
