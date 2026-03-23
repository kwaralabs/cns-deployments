#!/bin/bash
###############################################################################
# ERPNext v16 Production Setup — Frappe Docker
#
# Platform: Ubuntu 24.04 LTS (Contabo VPS)
# Reference: https://github.com/frappe/frappe_docker
#            https://github.com/frappe/frappe_docker/blob/main/docs/single-server-example.md
#
# Fixes applied vs previous attempts:
#   - Does NOT edit compose.yaml (uses CUSTOM_IMAGE/CUSTOM_TAG env vars instead)
#   - SITES, ROUTER, BENCH_NETWORK are appended (they don't exist in example.env)
#   - Traefik password hash has $$ escaping for Docker Compose
#   - Verifies generated YAML has correct domain before deploying
#   - All passwords are unique and saved to a credentials file
#
# USAGE:
#   1. SSH into a fresh Ubuntu 24.04 VPS as root
#   2. Edit the CONFIGURATION section below
#   3. Run:
#        chmod +x setup-erpnext.sh
#        ./setup-erpnext.sh
#   4. Save the passwords printed at the end
#
###############################################################################

set -euo pipefail

###############################################################################
# CONFIGURATION — EDIT THESE VALUES
###############################################################################

# Your site domain (DNS A record must already point to this server's IP)
SITE_DOMAIN="boujeeboyzjerky.collabnscale.io"

# Traefik dashboard domain
TRAEFIK_DOMAIN="traefik.cns-srv1.collabnscale.com"

# Email for Let's Encrypt certificate notifications
LETSENCRYPT_EMAIL="admin@collabnscale.com"

# Project/bench name (lowercase, no spaces, alphanumeric + hyphens)
PROJECT_NAME="boujeeboyz-one"

# Docker image tag for the custom build
IMAGE_NAME="customapp"
IMAGE_TAG="1.0.0"

# Frappe/ERPNext branch
FRAPPE_BRANCH="version-16"

# Apps to include (add hrms, payments, etc. as needed)
APPS_JSON='[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "version-16"
  }
]'

# Non-root user to create and run everything under
FRAPPE_USER="frappe"

###############################################################################
# DO NOT EDIT BELOW THIS LINE
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

###############################################################################
# PHASE 0: PRE-FLIGHT
###############################################################################

step "PHASE 0: Pre-flight checks"

# Must run as root (we'll create the frappe user)
if [ "$(id -u)" -ne 0 ]; then
  err "Run this script as root: sudo ./setup-erpnext.sh"
fi

# Check DNS
log "Checking DNS for ${SITE_DOMAIN}..."
if ! command -v dig &> /dev/null; then
  apt-get update -qq && apt-get install -y -qq dnsutils > /dev/null 2>&1
fi

RESOLVED_IP=$(dig +short "${SITE_DOMAIN}" | head -1)
if [ -z "$RESOLVED_IP" ]; then
  err "DNS for ${SITE_DOMAIN} does not resolve. Set up your DNS A record first."
fi
log "DNS resolves to: ${RESOLVED_IP}"

SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || echo "unknown")
if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
  warn "DNS resolves to ${RESOLVED_IP}, server IP is ${SERVER_IP}"
  warn "Continuing in 5 seconds... (Ctrl+C to cancel)"
  sleep 5
fi

###############################################################################
# PHASE 1: SYSTEM PREP + USER CREATION
###############################################################################

step "PHASE 1: System preparation"

log "Updating system..."
apt-get update -qq && apt-get upgrade -y -qq > /dev/null 2>&1
log "System updated."

# Create frappe user if doesn't exist
if id "$FRAPPE_USER" &>/dev/null; then
  log "User ${FRAPPE_USER} already exists."
else
  log "Creating user ${FRAPPE_USER}..."
  adduser --disabled-password --gecos "" "$FRAPPE_USER"
  usermod -aG sudo "$FRAPPE_USER"
  echo "${FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${FRAPPE_USER}
  log "User ${FRAPPE_USER} created with sudo access."
fi

###############################################################################
# PHASE 2: INSTALL DOCKER
###############################################################################

step "PHASE 2: Install Docker"

if command -v docker &> /dev/null; then
  log "Docker already installed: $(docker --version)"
else
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | bash
  log "Docker installed: $(docker --version)"
fi

usermod -aG docker "$FRAPPE_USER"
log "User ${FRAPPE_USER} added to docker group."

docker compose version > /dev/null 2>&1 || err "Docker Compose plugin not found."
log "Docker Compose: $(docker compose version --short)"

###############################################################################
# PHASE 3: GENERATE PASSWORDS
###############################################################################

step "PHASE 3: Generate passwords"

# Use tr -d to strip characters that cause shell/yaml escaping issues
DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 24)
ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 16)
TRAEFIK_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 16)

FRAPPE_HOME=$(eval echo ~${FRAPPE_USER})

sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}/passwords"
PASS_FILE="${FRAPPE_HOME}/passwords/${PROJECT_NAME}-credentials.txt"
cat > "$PASS_FILE" << EOF
# ERPNext Credentials — Generated $(date)
# Site: ${SITE_DOMAIN}
# Project: ${PROJECT_NAME}

MARIADB_ROOT_PASSWORD=${DB_PASSWORD}
ERPNEXT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
TRAEFIK_DASHBOARD_PASSWORD=${TRAEFIK_PASSWORD}
EOF
chown "${FRAPPE_USER}:${FRAPPE_USER}" "$PASS_FILE"
chmod 600 "$PASS_FILE"
log "Passwords saved to ${PASS_FILE}"

###############################################################################
# PHASE 4: CLONE REPO + BUILD IMAGE
###############################################################################

step "PHASE 4: Clone repo and build custom image"

cd "$FRAPPE_HOME"

if [ -d "frappe_docker" ]; then
  warn "frappe_docker already exists, pulling latest..."
  cd frappe_docker && sudo -u "$FRAPPE_USER" git pull --quiet && cd ..
else
  log "Cloning frappe_docker..."
  sudo -u "$FRAPPE_USER" git clone https://github.com/frappe/frappe_docker
fi

cd "${FRAPPE_HOME}/frappe_docker"

log "Building custom image (this takes 10-30 minutes)..."

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
# PHASE 5: CREATE DIRECTORIES
###############################################################################

step "PHASE 5: Create directories"

sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}/gitops"
sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}/scripts"
sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}/logs"
sudo -u "$FRAPPE_USER" mkdir -p "${FRAPPE_HOME}/backups"

log "Directories created."

###############################################################################
# PHASE 6: DEPLOY TRAEFIK
###############################################################################

step "PHASE 6: Deploy Traefik"

# Generate password hash for Traefik basic auth
# openssl passwd -apr1 produces hashes like: $apr1$salt$hash
# Docker Compose treats $ as variable interpolation, so we must escape $ as $$
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
# PHASE 7: DEPLOY MARIADB
###############################################################################

step "PHASE 7: Deploy MariaDB"

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
  sleep 2
  RETRIES=$((RETRIES - 1))
done

if [ $RETRIES -eq 0 ]; then
  warn "MariaDB health check timed out. Waiting 10 more seconds..."
  sleep 10
else
  log "MariaDB is healthy."
fi

###############################################################################
# PHASE 8: DEPLOY ERPNEXT BENCH
###############################################################################

step "PHASE 8: Deploy ERPNext bench"

cd "${FRAPPE_HOME}/frappe_docker"

#
# Create the bench env file.
#
# KEY INSIGHT: compose.yaml uses these env vars for the image:
#   image: ${CUSTOM_IMAGE:-frappe/erpnext}:${CUSTOM_TAG:-$ERPNEXT_VERSION}
#   pull_policy: ${PULL_POLICY:-always}
#
# So we set CUSTOM_IMAGE, CUSTOM_TAG, and PULL_POLICY in the env file.
# We do NOT edit compose.yaml at all.
#
# SITES, ROUTER, and BENCH_NETWORK do NOT exist in example.env.
# They must be APPENDED (not sed-replaced). This was the bug in the
# original script that caused Traefik to route to erp.example.com.
#

log "Downloading fresh example.env..."
curl -sL https://raw.githubusercontent.com/frappe/frappe_docker/main/example.env \
  -o "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env"

# Patch values that EXIST in example.env
sed -i "s|DB_PASSWORD=123|DB_PASSWORD=${DB_PASSWORD}|g" "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env"
sed -i "s|DB_HOST=|DB_HOST=mariadb-database|g" "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env"
sed -i "s|DB_PORT=|DB_PORT=3306|g" "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env"

# APPEND values that DO NOT exist in example.env
cat >> "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env" << EOF
ROUTER=${PROJECT_NAME}
SITES=\`${SITE_DOMAIN}\`
BENCH_NETWORK=${PROJECT_NAME}
CUSTOM_IMAGE=${IMAGE_NAME}
CUSTOM_TAG=${IMAGE_TAG}
PULL_POLICY=never
EOF

chown "${FRAPPE_USER}:${FRAPPE_USER}" "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env"

# Verify
log "Verifying env file..."
ENV_FILE="${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env"
grep -q "DB_HOST=mariadb-database" "$ENV_FILE" || err "DB_HOST not set"
grep -q "SITES=\`${SITE_DOMAIN}\`" "$ENV_FILE" || err "SITES not set"
grep -q "ROUTER=${PROJECT_NAME}" "$ENV_FILE" || err "ROUTER not set"
grep -q "BENCH_NETWORK=${PROJECT_NAME}" "$ENV_FILE" || err "BENCH_NETWORK not set"
grep -q "CUSTOM_IMAGE=${IMAGE_NAME}" "$ENV_FILE" || err "CUSTOM_IMAGE not set"
grep -q "PULL_POLICY=never" "$ENV_FILE" || err "PULL_POLICY not set"
log "Env file verified."

# Generate resolved compose YAML
log "Generating resolved compose file..."

docker compose --project-name "${PROJECT_NAME}" \
  --env-file "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.env" \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.multi-bench.yaml \
  -f overrides/compose.multi-bench-ssl.yaml \
  config > "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml"

# CRITICAL CHECKS on the generated YAML
if grep -q "erp.example.com" "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml"; then
  err "FATAL: Generated YAML contains 'erp.example.com'. SITES not applied."
fi

if ! grep -q "${SITE_DOMAIN}" "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml"; then
  err "FATAL: Generated YAML missing '${SITE_DOMAIN}'."
fi

if ! grep -q "${IMAGE_NAME}:${IMAGE_TAG}" "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml"; then
  err "FATAL: Generated YAML not using image ${IMAGE_NAME}:${IMAGE_TAG}."
fi

log "Verified: domain=${SITE_DOMAIN}, image=${IMAGE_NAME}:${IMAGE_TAG}"

chown "${FRAPPE_USER}:${FRAPPE_USER}" "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml"

# Start the bench
log "Starting ERPNext bench..."

docker compose --project-name "${PROJECT_NAME}" \
  -f "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml" up -d

# Wait for backend
log "Waiting for backend to be ready..."
sleep 10
RETRIES=24
until docker compose --project-name "${PROJECT_NAME}" \
  -f "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml" \
  exec -T backend bench version > /dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
  sleep 5
  RETRIES=$((RETRIES - 1))
done

if [ $RETRIES -eq 0 ]; then
  warn "Backend readiness timed out. Attempting site creation anyway..."
else
  log "Backend is ready."
fi

###############################################################################
# PHASE 9: CREATE SITE
###############################################################################

step "PHASE 9: Create site"

log "Creating site: ${SITE_DOMAIN}..."

docker compose --project-name "${PROJECT_NAME}" \
  -f "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml" \
  exec -T backend \
  bench new-site "${SITE_DOMAIN}" \
    --no-mariadb-socket \
    --mariadb-root-password "${DB_PASSWORD}" \
    --install-app erpnext \
    --admin-password "${ADMIN_PASSWORD}"

log "Site created."

log "Enabling scheduler..."

docker compose --project-name "${PROJECT_NAME}" \
  -f "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml" \
  exec -T backend \
  bench --site "${SITE_DOMAIN}" enable-scheduler

log "Scheduler enabled."

###############################################################################
# PHASE 10: AUTOMATED BACKUPS
###############################################################################

step "PHASE 10: Setup automated backups"

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

CRON_LINE="0 2 * * * ${FRAPPE_HOME}/scripts/backup-${PROJECT_NAME}.sh >> ${FRAPPE_HOME}/logs/backup-${PROJECT_NAME}.log 2>&1"
(sudo -u "$FRAPPE_USER" crontab -l 2>/dev/null | grep -v "backup-${PROJECT_NAME}"; echo "$CRON_LINE") | sudo -u "$FRAPPE_USER" crontab -

log "Backup cron installed (daily 2:00 AM)."

###############################################################################
# PHASE 11: VERIFICATION
###############################################################################

step "PHASE 11: Verification"

echo "--- Container Status ---"
echo ""
docker compose --project-name traefik ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
docker compose --project-name mariadb ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
docker compose --project-name "${PROJECT_NAME}" \
  -f "${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml" \
  ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true

echo ""
echo "--- Traefik Labels on Frontend ---"
FRONTEND_ID=$(docker ps -qf "name=${PROJECT_NAME}.*frontend" 2>/dev/null)
if [ -n "$FRONTEND_ID" ]; then
  docker inspect "$FRONTEND_ID" \
    --format='{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep "rule=" || echo "  (no traefik rules found)"
else
  echo "  (frontend container not found)"
fi

echo ""
echo "--- HTTP Test ---"
sleep 5
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${SITE_DOMAIN}" http://localhost:80 2>/dev/null || echo "000")
echo "  curl -H 'Host: ${SITE_DOMAIN}' http://localhost:80 → HTTP ${HTTP_CODE}"

###############################################################################
# DONE
###############################################################################

echo ""
echo -e "${BOLD}=============================================${NC}"
echo -e "${BOLD} SETUP COMPLETE${NC}"
echo -e "${BOLD}=============================================${NC}"
echo ""
echo "  Site:           https://${SITE_DOMAIN}"
echo "  Traefik:        https://${TRAEFIK_DOMAIN}"
echo "  Login:          Administrator"
echo ""
echo -e "${BOLD}  PASSWORDS (save these now!):${NC}"
echo "  MariaDB root:      ${DB_PASSWORD}"
echo "  ERPNext admin:     ${ADMIN_PASSWORD}"
echo "  Traefik dashboard: ${TRAEFIK_PASSWORD}"
echo ""
echo "  Saved to: ${PASS_FILE}"
echo ""
echo -e "${BOLD}=============================================${NC}"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "308" ]; then
  echo ""
  log "All checks passed. SSL cert will be issued in 1-2 minutes."
  log "Open https://${SITE_DOMAIN}"
else
  echo ""
  warn "HTTP returned ${HTTP_CODE}. Common causes:"
  echo "    - Wait 1-2 min for containers to fully start"
  echo "    - Check: docker compose --project-name traefik logs --tail=30"
  echo "    - Check: docker compose --project-name ${PROJECT_NAME} -f ${FRAPPE_HOME}/gitops/${PROJECT_NAME}.yaml logs backend"
fi

echo ""
echo "--- Useful Commands (run as ${FRAPPE_USER}) ---"
echo ""
echo "  su - ${FRAPPE_USER}"
echo "  docker compose --project-name ${PROJECT_NAME} -f ~/gitops/${PROJECT_NAME}.yaml logs -f backend"
echo "  docker compose --project-name ${PROJECT_NAME} -f ~/gitops/${PROJECT_NAME}.yaml down"
echo "  docker compose --project-name ${PROJECT_NAME} -f ~/gitops/${PROJECT_NAME}.yaml up -d"
echo "  ~/scripts/backup-${PROJECT_NAME}.sh"
echo ""
