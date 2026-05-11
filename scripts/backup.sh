#!/usr/bin/env bash
# =============================================================================
# scripts/backup.sh — Frappe site backup
#
# Designed to run on a dedicated brand VPS.
# No --brand flag needed — there is exactly one brand per VPS.
#
# Usage:
#   ./scripts/backup.sh [--site SITE_NAME] [--push] [--prune]
#
# Options:
#   --site NAME   Back up a specific site (default: all sites)
#   --push        Upload to rclone remote after backup
#   --prune       Remove local backups older than BACKUP_RETENTION_DAYS
#
# Prerequisites:
#   - docker / docker compose available
#   - .env sourced or environment variables already set
#   - rclone configured on this VPS if using --push
#
# Cron example (runs daily at 02:00):
#   0 2 * * * root /opt/cns-deployments/scripts/backup.sh --push --prune \
#     >> /var/log/cns-backup.log 2>&1
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${REPO_DIR}/backups/${TIMESTAMP}"
SITE_NAME="all"
DO_PUSH=false
DO_PRUNE=false

# Load .env from the brand directory if present
# On a dedicated VPS, there is only one brand — find it automatically.
BRAND_ENV=$(find "$REPO_DIR/brands" -name ".env" -maxdepth 2 2>/dev/null | head -1 || true)
if [[ -f "$BRAND_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$BRAND_ENV"
fi

RCLONE_REMOTE="${BACKUP_RCLONE_REMOTE:-s3-backups}"
REMOTE_PATH="${BACKUP_REMOTE_PATH:-cns-backups/unknown}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# Find the brand compose file
COMPOSE_FILE=$(find "$REPO_DIR/brands" -name "docker-compose.yml" -maxdepth 2 2>/dev/null | head -1 || true)
if [[ -z "$COMPOSE_FILE" ]]; then
  echo "ERROR: No brand docker-compose.yml found under brands/." >&2
  exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
  echo "Usage: $0 [--site SITE_NAME] [--push] [--prune]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --site)  SITE_NAME="$2"; shift 2 ;;
    --push)  DO_PUSH=true; shift ;;
    --prune) DO_PRUNE=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

mkdir -p "$BACKUP_DIR"
log "Backup starting → $BACKUP_DIR"
log "Compose file: $COMPOSE_FILE"

# Run bench backup inside the backend container
if [[ "$SITE_NAME" == "all" ]]; then
  docker compose -f "$COMPOSE_FILE" exec -T backend \
    bench --site all backup --with-files
else
  docker compose -f "$COMPOSE_FILE" exec -T backend \
    bench --site "$SITE_NAME" backup --with-files
fi

# Copy backup files out of the sites volume to the local backups/ directory
SITES_VOLUME_NAME=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null \
  | python3 -c "import sys,json; c=json.load(sys.stdin); print(list(v['name'] for k,v in c.get('volumes',{}).items() if 'sites' in k)[0])" 2>/dev/null || true)

if [[ -n "$SITES_VOLUME_NAME" ]]; then
  MOUNT=$(docker volume inspect "$SITES_VOLUME_NAME" --format '{{ .Mountpoint }}' 2>/dev/null || true)
  if [[ -n "$MOUNT" ]]; then
    find "$MOUNT" -path "*/private/backups/*" \( -name "*.sql.gz" -o -name "*.tar" \) \
      -newer "$REPO_DIR/backups" 2>/dev/null | while read -r f; do
        cp "$f" "$BACKUP_DIR/"
        log "Copied: $(basename "$f")"
      done
  fi
fi

log "Backup files in: $BACKUP_DIR"
ls -lh "$BACKUP_DIR" 2>/dev/null || true

# Push to remote
if $DO_PUSH; then
  if ! command -v rclone &>/dev/null; then
    log "ERROR: rclone not found. Install and configure rclone on this VPS."
    exit 1
  fi
  log "Pushing to $RCLONE_REMOTE:$REMOTE_PATH/${TIMESTAMP} ..."
  rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE:$REMOTE_PATH/${TIMESTAMP}" \
    --progress --transfers=4
  log "Push complete."
fi

# Prune old local backups
if $DO_PRUNE; then
  log "Pruning local backups older than ${RETENTION_DAYS} days ..."
  find "$REPO_DIR/backups" -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" \
    -exec rm -rf {} + 2>/dev/null || true
  log "Prune complete."
fi

log "Backup finished."
