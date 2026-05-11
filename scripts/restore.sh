#!/usr/bin/env bash
# =============================================================================
# scripts/restore.sh — Frappe site restore
#
# Restores a site from a bench backup set (SQL dump + optional files archive).
# Designed for a dedicated brand VPS — auto-detects the brand compose file.
#
# Usage:
#   ./scripts/restore.sh --site SITE_NAME --sql /path/to/dump.sql.gz \
#     [--files /path/to/files.tar]
#
# WARNING: Overwrites the existing site database. Always back up first.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

SITE_NAME=""
SQL_FILE=""
FILES_TAR=""

# Load .env
BRAND_ENV=$(find "$REPO_DIR/brands" -name ".env" -maxdepth 2 2>/dev/null | head -1 || true)
[[ -f "$BRAND_ENV" ]] && source "$BRAND_ENV"

COMPOSE_FILE=$(find "$REPO_DIR/brands" -name "docker-compose.yml" -maxdepth 2 2>/dev/null | head -1 || true)
if [[ -z "$COMPOSE_FILE" ]]; then
  echo "ERROR: No brand docker-compose.yml found." >&2
  exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
  echo "Usage: $0 --site SITE_NAME --sql /path/to/dump.sql.gz [--files /path/to/files.tar]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --site)  SITE_NAME="$2"; shift 2 ;;
    --sql)   SQL_FILE="$2"; shift 2 ;;
    --files) FILES_TAR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$SITE_NAME" ]] && { echo "ERROR: --site required"; usage; }
[[ -z "$SQL_FILE" ]]  && { echo "ERROR: --sql required"; usage; }
[[ ! -f "$SQL_FILE" ]] && { echo "ERROR: SQL file not found: $SQL_FILE"; exit 1; }

log "Restoring $SITE_NAME from $SQL_FILE ..."
log "Compose file: $COMPOSE_FILE"

CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps -q backend | head -1)
[[ -z "$CONTAINER" ]] && { log "ERROR: backend container not running"; exit 1; }

log "Copying SQL dump into container ..."
docker cp "$SQL_FILE" "$CONTAINER:/tmp/restore.sql.gz"

if [[ -n "$FILES_TAR" && -f "$FILES_TAR" ]]; then
  log "Copying files archive into container ..."
  docker cp "$FILES_TAR" "$CONTAINER:/tmp/restore-files.tar"
fi

log "Running bench restore ..."
if [[ -n "$FILES_TAR" && -f "$FILES_TAR" ]]; then
  docker compose -f "$COMPOSE_FILE" exec -T backend \
    bench --site "$SITE_NAME" restore \
      --mariadb-root-password "${DB_ROOT_PASSWORD}" \
      --with-public-files /tmp/restore-files.tar \
      --with-private-files /tmp/restore-files.tar \
      /tmp/restore.sql.gz
else
  docker compose -f "$COMPOSE_FILE" exec -T backend \
    bench --site "$SITE_NAME" restore \
      --mariadb-root-password "${DB_ROOT_PASSWORD}" \
      /tmp/restore.sql.gz
fi

log "Running migrations after restore ..."
docker compose -f "$COMPOSE_FILE" exec -T backend \
  bench --site "$SITE_NAME" migrate

log "Clearing cache ..."
docker compose -f "$COMPOSE_FILE" exec -T backend \
  bench --site "$SITE_NAME" clear-cache

log "Restore complete. Verify the site at https://$SITE_NAME"
