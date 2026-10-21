# EtcdDatabaseHighFragmentationRatio triage

## Key insight: the ratio denominator

The alert says "X% of the actual allocated disk space". The live ratio `etcd_mvcc_db_total_size_in_use_in_bytes / etcd_mvcc_db_total_size_in_bytes` uses a different denominator, so the live number (~31-37%) looks fine while the alert (~63-67%) still trips its 50% threshold. Both are consistent: the gap is fragmented space etcd still reserves.

```bash
curl -s -G 'http://victoria-metrics-server.observability.svc.cluster.local:8428/api/v1/query' \
  --data-urlencode 'query=etcd_mvcc_db_total_size_in_use_in_bytes/etcd_mvcc_db_total_size_in_bytes' \
  -o /tmp/etcd.json -w '%{http_code}\n'
```

## Classification and fix

Not auto-fixable. The operator runs `etcdctl defrag` on each member, one at a time so quorum holds (Talos: via `talosctl` on the control-plane node). The agent has no access to etcd.

## History

Fired on talos-cp-01/02/03 together for ~18.6 h from 2026-09-22 and was RESOLVED 2026-09-23 08:02Z (in-use/total ratio jumped from ~31-37% to ~85% after a defrag; it cleared in the same window as the kube-apiserver TargetDown). No open case at 2026-10-21. If it fires again, append recurrence entries per `SKILL.md` § Documented cases. Older entries: `/opt/data/workspace/cluster-health/archive/etcd-triage.full.md`.
