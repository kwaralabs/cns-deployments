#!/bin/bash
###############################################################################
#
#  ERPNext v16 — Multi-Project Production Setup via Frappe Docker
#
#  Tested & verified: March 24, 2026 — Ubuntu 24.04 LTS, Contabo VPS
#  Reference: https://github.com/frappe/frappe_docker
#
#  Supports apps requiring pnpm (e.g., Frappe Drive) by patching the
#  Containerfile to install pnpm globally before bench init.
#
#  USAGE:
#    1. Point all DNS A records to your server IP
#    2. Edit the CONFIGURATION section below
#    3. Run as root:  chmod +x setup-erpnext.sh && ./setup-erpnext.sh
#    4. Save the passwords printed at the end
#
###############################################################################

set -euo pipefail

###############################################################################
# CONFIGURATION — EDIT THESE
###############################################################################

TRAEFIK_DOMAIN="traefik.cns-srv1.collabnscale.com"
LETSENCRYPT_EMAIL="admin@collabnscale.com"
FRAPPE_BRANCH="version-16"
FRAPPE_USER="frappe"

# Set to "yes" if ANY project uses an app that requires pnpm (e.g., Drive).
# This patches the Containerfile to install pnpm globally in the builder stage.
NEEDS_PNPM="yes"

# --- Projects ---
# Each entry: "name|domain|image-tag|extra-apps|apps-json"
# MUST be a single line. See examples in comments below.
#
# Fields:
#   name       : Compose project name
#   domain     : Site domain (DNS must point here)
#   image-tag  : Docker image tag (unique per app combo)
#   extra-apps : Apps to install AFTER erpnext, or "none"
#   apps-json  : Single-line JSON of apps for the image
#
# NOTE on Drive: Use branch "main" (Drive has no version-16 branch)

PROJECTS=(
  "boujeeboyz-one|boujeeboyzjerky.collabnscale.io|customapp-erp-drive:1.0.0|drive|[{\"url\":\"https://github.com/frappe/erpnext\",\"branch\":\"version-16\"},{\"url\":\"https://github.com/frappe/drive\",\"branch\":\"main\"}]"
)

###############################################################################
# INTERNALS — DO NOT EDIT
###############################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

FRAPPE_HOME="/home/${FRAPPE_USER}"
PASS_FILE="${FRAPPE_HOME}/passwords/all-credentials.txt"

parse_project() {
  P_NAME=$(echo "$1" | cut -d'|' -f1)
  P_DOMAIN=$(echo "$1" | cut -d'|' -f2)
  P_IMAGE=$(echo "$1" | cut -d'|' -f3)
  P_EXTRA_APPS=$(echo "$1" | cut -d'|' -f4)
  P_APPS_JSON=$(echo "$1" | cut -d'|' -f5)
  P_IMAGE_NAME=$(echo "$P_IMAGE" | cut -d':' -f1)
  P_IMAGE_TAG=$(echo "$P_IMAGE" | cut -d':' -f2)
}

###############################################################################
step "PHASE 0: Pre-flight checks"
###############################################################################

[ "$(id -u)" -ne 0 ] && err "Run as root: sudo ./setup-erpnext.sh"

command -v dig &>/dev/null || { apt-get update -qq; apt-get install -y -qq dnsutils >/dev/null 2>&1; }

log "Checking DNS for all project domains..."
for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  RESOLVED_IP=$(dig +short "${P_DOMAIN}" | head -1)
  [ -z "$RESOLVED_IP" ] && err "DNS for ${P_DOMAIN} does not resolve."
  log "${P_DOMAIN} → ${RESOLVED_IP}"
done

SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || echo "unknown")
log "Server IP: ${SERVER_IP}"

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
TRAEFIK_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 16)

sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}/passwords"

declare -A ADMIN_PASSWORDS
for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  ADMIN_PASSWORDS["$P_NAME"]=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 16)
done

cat > "$PASS_FILE" << EOF
# ERPNext Multi-Project Credentials — $(date)
# Server: ${SERVER_IP}
MARIADB_ROOT_PASSWORD=${DB_PASSWORD}
TRAEFIK_DASHBOARD_PASSWORD=${TRAEFIK_PASSWORD}

EOF

for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  APPS_DISPLAY="erpnext"
  [ "${P_EXTRA_APPS}" != "none" ] && APPS_DISPLAY="erpnext, ${P_EXTRA_APPS}"
  cat >> "$PASS_FILE" << EOF
# --- ${P_NAME} (${P_DOMAIN}) | Apps: ${APPS_DISPLAY} ---
ADMIN_PASSWORD_${P_NAME}=${ADMIN_PASSWORDS[$P_NAME]}

EOF
done

chown "${FRAPPE_USER}:${FRAPPE_USER}" "$PASS_FILE"
chmod 600 "$PASS_FILE"
log "Passwords saved to ${PASS_FILE}"

###############################################################################
step "PHASE 4: Clone repo and create directories"
###############################################################################

cd "$FRAPPE_HOME"

if [ -d "frappe_docker" ]; then
  warn "frappe_docker exists, pulling latest..."
  cd frappe_docker && sudo -u "$FRAPPE_USER" git pull --quiet && cd ..
else
  sudo -u "$FRAPPE_USER" git clone https://github.com/frappe/frappe_docker
fi

sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}"/{gitops,scripts,logs,backups}
log "Directories ready."

###############################################################################
step "PHASE 5: Patch Containerfile (if pnpm needed) and build images"
###############################################################################

cd "${FRAPPE_HOME}/frappe_docker"

CONTAINERFILE="images/custom/Containerfile"

if [ "${NEEDS_PNPM}" = "yes" ]; then
  log "Patching Containerfile to install pnpm..."

  # Create a patched copy so we don't modify the git-tracked original
  PATCHED_CONTAINERFILE="images/custom/Containerfile.pnpm"
  cp "${CONTAINERFILE}" "${PATCHED_CONTAINERFILE}"

  # The builder stage has a RUN that starts with:
  #   RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install ...
  # We need to add "npm install -g pnpm" AFTER the nvm/node setup but
  # BEFORE bench init. The safest injection point is right after the
  # existing "RUN apt-get update" block in the builder stage.
  #
  # Strategy: Find the line "bench init" and insert pnpm install before it.
  # We use sed to add a line before the "bench init" command.

  if grep -q "npm install -g pnpm" "${PATCHED_CONTAINERFILE}"; then
    log "Containerfile already has pnpm — skipping patch."
  else
    # Insert "npm install -g pnpm &&" before "bench init"
    sed -i '/bench init/i\  npm install -g pnpm && \\' "${PATCHED_CONTAINERFILE}"
    log "Containerfile patched: added 'npm install -g pnpm'"
  fi

  # Use the patched Containerfile for all builds
  CONTAINERFILE="${PATCHED_CONTAINERFILE}"
fi

# Collect unique images
declare -A IMAGES_TO_BUILD
for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  IMAGES_TO_BUILD["$P_IMAGE"]="$P_APPS_JSON"
done

IMAGE_COUNT=${#IMAGES_TO_BUILD[@]}
IMAGE_NUM=0

for IMAGE_FULL in "${!IMAGES_TO_BUILD[@]}"; do
  IMAGE_NUM=$((IMAGE_NUM + 1))
  APPS_JSON="${IMAGES_TO_BUILD[$IMAGE_FULL]}"

  if docker image inspect "${IMAGE_FULL}" >/dev/null 2>&1; then
    log "Image ${IMAGE_FULL} already exists, skipping. (${IMAGE_NUM}/${IMAGE_COUNT})"
    continue
  fi

  log "Building image ${IMAGE_NUM}/${IMAGE_COUNT}: ${IMAGE_FULL}..."
  APPS_JSON_BASE64=$(echo "${APPS_JSON}" | base64 -w 0)

  docker build \
    --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
    --build-arg=FRAPPE_BRANCH=${FRAPPE_BRANCH} \
    --build-arg=APPS_JSON_BASE64=${APPS_JSON_BASE64} \
    --tag=${IMAGE_FULL} \
    --file=${CONTAINERFILE} . \
    --no-cache

  log "Image built: ${IMAGE_FULL}"
done

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
step "PHASE 8: Deploy projects"
###############################################################################

TOTAL_PROJECTS=${#PROJECTS[@]}
PROJECT_NUM=0

for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  PROJECT_NUM=$((PROJECT_NUM + 1))
  ADMIN_PASSWORD="${ADMIN_PASSWORDS[$P_NAME]}"
  ENV_FILE="${FRAPPE_HOME}/gitops/${P_NAME}.env"
  YAML_FILE="${FRAPPE_HOME}/gitops/${P_NAME}.yaml"

  echo ""
  log "━━━ Project ${PROJECT_NUM}/${TOTAL_PROJECTS}: ${P_NAME} (${P_DOMAIN}) ━━━"

  log "Creating env file..."
  cd "${FRAPPE_HOME}/frappe_docker"
  curl -sL https://raw.githubusercontent.com/frappe/frappe_docker/main/example.env -o "$ENV_FILE"

  sed -i "s|DB_PASSWORD=123|DB_PASSWORD=${DB_PASSWORD}|g" "$ENV_FILE"
  sed -i "s|DB_HOST=|DB_HOST=mariadb-database|g" "$ENV_FILE"
  sed -i "s|DB_PORT=|DB_PORT=3306|g" "$ENV_FILE"
  sed -i "s|SITES_RULE=.*|SITES_RULE=Host(\`${P_DOMAIN}\`)|g" "$ENV_FILE"

  cat >> "$ENV_FILE" << EOF
ROUTER=${P_NAME}
SITES=\`${P_DOMAIN}\`
BENCH_NETWORK=${P_NAME}
CUSTOM_IMAGE=${P_IMAGE_NAME}
CUSTOM_TAG=${P_IMAGE_TAG}
PULL_POLICY=never
EOF
  chown "${FRAPPE_USER}:${FRAPPE_USER}" "$ENV_FILE"

  grep -q "SITES_RULE=Host(\`${P_DOMAIN}\`)" "$ENV_FILE" || err "${P_NAME}: SITES_RULE not set"
  grep -q "CUSTOM_IMAGE=${P_IMAGE_NAME}"      "$ENV_FILE" || err "${P_NAME}: CUSTOM_IMAGE not set"
  log "Env file verified."

  log "Generating compose file..."
  docker compose --project-name "${P_NAME}" \
    --env-file "$ENV_FILE" \
    -f compose.yaml \
    -f overrides/compose.redis.yaml \
    -f overrides/compose.multi-bench.yaml \
    -f overrides/compose.multi-bench-ssl.yaml \
    config > "$YAML_FILE"

  grep -q "erp.example.com" "$YAML_FILE" && err "${P_NAME}: YAML still has erp.example.com"
  grep -q "${P_DOMAIN}"     "$YAML_FILE" || err "${P_NAME}: YAML missing ${P_DOMAIN}"
  grep -q "${P_IMAGE}"      "$YAML_FILE" || err "${P_NAME}: YAML wrong image"
  log "Compose verified: domain=${P_DOMAIN}, image=${P_IMAGE}"
  chown "${FRAPPE_USER}:${FRAPPE_USER}" "$YAML_FILE"

  log "Starting bench..."
  docker compose --project-name "${P_NAME}" -f "$YAML_FILE" up -d

  log "Waiting for backend..."
  sleep 10
  RETRIES=24
  until docker compose --project-name "${P_NAME}" -f "$YAML_FILE" \
    exec -T backend bench version >/dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
    sleep 5; RETRIES=$((RETRIES - 1))
  done
  [ $RETRIES -eq 0 ] && warn "Backend readiness timed out." || log "Backend is ready."

  log "Creating site: ${P_DOMAIN}..."
  docker compose --project-name "${P_NAME}" -f "$YAML_FILE" \
    exec -T backend \
    bench new-site "${P_DOMAIN}" \
      --mariadb-user-host-login-scope='%' \
      --mariadb-root-password "${DB_PASSWORD}" \
      --install-app erpnext \
      --admin-password "${ADMIN_PASSWORD}"
  log "Site created with erpnext."

  if [ "${P_EXTRA_APPS}" != "none" ]; then
    for APP in ${P_EXTRA_APPS}; do
      log "Installing app: ${APP}..."
      docker compose --project-name "${P_NAME}" -f "$YAML_FILE" \
        exec -T backend \
        bench --site "${P_DOMAIN}" install-app "${APP}"
      log "App ${APP} installed."
    done

    log "Running migrate..."
    docker compose --project-name "${P_NAME}" -f "$YAML_FILE" \
      exec -T backend \
      bench --site "${P_DOMAIN}" migrate
    log "Migration complete."
  fi

  log "Enabling scheduler..."
  docker compose --project-name "${P_NAME}" -f "$YAML_FILE" \
    exec -T backend \
    bench --site "${P_DOMAIN}" enable-scheduler
  log "Scheduler enabled."

  log "Installed apps on ${P_DOMAIN}:"
  docker compose --project-name "${P_NAME}" -f "$YAML_FILE" \
    exec -T backend \
    bench --site "${P_DOMAIN}" list-apps

  # --- Backup script ---
  cat > "${FRAPPE_HOME}/scripts/backup-${P_NAME}.sh" << BKEOF
#!/bin/bash
set -e
BACKUP_DIR="\${HOME}/backups/${P_NAME}/\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\$BACKUP_DIR"

docker compose --project-name ${P_NAME} \\
  -f "\${HOME}/gitops/${P_NAME}.yaml" \\
  exec -T backend \\
  bench --site ${P_DOMAIN} backup --with-files

docker compose --project-name ${P_NAME} \\
  -f "\${HOME}/gitops/${P_NAME}.yaml" \\
  cp backend:/home/frappe/frappe-bench/sites/${P_DOMAIN}/private/backups/ \\
  "\$BACKUP_DIR/"

find "\${HOME}/backups/${P_NAME}/" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \;
echo "[\$(date)] Backup done: \$BACKUP_DIR"
BKEOF

  chown "${FRAPPE_USER}:${FRAPPE_USER}" "${FRAPPE_HOME}/scripts/backup-${P_NAME}.sh"
  chmod +x "${FRAPPE_HOME}/scripts/backup-${P_NAME}.sh"

  CRON_MINUTE=$(( (PROJECT_NUM - 1) * 15 ))
  sudo -u "$FRAPPE_USER" bash -c "echo '${CRON_MINUTE} 2 * * * ${FRAPPE_HOME}/scripts/backup-${P_NAME}.sh >> ${FRAPPE_HOME}/logs/backup-${P_NAME}.log 2>&1' | crontab -"
  log "Backup cron installed (daily 2:$(printf '%02d' $CRON_MINUTE) AM)."

  log "Project ${P_NAME} complete!"
done

###############################################################################
step "PHASE 9: Verification"
###############################################################################

echo "--- Container Status ---"
echo ""
docker compose --project-name traefik ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
docker compose --project-name mariadb ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true

for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  echo ""
  docker compose --project-name "${P_NAME}" \
    -f "${FRAPPE_HOME}/gitops/${P_NAME}.yaml" \
    ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
done

echo ""
echo "--- HTTP Tests ---"
sleep 3
for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${P_DOMAIN}" http://localhost:80 2>/dev/null || echo "000")
  echo "  ${P_DOMAIN} → HTTP ${HTTP_CODE}"
done

###############################################################################
# SUMMARY
###############################################################################

echo ""
echo -e "${BOLD}=============================================${NC}"
echo -e "${BOLD} SETUP COMPLETE — ${TOTAL_PROJECTS} PROJECT(S)${NC}"
echo -e "${BOLD}=============================================${NC}"
echo ""
echo "  Traefik:    https://${TRAEFIK_DOMAIN}"
echo ""
echo -e "${BOLD}  SHARED PASSWORDS:${NC}"
echo "  MariaDB:    ${DB_PASSWORD}"
echo "  Traefik:    ${TRAEFIK_PASSWORD}"
echo ""

for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  APPS_DISPLAY="erpnext"
  [ "${P_EXTRA_APPS}" != "none" ] && APPS_DISPLAY="erpnext, ${P_EXTRA_APPS}"
  echo -e "${BOLD}  ${P_NAME}:${NC}"
  echo "    URL:      https://${P_DOMAIN}"
  echo "    Apps:     ${APPS_DISPLAY}"
  echo "    Admin:    ${ADMIN_PASSWORDS[$P_NAME]}"
  echo ""
done

echo "  All saved:  ${PASS_FILE}"
echo -e "${BOLD}=============================================${NC}"
echo ""

echo "--- Commands (run as: su - ${FRAPPE_USER}) ---"
echo ""
for PROJECT_ENTRY in "${PROJECTS[@]}"; do
  parse_project "$PROJECT_ENTRY"
  echo "  # ${P_NAME}"
  echo "  docker compose --project-name ${P_NAME} -f ~/gitops/${P_NAME}.yaml logs -f backend"
  echo "  docker compose --project-name ${P_NAME} -f ~/gitops/${P_NAME}.yaml down && docker compose --project-name ${P_NAME} -f ~/gitops/${P_NAME}.yaml up -d"
  echo "  ~/scripts/backup-${P_NAME}.sh"
  echo "  docker compose --project-name ${P_NAME} -f ~/gitops/${P_NAME}.yaml exec backend bash"
  echo ""
done