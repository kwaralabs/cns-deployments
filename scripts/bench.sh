#!/usr/bin/env bash
# =============================================================================
# scripts/bench.sh — run bench commands inside the backend container
#
# Auto-detects the brand compose file on this dedicated VPS.
#
# Usage:
#   ./scripts/bench.sh --site erp.brazenhalo.com console
#   ./scripts/bench.sh --site erp.brazenhalo.com migrate
#   ./scripts/bench.sh --site all list-apps
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

COMPOSE_FILE=$(find "$REPO_DIR/brands" -name "docker-compose.yml" -maxdepth 2 2>/dev/null | head -1 || true)
if [[ -z "$COMPOSE_FILE" ]]; then
  echo "ERROR: No brand docker-compose.yml found." >&2
  exit 1
fi

exec docker compose -f "$COMPOSE_FILE" exec backend bench "$@"
