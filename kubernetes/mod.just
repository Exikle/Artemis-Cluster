set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

context := env('KUBE_CONTEXT', 'artemis')
kubectl := "kubectl --context " + context
flux := "flux --context " + context
kopiur := "kopiur --context " + context
root_ks := "artemis-cluster"
root_ns := "flux-system"
alpine := "mirror.gcr.io/alpine:latest"

[doc('Apply local Flux Kustomization — run suspend-ks first')]
apply-ks ns ks:
    just log info "Applying" ns "{{ ns }}" ks "{{ ks }}"
    just kube render-ks "{{ ns }}" "{{ ks }}" \
        | {{ kubectl }} apply --server-side --force-conflicts --field-manager=kustomize-controller -f -
    just log info "Applied" ns "{{ ns }}" ks "{{ ks }}"

[doc('Browse a PVC')]
browse-pvc ns claim:
    just log info "Browsing PVC, pod is removed on exit" ns "{{ ns }}" pvc "{{ claim }}"
    {{ kubectl }} run -n {{ ns }} browse-pvc-{{ claim }} -it --rm --restart=Never \
        --image={{ alpine }} \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"{{ alpine }}","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Debug a node')]
debug-node node:
    just log info "Debugging node with sysadmin profile, pod is removed on exit" node "{{ node }}"
    trap '{{ kubectl }} delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    {{ kubectl }} debug node/{{ node }} -n default -it --image={{ alpine }} --profile=sysadmin

[doc('Delete local Flux Kustomization — run suspend-ks first')]
delete-ks ns ks:
    just log warn "Deleting" ns "{{ ns }}" ks "{{ ks }}"
    just kube render-ks "{{ ns }}" "{{ ks }}" \
        | {{ kubectl }} delete -f -
    just log info "Deleted" ns "{{ ns }}" ks "{{ ks }}"

[doc('Diff a locally rendered Kustomization against the live cluster — exits 1 if they differ')]
[no-exit-message]
diff-ks ns ks:
    just log info "Diffing against live cluster" ns "{{ ns }}" ks "{{ ks }}"

    # Render first so a bad ks name fails here, not as a phantom "difference".
    rendered="$(just kube render-ks "{{ ns }}" "{{ ks }}")"

    if printf '%s\n' "$rendered" \
        | KUBECTL_EXTERNAL_DIFF="dyff between --omit-header --set-exit-code" \
          {{ kubectl }} diff --server-side --force-conflicts -f -; then
        just log info "No differences" ns "{{ ns }}" ks "{{ ks }}"
    else
        just log warn "Differences found" ns "{{ ns }}" ks "{{ ks }}"
        exit 1
    fi

[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume kopiur — the controller only; the webhook stays up')]
toggle-kopiur state:
    just log info "{{ if state == 'resume' { 'Resuming' } else { 'Suspending' } }} kopiur"

    {{ flux }} -n kopiur-system {{ state }} kustomization kopiur
    {{ flux }} -n kopiur-system {{ state }} helmrelease kopiur

    # The webhook is deliberately left running: its ValidatingWebhookConfiguration
    # stays registered, so scaling it to 0 would fail every kopiur CR write.
    {{ kubectl }} -n kopiur-system scale deployment kopiur-controller \
        --replicas {{ if state == 'resume' { '1' } else { '0' } }}

    just log info "kopiur {{ if state == 'resume' { 'resumed' } else { 'suspended' } }}"

[doc('Check an app can reach Postgres with its own libpq DSN (url key) over sslmode=verify-full')]
check-postgres ns app:
    just log info "Checking Postgres auth" ns "{{ ns }}" app "{{ app }}"
    pod="check-postgres-{{ app }}-${RANDOM}"
    image="$({{ kubectl }} -n database get cluster postgres -o jsonpath='{.spec.imageName}')"

    # `url` only: psql is libpq, so it reads url_prisma's sslcert= as a client cert and has
    # no CA at all for url_node. A driver's DSN can only be validated by that driver.
    overrides="$(cat <<JSON
    { "spec": {
      "securityContext": { "runAsNonRoot": true, "seccompProfile": { "type": "RuntimeDefault" } },
      "containers": [{
        "name": "psql", "image": "$image",
        "command": ["sh", "-c", "psql \"\$PGURL\" -tAc \"select 'OK  user=' || current_user || '  db=' || current_database()\""],
        "env": [{ "name": "PGURL", "valueFrom": { "secretKeyRef": { "name": "{{ app }}-postgres", "key": "url" } } }],
        "securityContext": { "allowPrivilegeEscalation": false, "capabilities": { "drop": ["ALL"] } },
        "volumeMounts": [{ "name": "ca", "mountPath": "/var/run/secrets/postgres-server-ca", "readOnly": true }]
      }],
      "volumes": [{ "name": "ca", "secret": { "secretName": "postgres-server-ca", "defaultMode": 292 } }]
    } }
    JSON
    )"

    # Not --attach --rm: the stream drops under load and the pod can vanish before logs are read.
    trap '{{ kubectl }} delete pod -n {{ ns }} "$pod" --ignore-not-found --wait=false >/dev/null 2>&1' EXIT
    {{ kubectl }} run -n {{ ns }} "$pod" --restart=Never --image="$image" --overrides="$overrides" >/dev/null

    for _ in $(seq 1 60); do
        read -r phase reason < <({{ kubectl }} get pod -n {{ ns }} "$pod" \
            -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null) || true
        case "$phase:$reason" in
            Succeeded:* | Failed:*) break ;;
            # A bad secret never reaches a terminal phase; do not wait out the timeout.
            *:CreateContainerConfigError | *:ErrImagePull | *:InvalidImageName)
                just log fatal "Pod could not start" ns "{{ ns }}" app "{{ app }}" reason "$reason" ;;
        esac
        sleep 2
    done

    {{ kubectl }} logs -n {{ ns }} "$pod" -c psql 2>&1
    [[ "${phase:-}" == "Succeeded" ]] || just log fatal "Auth check failed" app "{{ app }}" phase "${phase:-timeout}"
    just log info "Postgres auth OK" ns "{{ ns }}" app "{{ app }}"

[doc('Delete every pod that is not Running — Succeeded, Failed, Pending or Unknown')]
prune-pods:
    just log info "Pruning pods that are not Running"
    {{ kubectl }} delete pods -A --field-selector='status.phase!=Running' --ignore-not-found=true

[doc('Restore a PVC in place from kopiur (offset 0 = latest, 1 = previous, ...)')]
restore-pvc ns app offset='0':
    selector="app.kubernetes.io/name={{ app }}"
    just log warn "Restoring PVC — the app will be scaled to zero" ns "{{ ns }}" app "{{ app }}" offset "{{ offset }}"

    # On failure the app is left DOWN and Flux suspended on purpose: the volume must stay
    # unmounted to investigate. Resume by hand once the cause is known.
    trap 'just log error "Restore did not finish — app is at 0 replicas and Flux is suspended" ns "{{ ns }}" app "{{ app }}"' ERR

    {{ flux }} -n {{ ns }} suspend kustomization {{ app }}
    {{ flux }} -n {{ ns }} suspend helmrelease {{ app }}

    {{ kubectl }} -n {{ ns }} get deploy,sts -l "$selector" -o name \
        | xargs -r -I{} {{ kubectl }} -n {{ ns }} scale {} --replicas=0
    {{ kubectl }} -n {{ ns }} wait pod --for=delete --selector="$selector" --timeout=5m
    just log info "Workload stopped, volume unmounted" app "{{ app }}"

    {{ kopiur }} restore -n {{ ns }} --from-policy {{ app }} --offset {{ offset }} --to-pvc {{ app }} --wait
    just log info "Data restored" app "{{ app }}" offset "{{ offset }}"

    {{ flux }} -n {{ ns }} resume kustomization {{ app }}
    {{ flux }} -n {{ ns }} resume helmrelease {{ app }}
    {{ flux }} -n {{ ns }} reconcile helmrelease {{ app }} --force

    # rollout status, not `wait --for=condition=ready`: a moment after the reconcile the pod
    # object may not exist yet, and that wait errors "no matching resources found" instead of waiting.
    {{ kubectl }} -n {{ ns }} get deploy,sts -l "$selector" -o name \
        | xargs -r -I{} {{ kubectl }} -n {{ ns }} rollout status {} --timeout=5m
    just log info "Restore complete" ns "{{ ns }}" app "{{ app }}"

[doc('Resume one Flux Kustomization — resume the root first if it is also suspended')]
resume-ks ns ks:
    just log info "Resuming" ns "{{ ns }}" ks "{{ ks }}"

    # Refuse to wake a child while the root is still suspended. The child would reconcile its
    # OLD spec and write stale values straight back — that regrew 13 PVCs to 5Gi on 2026-09-06
    # (#1997), and allowVolumeExpansion made it one-way. Resuming the root is a separate call.
    if [[ "{{ ns }}/{{ ks }}" != "{{ root_ns }}/{{ root_ks }}" ]]; then
        root="$({{ kubectl }} -n {{ root_ns }} get kustomization {{ root_ks }} \
            -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
        [[ "$root" != "true" ]] || just log fatal \
            "Root still suspended, resume it first: just kube resume-ks {{ root_ns }} {{ root_ks }}"
    fi

    {{ flux }} -n {{ ns }} resume kustomization {{ ks }} --timeout 10m \
        || just log fatal "Could not resume" ns "{{ ns }}" ks "{{ ks }}"
    just log info "Resumed" ns "{{ ns }}" ks "{{ ks }}"

    # Narrow by design, but never leave anything suspended silently.
    left="$({{ kubectl }} get kustomization -A \
        -o jsonpath='{range .items[?(@.spec.suspend==true)]}{.metadata.namespace}/{.metadata.name} {end}')"
    [[ -z "$left" ]] || just log warn "Still suspended — resume these too" targets "$left"

[doc('Snapshot kopiur SnapshotPolicies now — one policy, a whole namespace, or all if no args')]
snapshot-pvc ns='' policy='':
    [[ -z "{{ policy }}" || -n "{{ ns }}" ]] \
        || just log fatal "A policy needs a namespace: just kube snapshot-pvc <ns> <policy>"

    if [[ -n "{{ policy }}" ]]; then
        just log info "Snapshotting" ns "{{ ns }}" policy "{{ policy }}"
        {{ kopiur }} snapshot now --policy "{{ policy }}" -n "{{ ns }}"
        exit 0
    fi

    scope=(-A)
    [[ -z "{{ ns }}" ]] || scope=(-n "{{ ns }}")

    n=0
    while read -r pns pname; do
        [[ -n "$pname" ]] || continue
        just log info "Snapshotting" ns "$pns" policy "$pname"
        {{ kopiur }} snapshot now --policy "$pname" -n "$pns"
        n=$((n + 1))
    done < <({{ kubectl }} get snapshotpolicies "${scope[@]}" --no-headers \
        -o custom-columns=':.metadata.namespace,:.metadata.name')

    just log info "Snapshots requested" count "$n"

[doc('Suspend one Flux Kustomization — suspend the root separately, or it reverts your edits')]
suspend-ks ns ks:
    just log info "Suspending" ns "{{ ns }}" ks "{{ ks }}"

    case "$({{ kubectl }} -n {{ ns }} get kustomization {{ ks }} -o jsonpath='{.spec.suspend}' 2>/dev/null || echo missing)" in
        true) just log info "Already suspended" ns "{{ ns }}" ks "{{ ks }}" ;;
        missing)
            [[ "{{ ns }}/{{ ks }}" != "{{ root_ns }}/{{ root_ks }}" ]] \
                || just log fatal "Root Kustomization not found — wrong context?" ns "{{ ns }}" ks "{{ ks }}"
            just log warn "Not in cluster yet, nothing to suspend" ns "{{ ns }}" ks "{{ ks }}" ;;
        *)
            {{ flux }} -n {{ ns }} suspend kustomization {{ ks }} >/dev/null 2>&1 \
                || just log fatal "Could not suspend" ns "{{ ns }}" ks "{{ ks }}"
            just log info "Suspended" ns "{{ ns }}" ks "{{ ks }}" ;;
    esac

    # Suspending the root is a separate call. Left running it reconciles on its own interval
    # and silently reverts the uncommitted edits apply-ks just wrote. Warn, do not act.
    if [[ "{{ ns }}/{{ ks }}" != "{{ root_ns }}/{{ root_ks }}" ]]; then
        root="$({{ kubectl }} -n {{ root_ns }} get kustomization {{ root_ks }} \
            -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
        [[ "$root" == "true" ]] || just log warn \
            "Root NOT suspended, it will revert your edits: just kube suspend-ks {{ root_ns }} {{ root_ks }}"
    fi

[arg('resource', pattern='hr|ks|gitrepo|ocirepo|es')]
[doc('Sync a resource; optionally filter to a single name')]
sync-flux resource name='':
    filter="{{ name }}"
    {{ kubectl }} get {{ resource }} --no-headers -A | while read -r ns rname _; do
        [[ -n "$filter" && "$rname" != "$filter" ]] && continue
        {{ kubectl }} -n "$ns" annotate --field-manager flux-client-side-apply --overwrite {{ resource }} "$rname" \
            "force-sync=$(date +%s)" \
            "reconcile.fluxcd.io/requestedAt=$(date +%s)" \
            "reconcile.fluxcd.io/forceAt=$(date +%s)"
    done

[doc('View a secret with every value base64-decoded')]
view-secret ns secret:
    {{ kubectl }} get secret -n {{ ns }} {{ secret }} -o yaml | yq '.data | map_values(@base64d)'

[private]
render-ks ns ks:
    flate build ks --namespace "{{ ns }}" --output yaml "{{ ks }}"
