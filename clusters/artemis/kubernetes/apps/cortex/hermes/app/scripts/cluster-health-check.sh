#!/usr/bin/env bash
set -u

STATE="${STATE_DIR:-/opt/data/workspace/cluster-health}"
AM="${ALERTMANAGER_URL:-http://alertmanager.observability.svc.cluster.local:9093}"
VM="${VM_URL:-http://victoria-metrics-server.observability.svc.cluster.local:8428}"
CHASKI="${CHASKI_URL:-http://chaski.observability.svc.cluster.local:8080}"
DRY_RUN="${DRY_RUN:-0}"
QUIET_INTERVAL=14400
WAKE_INTERVAL=14400
PENDING_GRACE=600

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KEYS="$WORK/keys"
LINES="$WORK/lines"
: > "$KEYS"
: > "$LINES"

finding() {
  printf '%s\n' "$1" >> "$KEYS"
  printf -- '- %s\n' "$2" >> "$LINES"
}

records() {
  sed "s/{\"$2\":/\n&/g" "$1" | grep "^{\"$2\"" || true
}

label() {
  printf '%s' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
}

scalar() {
  sed -n 's/.*"value":\[[0-9.]*,"\([^"]*\)"\].*/\1/p' "$1" 2> /dev/null | head -n 1
}

query() {
  local out="$WORK/q-$1.json"
  curl -s --max-time 20 -G "$VM/api/v1/query" --data-urlencode "query=$2" -o "$out" 2> /dev/null
  grep -q '"status":"success"' "$out" 2> /dev/null
}

write_state() {
  printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

number_or_zero() {
  case "$1" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

check_alerts() {
  local f="$WORK/alerts.json" rec labels name sev ns what fp starts
  if ! curl -sf --max-time 20 "$AM/api/v2/alerts?active=true&silenced=false&inhibited=false&unprocessed=true" -o "$f" 2> /dev/null \
    || [ "$(head -c 1 "$f")" != "[" ]; then
    finding "check-failed:alertmanager" "check-failed: alertmanager unreachable or returned bad data"
    return
  fi
  while IFS= read -r rec; do
    labels="$(printf '%s' "$rec" | sed -n 's/.*"labels":{\([^}]*\)}.*/\1/p')"
    name="$(label alertname "$labels")"
    [ "$name" = "Watchdog" ] && continue
    sev="$(label severity "$labels")"
    ns="$(label namespace "$labels")"
    what="$(label pod "$labels")"
    [ -z "$what" ] && what="$(label job "$labels")"
    [ -z "$what" ] && what="$(label instance "$labels")"
    [ -z "$what" ] && what="$(label node "$labels")"
    fp="$(label fingerprint "$rec")"
    starts="$(label startsAt "$rec")"
    finding "alert:$fp" "alert $name severity=${sev:-none} ns=${ns:--} target=${what:--} since $starts"
  done < <(records "$f" annotations)
}

check_nodes() {
  local rec
  if query notready 'kube_node_status_condition{condition="Ready",status="true"} == 0'; then
    while IFS= read -r rec; do
      finding "node-notready:$(label node "$rec")" "node $(label node "$rec") is not Ready"
    done < <(records "$WORK/q-notready.json" metric)
  else
    finding "check-failed:node-ready" "check-failed: node Ready query failed"
  fi
  if query pressure 'kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure",status="true"} == 1'; then
    while IFS= read -r rec; do
      finding "node-pressure:$(label node "$rec"):$(label condition "$rec")" "node $(label node "$rec") has $(label condition "$rec")"
    done < <(records "$WORK/q-pressure.json" metric)
  else
    finding "check-failed:node-pressure" "check-failed: node pressure query failed"
  fi
  if query ready 'count(kube_node_status_condition{condition="Ready",status="true"} == 1)'; then
    NODES_READY="$(scalar "$WORK/q-ready.json")"
  fi
  if query total 'count(kube_node_status_condition{condition="Ready",status="true"})'; then
    NODES_TOTAL="$(scalar "$WORK/q-total.json")"
  fi
}

check_pending() {
  local rec
  if query pending "kube_pod_status_phase{phase=\"Pending\"} == 1 and on(namespace,pod) ((time() - kube_pod_created) > $PENDING_GRACE)"; then
    while IFS= read -r rec; do
      finding "pod-pending:$(label namespace "$rec")/$(label pod "$rec")" "pod $(label namespace "$rec")/$(label pod "$rec") Pending for over $((PENDING_GRACE / 60))m"
    done < <(records "$WORK/q-pending.json" metric)
  else
    finding "check-failed:pods-pending" "check-failed: pending pods query failed"
  fi
}

check_targets() {
  local rec
  if query down 'up == 0 or absent(up{job="smartctl-exporter",instance="pantheon"})'; then
    while IFS= read -r rec; do
      finding "target-down:$(label job "$rec")/$(label instance "$rec")" "scrape target down: job=$(label job "$rec") instance=$(label instance "$rec")"
    done < <(records "$WORK/q-down.json" metric)
  else
    finding "check-failed:targets" "check-failed: scrape target query failed"
  fi
  if query smartup 'count(up{job="smartctl-exporter"} == 1)' && query smarttotal 'count(up{job="smartctl-exporter"})'; then
    SMART_UP="$(scalar "$WORK/q-smartup.json")"
    SMART_TOTAL="$(scalar "$WORK/q-smarttotal.json")"
  fi
}

send_quiet() {
  local payload="$WORK/quiet.json" code items summary
  summary="No findings: ${NODES_READY:-?}/${NODES_TOTAL:-?} nodes Ready, no alerts firing, no stuck pods, all scrape targets up."
  items="\"${NODES_READY:-?}/${NODES_TOTAL:-?} nodes Ready, no pressure\""
  if [ -n "${SMART_UP:-}" ]; then
    items="$items,\"smartctl-exporter up ${SMART_UP}/${SMART_TOTAL:-?} incl. static instance pantheon\""
  fi
  printf '{"skill":"cluster-health","status":"ok","summary":"%s","stats":{"alerts":0,"resolved":0,"fixed":0,"attention":0},"items":[%s],"url":"https://alertmanager.dcunha.io/alerts"}\n' \
    "$summary" "$items" > "$payload"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN: would POST to $CHASKI/hooks/info:"
    cat "$payload"
    return 0
  fi
  code="$(curl -s --max-time 15 -X POST -H 'Content-Type: application/json' --data "@$payload" -o /dev/null -w '%{http_code}' "$CHASKI/hooks/info" 2> /dev/null)"
  echo "chaski quiet notification: HTTP $code"
  [ "$code" = "200" ]
}

NODES_READY=""
NODES_TOTAL=""
SMART_UP=""
SMART_TOTAL=""
mkdir -p "$STATE" 2> /dev/null || echo "warning: cannot create $STATE, dedupe state disabled"

NOW="$(date +%s)"
echo "cluster-health pre-check $(date -u +%Y-%m-%dT%H:%MZ)"

check_alerts
check_nodes
check_pending
check_targets

echo "nodes Ready: ${NODES_READY:-?}/${NODES_TOTAL:-?}"
COUNT="$(grep -c . "$KEYS")"

if [ "$COUNT" -eq 0 ]; then
  echo "findings: none"
  last="$(number_or_zero "$(cat "$STATE/last-quiet-notify" 2> /dev/null)")"
  if [ $((NOW - last)) -ge "$QUIET_INTERVAL" ]; then
    if send_quiet; then
      write_state "$STATE/last-quiet-notify" "$NOW"
    else
      echo "quiet notification failed, will retry next run"
    fi
  else
    echo "quiet notification sent $(((NOW - last) / 60))m ago, next after $((QUIET_INTERVAL / 3600))h"
  fi
  echo '{"wakeAgent": false}'
  exit 0
fi

FP="$(LC_ALL=C sort "$KEYS" | sha256sum | cut -c1-16)"
echo "findings: $COUNT"
cat "$LINES"
echo "fingerprint: $FP"

last_ts=0
last_fp=""
if [ -r "$STATE/last-wake" ]; then
  read -r last_ts last_fp < "$STATE/last-wake" || true
fi
last_ts="$(number_or_zero "$last_ts")"
if [ "$FP" = "$last_fp" ] && [ $((NOW - last_ts)) -lt "$WAKE_INTERVAL" ]; then
  echo "result: same findings as the run woken $(((NOW - last_ts) / 60))m ago, agent skipped"
  echo '{"wakeAgent": false}'
  exit 0
fi

write_state "$STATE/last-wake" "$NOW $FP"
echo "result: new or stale findings, waking agent"
exit 0
