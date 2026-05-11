#!/bin/bash
# nginx-entrypoint.sh — renders nginx config from env vars and starts nginx

set -euo pipefail

TEMPLATE=$(find /home/frappe/frappe-bench/apps/frappe -name "nginx-default.conf.template" 2>/dev/null | head -1 || true)

if [[ -z "$TEMPLATE" ]]; then
  echo "[nginx-entrypoint] ERROR: Could not find nginx-default.conf.template in frappe app." >&2
  exit 1
fi

export BACKEND="${BACKEND:-backend:8000}"
export SOCKETIO="${SOCKETIO:-websocket:9000}"
export FRAPPE_SITE_NAME_HEADER="${FRAPPE_SITE_NAME_HEADER:-\$host}"
export UPSTREAM_REAL_IP_ADDRESS="${UPSTREAM_REAL_IP_ADDRESS:-127.0.0.1}"
export UPSTREAM_REAL_IP_HEADER="${UPSTREAM_REAL_IP_HEADER:-X-Forwarded-For}"
export UPSTREAM_REAL_IP_RECURSIVE="${UPSTREAM_REAL_IP_RECURSIVE:-off}"
export PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-120}"
export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"

echo "[nginx-entrypoint] Rendering nginx config from $TEMPLATE ..."
envsubst \
  '${BACKEND} ${SOCKETIO} ${FRAPPE_SITE_NAME_HEADER} ${UPSTREAM_REAL_IP_ADDRESS} ${UPSTREAM_REAL_IP_HEADER} ${UPSTREAM_REAL_IP_RECURSIVE} ${PROXY_READ_TIMEOUT} ${CLIENT_MAX_BODY_SIZE}' \
  < "$TEMPLATE" > /etc/nginx/conf.d/default.conf

echo "[nginx-entrypoint] Starting nginx ..."
exec nginx -g "daemon off;"
