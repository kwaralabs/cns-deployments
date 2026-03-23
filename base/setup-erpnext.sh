#!/bin/bash
###############################################################################
#
#  ERPNext v16 — Production Setup via Frappe Docker
#
#  Tested: March 2026, Ubuntu 24.04 LTS, Contabo VPS
#  Reference: https://github.com/frappe/frappe_docker
#             docs/single-server-example.md
#
#  Architecture:
#    Traefik (central reverse proxy + Let's Encrypt)
#      └── MariaDB (shared database)
#      └── ERPNext Bench (per-client: backend, frontend, redis, workers)
#
#  Key design decisions (learned the hard way):
#
#    1. compose.yaml is NEVER edited.
#       It reads CUSTOM_IMAGE, CUSTOM_TAG, PULL_POLICY from env vars.
#
#    2. example.env contains SITES_RULE=Host(`erp.example.com`).
#       This is what Traefik uses for routing. It MUST be sed-replaced.
#
#    3. SITES, ROUTER, BENCH_NETWORK do NOT exist in example.env.
#       They must be APPENDED with echo >>.
#
#    4. Traefik password hashes contain $ signs.
#       Docker Compose interprets $ as variables — escape as $$.
#
#    5. --no-mariadb-socket is deprecated in Frappe v16.
#       Use --mariadb-user-host-login-scope='%' instead.
#
#    6. Python/Node build args are omitted.
#       The Containerfile has correct defaults per branch.
#
#  USAGE:
#    1. Point DNS A record to your server IP
#    2. Edit the CONFIGURATION section below
#    3. Run as root on a fresh Ubuntu 24.04 VPS:
#         chmod +x setup-erpnext.sh
#         ./setup-erpnext.sh
#    4. Save the passwords printed at the end
#
###############################################################################

set -euo pipefail

###############################################################################
# CONFIGURATION — EDIT THESE
###############################################################################

SITE_DOMAIN="boujeeboyzjerky.collabnscale.io"
TRAEFIK_DOMAIN="traefik.cns-srv1.collabnscale.com"
LETSENCRYPT_EMAIL="admin@collabnscale.com"
PROJECT_NAME="boujeeboyz-one"
IMAGE_NAME="customapp"
IMAGE_TAG="1.0.0"
FRAPPE_BRANCH="version-16"
FRAPPE_USER="frappe"

# Apps to bake into the image. Add more as needed:
#   {"url": "https://github.com/frappe/hrms", "branch": "version-16"},
#   {"url": "https://github.com/frappe/payments", "branch": "version-16"}
APPS_JSON='[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "version-16"
  }
]'

###############################################################################
# INTERNALS — DO NOT EDIT
###############################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

FRAPPE_HOME="/home/${FRAPPE_USER}"
ENV_FILE="${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env"
YAML_FILE="${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml"
PASS_FILE="${FRAPPE_HOME}/passwords/${PROJECT_NAME}-credentials.txt"

###############################################################################
step "PHASE 0: Pre-flight checks"
###############################################################################

[ "$(id -u)" -ne 0 ] && err "Run as root: sudo ./setup-erpnext.sh"

command -v dig &>/dev/null || { apt-get update -qq; apt-get install -y -qq dnsutils >/dev/null 2>&1; }

log "Checking DNS for ${SITE_DOMAIN}..."
RESOLVED_IP=$(dig +short "${SITE_DOMAIN}" | head -1)
[ -z "$RESOLVED_IP" ] && err "DNS for ${SITE_DOMAIN} does not resolve. Fix DNS first."
log "DNS resolves to: ${RESOLVED_IP}"

SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || echo "unknown")
if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
  warn "DNS → ${RESOLVED_IP}, server → ${SERVER_IP}. Continuing in 5s..."
  sleep 5
fi

###############################################################################
step "PHASE 1: System preparation"
###############################################################################

log "Updating system..."
apt-get update -qq && apt-get upgrade -y -qq >/dev/null 2>&1
log "System updated."

if id "$FRAPPE_USER" &>/dev/null; then
  log "User ${FRAPPE_USER} already exists."
else
  log "Creating user ${FRAPPE_USER}..."
  adduser --disabled-password --gecos "" "$FRAPPE_USER"
  usermod -aG sudo "$FRAPPE_USER"
  echo "${FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${FRAPPE_USER}"
  log "User ${FRAPPE_USER} created."
fi

###############################################################################
step "PHASE 2: Install Docker"
###############################################################################

if command -v docker &>/dev/null; then
  log "Docker already installed: $(docker --version)"
else
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | bash
  log "Docker installed: $(docker --version)"
fi

usermod -aG docker "$FRAPPE_USER"
docker compose version >/dev/null 2>&1 || err "Docker Compose plugin not found."
log "Docker Compose: $(docker compose version --short)"

###############################################################################
step "PHASE 3: Generate passwords"
###############################################################################

DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 24)
ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 16)
TRAEFIK_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 16)

sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}/passwords"
cat > "$PASS_FILE" << EOF
# ERPNext Credentials — $(date)
# Site: ${SITE_DOMAIN} | Project: ${PROJECT_NAME}
MARIADB_ROOT_PASSWORD=${DB_PASSWORD}
ERPNEXT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
TRAEFIK_DASHBOARD_PASSWORD=${TRAEFIK_PASSWORD}
EOF
chown "${FRAPPE_USER}:${FRAPPE_USER}" "$PASS_FILE"
chmod 600 "$PASS_FILE"
log "Passwords saved to ${PASS_FILE}"

###############################################################################
step "PHASE 4: Clone repo and build custom image"
###############################################################################

cd "$FRAPPE_HOME"

if [ -d "frappe_docker" ]; then
  warn "frappe_docker exists, pulling latest..."
  cd frappe_docker && sudo -u "$FRAPPE_USER" git pull --quiet && cd ..
else
  sudo -u "$FRAPPE_USER" git clone https://github.com/frappe/frappe_docker
fi

cd "${FRAPPE_HOME}/frappe_docker"

log "Building custom image (10-30 minutes)..."
APPS_JSON_BASE64=$(echo "${APPS_JSON}" | base64 -w 0)

docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=${FRAPPE_BRANCH} \
  --build-arg=APPS_JSON_BASE64=${APPS_JSON_BASE64} \
  --tag=${IMAGE_NAME}:${IMAGE_TAG} \
  --file=images/custom/Containerfile . \
  --no-cache

log "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"

###############################################################################
step "PHASE 5: Create directories"
###############################################################################

sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}"/{gitops,scripts,logs,backups}
log "Directories created."

###############################################################################
step "PHASE 6: Deploy Traefik"
###############################################################################

TRAEFIK_HASH_RAW=$(openssl passwd -apr1 "$TRAEFIK_PASSWORD")
TRAEFIK_HASH_ESCAPED=$(echo "$TRAEFIK_HASH_RAW" | sed 's/\$/\$\$/g')

cat > "${FRAPPE_HOME}/gitops/traefik.env" << EOF
TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}
EMAIL=${LETSENCRYPT_EMAIL}
HASHED_PASSWORD=${TRAEFIK_HASH_ESCAPED}
EOF
chown "${FRAPPE_USER}:${FRAPPE_USER}" "${FRAPPE_HOME}/gitops/traefik.env"

log "Starting Traefik..."
cd "${FRAPPE_HOME}/frappe_docker"
docker compose --project-name traefik \
  --env-file "${FRAPPE_HOME}/gitops/traefik.env" \
  -f overrides/compose.traefik.yaml \
  -f overrides/compose.traefik-ssl.yaml up -d
log "Traefik running."

###############################################################################
step "PHASE 7: Deploy MariaDB"
###############################################################################

cat > "${FRAPPE_HOME}/gitops/mariadb.env" << EOF
DB_PASSWORD=${DB_PASSWORD}
EOF
chown "${FRAPPE_USER}:${FRAPPE_USER}" "${FRAPPE_HOME}/gitops/mariadb.env"

log "Starting MariaDB..."
docker compose --project-name mariadb \
  --env-file "${FRAPPE_HOME}/gitops/mariadb.env" \
  -f overrides/compose.mariadb-shared.yaml up -d

log "Waiting for MariaDB to be healthy..."
RETRIES=30
until docker compose --project-name mariadb ps 2>/dev/null | grep -q "healthy" || [ $RETRIES -eq 0 ]; do
  sleep 2; RETRIES=$((RETRIES - 1))
done
[ $RETRIES -eq 0 ] && { warn "MariaDB health timed out, waiting 10s..."; sleep 10; } || log "MariaDB is healthy."

###############################################################################
step "PHASE 8: Deploy ERPNext bench"
###############################################################################

cd "${FRAPPE_HOME}/frappe_docker"

# --- Build the env file ---
log "Creating bench env file..."
curl -sL https://raw.githubusercontent.com/frappe/frappe_docker/main/example.env -o "$ENV_FILE"

# Replace values that EXIST in example.env
sed -i "s|DB_PASSWORD=123|DB_PASSWORD=${DB_PASSWORD}|g" "$ENV_FILE"
sed -i "s|DB_HOST=|DB_HOST=mariadb-database|g" "$ENV_FILE"
sed -i "s|DB_PORT=|DB_PORT=3306|g" "$ENV_FILE"
sed -i "s|SITES_RULE=.*|SITES_RULE=Host(\`${SITE_DOMAIN}\`)|g" "$ENV_FILE"

# Append values that DO NOT exist in example.env
cat >> "$ENV_FILE" << EOF
ROUTER=${PROJECT_NAME}
SITES=\`${SITE_DOMAIN}\`
BENCH_NETWORK=${PROJECT_NAME}
CUSTOM_IMAGE=${IMAGE_NAME}
CUSTOM_TAG=${IMAGE_TAG}
PULL_POLICY=never
EOF
chown "${FRAPPE_USER}:${FRAPPE_USER}" "$ENV_FILE"

# --- Verify ---
log "Verifying env file..."
grep -q "DB_HOST=mariadb-database"              "$ENV_FILE" || err "DB_HOST not set"
grep -q "SITES_RULE=Host(\`${SITE_DOMAIN}\`)"   "$ENV_FILE" || err "SITES_RULE not set"
grep -q "ROUTER=${PROJECT_NAME}"                 "$ENV_FILE" || err "ROUTER not set"
grep -q "SITES=\`${SITE_DOMAIN}\`"              "$ENV_FILE" || err "SITES not set"
grep -q "BENCH_NETWORK=${PROJECT_NAME}"          "$ENV_FILE" || err "BENCH_NETWORK not set"
grep -q "CUSTOM_IMAGE=${IMAGE_NAME}"             "$ENV_FILE" || err "CUSTOM_IMAGE not set"
grep -q "PULL_POLICY=never"                      "$ENV_FILE" || err "PULL_POLICY not set"
log "Env file verified."

# --- Generate resolved compose YAML ---
log "Generating resolved compose file..."
docker compose --project-name "${PROJECT_NAME}" \
  --env-file "$ENV_FILE" \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.multi-bench.yaml \
  -f overrides/compose.multi-bench-ssl.yaml \
  config > "$YAML_FILE"

# --- Critical checks ---
grep -q "erp.example.com" "$YAML_FILE" && err "FATAL: YAML still has erp.example.com"
grep -q "${SITE_DOMAIN}"  "$YAML_FILE" || err "FATAL: YAML missing ${SITE_DOMAIN}"
grep -q "${IMAGE_NAME}:${IMAGE_TAG}" "$YAML_FILE" || err "FATAL: YAML wrong image"
log "Verified: domain=${SITE_DOMAIN}, image=${IMAGE_NAME}:${IMAGE_TAG}"
chown "${FRAPPE_USER}:${FRAPPE_USER}" "$YAML_FILE"

# --- Start ---
log "Starting ERPNext bench..."
docker compose --project-name "${PROJECT_NAME}" -f "$YAML_FILE" up -d

log "Waiting for backend..."
sleep 10
RETRIES=24
until docker compose --project-name "${PROJECT_NAME}" -f "$YAML_FILE" \
  exec -T backend bench version >/dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
  sleep 5; RETRIES=$((RETRIES - 1))
done
[ $RETRIES -eq 0 ] && warn "Backend readiness timed out." || log "Backend is ready."

###############################################################################
step "PHASE 9: Create site"
###############################################################################

log "Creating site: ${SITE_DOMAIN}..."
docker compose --project-name "${PROJECT_NAME}" -f "$YAML_FILE" \
  exec -T backend \
  bench new-site "${SITE_DOMAIN}" \
    --mariadb-user-host-login-scope='%' \
    --mariadb-root-password "${DB_PASSWORD}" \
    --install-app erpnext \
    --admin-password "${ADMIN_PASSWORD}"
log "Site created."

log "Enabling scheduler..."
docker compose --project-name "${PROJECT_NAME}" -f "$YAML_FILE" \
  exec -T backend \
  bench --site "${SITE_DOMAIN}" enable-scheduler
log "Scheduler enabled."

###############################################################################
step "PHASE 10: Automated backups"
###############################################################################

cat > "${FRAPPE_HOME}/scripts/backup-${PROJECT_NAME}.sh" << BKEOF
#!/bin/bash
set -e
BACKUP_DIR="\${HOME}/backups/${PROJECT_NAME}/\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\$BACKUP_DIR"

docker compose --project-name ${PROJECT_NAME} \\
  -f "\${HOME}/gitops/${PROJECT_NAME}.yaml" \\
  exec -T backend \\
  bench --site ${SITE_DOMAIN} backup --with-files

docker compose --project-name ${PROJECT_NAME} \\
  -f "\${HOME}/gitops/${PROJECT_NAME}.yaml" \\
  cp backend:/home/frappe/frappe-bench/sites/${SITE_DOMAIN}/private/backups/ \\
  "\$BACKUP_DIR/"

find "\${HOME}/backups/${PROJECT_NAME}/" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \;
echo "[\$(date)] Backup done: \$BACKUP_DIR"
BKEOF

chown "${FRAPPE_USER}:${FRAPPE_USER}" "${FRAPPE_HOME}/scripts/backup-${PROJECT_NAME}.sh"
chmod +x "${FRAPPE_HOME}/scripts/backup-${PROJECT_NAME}.sh"
log "Backup script created."

# Install cron — use || true because crontab -l fails on empty crontab
CRON_LINE="0 2 * * * ${FRAPPE_HOME}/scripts/backup-${PROJECT_NAME}.sh >> ${FRAPPE_HOME}/logs/backup-${PROJECT_NAME}.log 2>&1"
( (sudo -u "$FRAPPE_USER" crontab -l 2>/dev/null || true) | grep -v "backup-${PROJECT_NAME}"; echo "$CRON_LINE") | sudo -u "$FRAPPE_USER" crontab -
log "Backup cron installed (daily 2:00 AM)."

###############################################################################
step "PHASE 11: Verification"
###############################################################################

echo "--- Container Status ---"
echo ""
docker compose --project-name traefik ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
docker compose --project-name mariadb ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
docker compose --project-name "${PROJECT_NAME}" -f "$YAML_FILE" \
  ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true

echo ""
echo "--- Traefik Labels ---"
FRONTEND_ID=$(docker ps -qf "name=${PROJECT_NAME}.*frontend" 2>/dev/null)
if [ -n "$FRONTEND_ID" ]; then
  docker inspect "$FRONTEND_ID" \
    --format='{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep "rule=" || echo "  (no rules found)"
else
  echo "  (frontend not found)"
fi

echo ""
echo "--- HTTP Test ---"
sleep 3
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${SITE_DOMAIN}" http://localhost:80 2>/dev/null || echo "000")
echo "  curl -H 'Host: ${SITE_DOMAIN}' http://localhost:80 → HTTP ${HTTP_CODE}"

###############################################################################
# SUMMARY
###############################################################################

echo ""
echo -e "${BOLD}=============================================${NC}"
echo -e "${BOLD} SETUP COMPLETE${NC}"
echo -e "${BOLD}=============================================${NC}"
echo ""
echo "  Site:       https://${SITE_DOMAIN}"
echo "  Traefik:    https://${TRAEFIK_DOMAIN}"
echo "  Login:      Administrator"
echo ""
echo -e "${BOLD}  PASSWORDS:${NC}"
echo "  MariaDB:    ${DB_PASSWORD}"
echo "  Admin:      ${ADMIN_PASSWORD}"
echo "  Traefik:    ${TRAEFIK_PASSWORD}"
echo ""
echo "  Saved to:   ${PASS_FILE}"
echo -e "${BOLD}=============================================${NC}"
echo ""

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "308" ]; then
  log "All checks passed!"
  log "SSL cert will be issued in 1-2 minutes."
  log "Open https://${SITE_DOMAIN}"
else
  warn "HTTP ${HTTP_CODE}. Debug with:"
  echo "  docker compose --project-name traefik logs --tail=30"
  echo "  docker compose --project-name ${PROJECT_NAME} -f ${YAML_FILE} logs backend"
fi

echo ""
echo "--- Commands (run as: su - ${FRAPPE_USER}) ---"
echo ""
echo "  # Logs"
echo "  docker compose --project-name ${PROJECT_NAME} -f ~/gitops/${PROJECT_NAME}.yaml logs -f backend"
echo ""
echo "  # Restart"
echo "  docker compose --project-name ${PROJECT_NAME} -f ~/gitops/${PROJECT_NAME}.yaml down"
echo "  docker compose --project-name ${PROJECT_NAME} -f ~/gitops/${PROJECT_NAME}.yaml up -d"
echo ""
echo "  # Backup now"
echo "  ~/scripts/backup-${PROJECT_NAME}.sh"
echo ""
echo "  # Shell into bench"
echo "  docker compose --project-name ${PROJECT_NAME} -f ~/gitops/${PROJECT_NAME}.yaml exec backend bash"
echo ""
echo "  # Add another site to this bench"
echo "  docker compose --project-name ${PROJECT_NAME} -f ~/gitops/${PROJECT_NAME}.yaml exec backend \\"
echo "    bench new-site newsite.example.com \\"
echo "      --mariadb-user-host-login-scope='%' \\"
echo "      --mariadb-root-password 'DB_PASSWORD_HERE' \\"
echo "      --install-app erpnext \\"
echo "      --admin-password 'ADMIN_PASSWORD_HERE'"
echo ""