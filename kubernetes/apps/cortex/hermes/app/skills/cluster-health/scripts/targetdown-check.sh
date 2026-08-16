#!/usr/bin/env bash
# TargetDown triage probe for the Artemis cluster.
# Usage: targetdown-check.sh <job>          (e.g. smartctl-exporter)
# Queries VictoriaMetrics for up{job=...} and vmagent for per-target scrapeUrl/health/lastError.
# Scanner-safe: no pipes — curl writes to files, python parses the files.
set -euo pipefail
JOB="${1:?usage: targetdown-check.sh <job>}"
VM="http://victoria-metrics-server.observability.svc.cluster.local:8428"
AGENT="http://vmagent-vmagent.observability.svc.cluster.local:8429"

curl -s -G --max-time 20 "$VM/api/v1/query" --data-urlencode "query=up{job=\"$JOB\"}" \
  -o /tmp/up.json -w 'vm query      HTTP %{http_code}\n'
curl -s -G --max-time 20 "$AGENT/api/v1/targets" --data-urlencode 'state=any' \
  -o /tmp/targets.json -w 'vmagent list  HTTP %{http_code}\n'

python3 - "$JOB" <<'EOF'
import json, sys
job = sys.argv[1]

print('--- up{job=...} ---')
try:
    d = json.load(open('/tmp/up.json'))
    for r in d.get('data', {}).get('result', []):
        m = r['metric']
        extra = {k: v for k, v in m.items()
                 if k not in ('__name__', 'job', 'cluster', 'prometheus', 'instance')}
        print(f"{m.get('instance'):<14} up={r['value'][1]}  {extra}")
except Exception as e:
    print('could not parse up.json:', e)

print('--- targets ---')
try:
    t = json.load(open('/tmp/targets.json'))
    hits = [x for x in t.get('data', {}).get('activeTargets', [])
            if x.get('labels', {}).get('job') == job]
    if not hits:
        print(f'no active targets for job={job}')
    for x in hits:
        print(f"{x.get('scrapeUrl')}  [{x.get('health')}]")
        err = x.get('lastError') or ''
        if err:
            print('   lastError:', err[:300])
except Exception as e:
    print('could not parse targets.json:', e)
EOF
