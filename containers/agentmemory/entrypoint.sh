#!/bin/sh
# agentmemory entrypoint — supports both Docker Compose (root) and k8s (non-root).
# When running as root: chowns /data, writes iii-config, then execs via gosu.
# When running as non-root (k8s): skips chown/gosu, relies on fsGroup for /data ownership.
set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
HMAC_FILE="${AGENTMEMORY_HMAC_FILE:-/data/.hmac}"
RUN_AS="node:node"
III_CONFIG="/opt/agentmemory/node_modules/@agentmemory/agentmemory/dist/iii-config.yaml"

IS_ROOT="$([ "$(id -u)" = "0" ] && echo true || echo false)"

if [ "$IS_ROOT" = "true" ]; then
  mkdir -p "$DATA_DIR"
  chown -R "$RUN_AS" "$DATA_DIR"
else
  mkdir -p "$DATA_DIR" 2>/dev/null || true
fi

cat > "$III_CONFIG" <<'EOF'
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 180000
      cors:
        allowed_origins:
          - "http://localhost:3111"
          - "http://localhost:3113"
          - "http://127.0.0.1:3111"
          - "http://127.0.0.1:3113"
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/state_store.db
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: 3112
      host: 0.0.0.0
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/stream_store
  - name: iii-observability
    config:
      enabled: true
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 1.0
      metrics_enabled: true
      logs_enabled: true
      logs_console_output: true
EOF

[ "$IS_ROOT" = "true" ] && chown "$RUN_AS" "$III_CONFIG"

# Prefer AGENTMEMORY_SECRET from environment (k8s ExternalSecret injection).
# Fall back to auto-generated file-based HMAC for non-k8s deployments.
if [ -z "${AGENTMEMORY_SECRET:-}" ]; then
  if [ ! -s "$HMAC_FILE" ]; then
    SECRET="$(openssl rand -hex 32)"
    umask 077
    printf '%s\n' "$SECRET" > "$HMAC_FILE"
    chmod 600 "$HMAC_FILE"
    [ "$IS_ROOT" = "true" ] && chown "$RUN_AS" "$HMAC_FILE"
    echo "agentmemory: generated HMAC secret on first boot (stored at $HMAC_FILE)"
  fi
  AGENTMEMORY_SECRET="$(cat "$HMAC_FILE")"
  export AGENTMEMORY_SECRET
else
  echo "agentmemory: using AGENTMEMORY_SECRET from environment"
fi

if [ "$IS_ROOT" = "true" ]; then
  exec gosu "$RUN_AS" agentmemory "$@"
else
  exec agentmemory "$@"
fi
