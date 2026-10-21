# KubePersistentVolumeFillingUp: apoci PVC (fediverse)

Seen once, 2026-09-28 (critical, from 03:42 EDT). Not auto-fixable: the skill must not touch PVCs.

- `apoci` PVC in `fediverse`, `miroir` class, 15Gi, RWO. Pod healthy, no restarts.
- The alert text ("0.08% free") comes from `predict_linear(kubelet_volume_stats_available_bytes[6h], 4*3600) < 0`, not from the current reading. Check `kubelet_volume_stats_used_bytes` / `kubelet_volume_stats_available_bytes` for the real figure: 13.47 GiB used, 1.19 GiB free (8%), flat for the last 1h45m after a ~500 MB media burst.
- If used bytes keep climbing between runs, the disk can fill within about an hour; say so in `items`.
- Operator actions: grow the PVC `spec.resources.requests.storage` (confirm the miroir class allows expansion), or clear the media cache with the sidekiq `media:cleanup` task.

The PVC is still 15Gi at 2026-10-21 and the alert is not firing. No recurrence log is kept for it.
