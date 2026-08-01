set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

kubectl := "kubectl --context artemis"

[private]
default:
    just -l kube

[doc('Apply local Flux Kustomization')]
apply-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | {{ kubectl }} apply --server-side --force-conflicts --field-manager=kustomize-controller -f /dev/stdin

[doc('Browse a PVC')]
browse-pvc ns claim:
    {{ kubectl }} run -n {{ ns }} browse-pvc-{{ claim }} -it --rm --restart=Never \
        --image=mirror.gcr.io/alpine:latest \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"mirror.gcr.io/alpine:latest","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Debug a node')]
[script]
debug-node node:
    trap '{{ kubectl }} delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    {{ kubectl }} debug node/{{ node }} -n default -it --image=mirror.gcr.io/alpine:latest --profile=sysadmin

[doc('Delete local Flux Kustomization')]
delete-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | {{ kubectl }} delete -f /dev/stdin

[doc('Prune pods in Failed, Pending, or Succeeded state')]
[script]
prune-pods:
    for phase in Failed Pending Succeeded; do
        {{ kubectl }} delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true
    done

[doc('Snapshot every kopiur SnapshotPolicy now')]
[script]
snapshot:
    {{ kubectl }} get snapshotpolicies --no-headers -A | while read -r ns name _; do
        kopiur snapshot now --policy "$name" -n "$ns"
    done

[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume Keda ScaledObjects')]
[script]
keda state:
    {{ kubectl }} get scaledobjects --no-headers -A | while read -r ns name _; do
        {{ kubectl }} -n "$ns" annotate --field-manager flux-client-side-apply --overwrite so "$name" autoscaling.keda.sh/paused{{ if state != "suspend" { "-" } else { "=true" } }}
    done

[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume kopiur')]
kopiur state:
    flux -n kopiur-system {{ state }} kustomization kopiur
    flux -n kopiur-system {{ state }} helmrelease kopiur
    {{ kubectl }} -n kopiur-system scale deployment kopiur-controller --replicas {{ if state != "suspend" { "1" } else { "0" } }}

[arg('resource', pattern='hr|ks|gitrepo|ocirepo|es')]
[doc('Sync a resource; optionally filter to a single name')]
[script]
sync resource name='':
    {{ kubectl }} get {{ resource }} --no-headers -A \
        | awk '{{ if name != "" { "$2 == \"" + name + "\"" } else { "1" } }}' \
        | while read -r ns rname _; do
            {{ kubectl }} -n "$ns" annotate --field-manager flux-client-side-apply --overwrite {{ resource }} "$rname" \
                "force-sync=$(date +%s)" \
                "reconcile.fluxcd.io/requestedAt=$(date +%s)" \
                "reconcile.fluxcd.io/forceAt=$(date +%s)"
        done

[doc("Restore a PVC in place from kopiur (offset 0 = latest, 1 = previous, ...)")]
[script]
restore ns app offset='0':
    flux -n {{ ns }} suspend kustomization {{ app }}
    flux -n {{ ns }} suspend helmrelease {{ app }}
    {{ kubectl }} -n {{ ns }} get deploy,sts -l app.kubernetes.io/name={{ app }} -o name \
        | xargs -r -I{} {{ kubectl }} -n {{ ns }} scale {} --replicas=0
    {{ kubectl }} -n {{ ns }} wait pod --for=delete --selector="app.kubernetes.io/name={{ app }}" --timeout=5m
    kopiur restore -n {{ ns }} --from-policy {{ app }} --offset {{ offset }} --to-pvc {{ app }} --wait
    flux -n {{ ns }} resume kustomization {{ app }}
    flux -n {{ ns }} resume helmrelease {{ app }}
    flux -n {{ ns }} reconcile helmrelease {{ app }} --force
    {{ kubectl }} -n {{ ns }} wait pod --for=condition=ready --selector="app.kubernetes.io/name={{ app }}" --timeout=5m

[doc('View a secret')]
view-secret namespace secret:
    {{ kubectl }} view-secret -n {{ namespace }} {{ secret }}

[private]
render-local-ks ns ks:
    flate build ks --namespace "{{ ns }}" --output yaml "{{ ks }}"
