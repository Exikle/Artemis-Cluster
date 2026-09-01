set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

kubectl := "kubectl --context artemis"
flux := "flux --context artemis"
root_ks := "artemis-cluster"
root_ns := "flux-system"

[private]
default:
    just -l kube

[doc('Apply local Flux Kustomization (suspends root + target first; resume with resume-ks)')]
[script]
apply-ks ns ks:
    # Suspends root + target first; see .agents/instructions/commit-style.md step 0.
    suspend() {
        local ns="$1" name="$2"
        case "$({{ kubectl }} -n "$ns" get kustomization "$name" -o jsonpath='{.spec.suspend}' 2>/dev/null || echo missing)" in
            true)    echo "  already suspended   $ns/$name" ;;
            missing) return 1 ;;
            *)       {{ flux }} -n "$ns" suspend kustomization "$name" >/dev/null 2>&1 \
                        || { echo "error: could not suspend $ns/$name" >&2; exit 1; }
                     echo "  suspended           $ns/$name" ;;
        esac
    }

    # A missing root means the wrong cluster or context.
    suspend "{{ root_ns }}" "{{ root_ks }}" \
        || { echo "error: root Kustomization {{ root_ns }}/{{ root_ks }} not found — wrong context?" >&2; exit 1; }

    # A missing child is normal when adding an app: its parent has not created it yet.
    suspend "{{ ns }}" "{{ ks }}" \
        || echo "  not in cluster yet  {{ ns }}/{{ ks }} (new Kustomization, nothing to suspend)"

    just kube render-local-ks "{{ ns }}" "{{ ks }}" | {{ kubectl }} apply --server-side --force-conflicts --field-manager=kustomize-controller -f /dev/stdin

    echo
    echo "  Flux is SUSPENDED. Once the change is confirmed, committed and pushed:"
    echo "    just kube sync ocirepo && just kube resume-ks"

[doc('Resume every suspended Flux Kustomization — children first, root last')]
[script]
resume-ks:
    mapfile -t suspended < <(
        {{ kubectl }} get kustomization -A \
            -o jsonpath='{range .items[?(@.spec.suspend==true)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
    )

    if (( ${#suspended[@]} == 0 )); then
        echo "  nothing suspended"
        exit 0
    fi

    # Children first, root last and exactly once — resuming the root while children
    # are still suspended re-triggers the same race this is meant to avoid.
    for target in "${suspended[@]}"; do
        [[ "$target" == "{{ root_ns }}/{{ root_ks }}" ]] && continue
        {{ flux }} -n "${target%%/*}" resume kustomization "${target##*/}" --wait=false >/dev/null 2>&1 \
            || { echo "error: could not resume $target" >&2; exit 1; }
        echo "  resumed  $target"
    done

    for target in "${suspended[@]}"; do
        [[ "$target" == "{{ root_ns }}/{{ root_ks }}" ]] || continue
        {{ flux }} -n "{{ root_ns }}" resume kustomization "{{ root_ks }}" --wait=false >/dev/null 2>&1 \
            || { echo "error: could not resume $target" >&2; exit 1; }
        echo "  resumed  $target (root)"
    done

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

[doc('Check an app can authenticate to Postgres with its client cert (host defaults to direct, bypassing the pooler)')]
[script]
pg-check ns app db='' host='postgres-rw.database.svc':
    db="{{ db }}"
    [[ -n "$db" ]] || db="{{ app }}"
    pod="pg-check-{{ app }}-${RANDOM}"

    # Track the cluster image rather than pinning one here — see
    # .agents/references/postgres-dragonfly.md (read .spec.imageName, never a written version).
    image="$({{ kubectl }} -n database get cluster postgres -o jsonpath='{.spec.imageName}')"
    [[ -n "$image" ]] || { echo "error: could not read postgres cluster image — wrong context?" >&2; exit 1; }

    # runAsUser 0 so the 0600 root-owned tls.key is readable; libpq rejects looser modes.
    overrides="$(cat <<JSON
    {
      "spec": {
        "securityContext": { "runAsUser": 0 },
        "containers": [
          {
            "name": "psql",
            "image": "$image",
            "command": [
              "psql",
              "postgresql://{{ app }}@{{ host }}:5432/$db?sslmode=verify-full&sslcert=/certs/tls.crt&sslkey=/certs/tls.key&sslrootcert=/ca/ca.crt",
              "-tAc",
              "select 'OK  user=' || current_user || '  db=' || current_database()"
            ],
            "volumeMounts": [
              { "name": "certs", "mountPath": "/certs", "readOnly": true },
              { "name": "ca", "mountPath": "/ca", "readOnly": true }
            ]
          }
        ],
        "volumes": [
          { "name": "certs", "secret": { "secretName": "postgres-{{ app }}-cert", "defaultMode": 384 } },
          { "name": "ca", "secret": { "secretName": "postgres-server-ca", "defaultMode": 292 } }
        ]
      }
    }
    JSON
    )"

    {{ kubectl }} run -n {{ ns }} "$pod" --rm --restart=Never --attach --image="$image" --overrides="$overrides"

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
