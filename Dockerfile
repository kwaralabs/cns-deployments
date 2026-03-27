# =============================================================================
# Shared Frappe/ERPNext base image — Kwaralabs multi-brand ecosystem
#
# Strategy: one image, all brands. Apps baked in at build time via apps.json.
#   - Pinned ERPNext version (ERPNEXT_VERSION build arg)
#   - Official Frappe apps: erpnext, hrms, crm
#   - Custom Kwaralabs apps: sourced from your private Git repos
#
# Built by Dokploy from this Dockerfile on every deploy trigger.
# The build context is the repo root (or brands/base/ — set in compose).
#
# Build args (all overridable via Dokploy build args UI):
#   FRAPPE_VERSION    Branch/tag of frappe framework  (default: version-15)
#   ERPNEXT_VERSION   Branch/tag of erpnext           (default: version-15)
#   HRMS_VERSION      Branch/tag of hrms              (default: version-15)
#   CRM_VERSION       Branch/tag of crm               (default: 2.x)
#   PYTHON_VERSION    Python base version             (default: 3.11.6)
#   NODE_VERSION      Node.js version                 (default: 18.18.2)
#
# IMAGE TAGGING CONVENTION (applied in Dokploy build settings):
#   dev:   ghcr.io/kwaralabs/frappe-base:dev-<short-sha>
#   test:  ghcr.io/kwaralabs/frappe-base:v15.28.1-r3
#   prod:  ghcr.io/kwaralabs/frappe-base:v15.28.1-r3  (same tag — never rebuilt)
# =============================================================================

ARG PYTHON_VERSION=3.11.6
ARG NODE_VERSION=18.18.2
ARG FRAPPE_VERSION=version-15

# -----------------------------------------------------------------------------
# Stage 1: builder
# Installs bench, clones all apps, runs asset build.
# The final stage copies only the bench directory — no build tooling in prod.
# -----------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

ARG FRAPPE_VERSION=version-15
ARG ERPNEXT_VERSION=version-15
ARG HRMS_VERSION=version-15
ARG CRM_VERSION=2.x

# Build-time deps: git, node, yarn, wkhtmltopdf deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    build-essential \
    libffi-dev \
    libssl-dev \
    libjpeg-dev \
    libpng-dev \
    libmariadb-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (exact version for reproducibility)
ARG NODE_VERSION=18.18.2
RUN curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz \
    | tar -xJ -C /usr/local --strip-components=1 \
    && node --version && npm --version

# Install yarn
RUN npm install -g yarn

# Create frappe user — bench must not run as root
RUN useradd -ms /bin/bash frappe

USER frappe
WORKDIR /home/frappe

# Install bench CLI
RUN pip install --user frappe-bench

ENV PATH="/home/frappe/.local/bin:$PATH"

# Initialise bench — clones frappe framework at the pinned version.
# --skip-redis-config-generation: Redis is managed by Docker, not bench.
# --frappe-branch: pinned via build arg.
RUN bench init \
    --frappe-branch ${FRAPPE_VERSION} \
    --skip-redis-config-generation \
    --verbose \
    frappe-bench

WORKDIR /home/frappe/frappe-bench

# ── Official Frappe apps ─────────────────────────────────────────────────────

# ERPNext
RUN bench get-app \
    --branch ${ERPNEXT_VERSION} \
    erpnext \
    https://github.com/frappe/erpnext

# HRMS
RUN bench get-app \
    --branch ${HRMS_VERSION} \
    hrms \
    https://github.com/frappe/hrms

# Frappe CRM
RUN bench get-app \
    --branch ${CRM_VERSION} \
    crm \
    https://github.com/frappe/crm

# ── Custom Kwaralabs apps ────────────────────────────────────────────────────
# Add your private repos below. Use SSH URLs for private repos — Dokploy
# must have an SSH deploy key configured and mounted at build time, or use
# HTTPS with a token passed as a build secret (never a plain build arg).
#
# Example with HTTPS token (passed via Dokploy build secret, not ARG):
#   RUN --mount=type=secret,id=github_token \
#       bench get-app \
#         --branch main \
#         kwaralabs_core \
#         https://$(cat /run/secrets/github_token)@github.com/kwaralabs/kwaralabs-core
#
# Uncomment and adjust when your custom apps are ready:
# RUN bench get-app \
#     --branch main \
#     kwaralabs_core \
#     https://github.com/kwaralabs/kwaralabs-core

# ── Build assets ─────────────────────────────────────────────────────────────
# Compiles JS/CSS bundles for all installed apps.
# Must run after all apps are fetched.
RUN bench build --production

# -----------------------------------------------------------------------------
# Stage 2: runtime
# Lean final image — only runtime deps, no compilers or build tooling.
# Copies the fully built bench from the builder stage.
# -----------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

# Runtime deps only
RUN apt-get update && apt-get install -y --no-install-recommends \
    # MariaDB client (bench db operations, healthchecks)
    mariadb-client \
    # Frappe file processing
    libmagic1 \
    libjpeg62-turbo \
    libpng16-16 \
    # PDF generation (wkhtmltopdf)
    wkhtmltopdf \
    # Network utilities used by configurator
    wait-for-it \
    curl \
    # Process supervision
    supervisor \
    && rm -rf /var/lib/apt/lists/*

# Recreate the frappe user with the same UID as builder (1000)
RUN useradd -ms /bin/bash frappe

# Copy the fully-built bench from builder
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
# Copy bench CLI
COPY --from=builder --chown=frappe:frappe /home/frappe/.local /home/frappe/.local

USER frappe
WORKDIR /home/frappe/frappe-bench

ENV PATH="/home/frappe/.local/bin:$PATH"
# Frappe reads FRAPPE_BENCH_ROOT to locate sites and apps
ENV FRAPPE_BENCH_ROOT=/home/frappe/frappe-bench

# Expose nothing — all ports are declared in docker-compose.yml
# (8000 backend, 9000 websocket, 8080 nginx frontend)

# Default entrypoint — overridden by each service's `command:` in compose
CMD ["bench", "serve", "--port", "8000"]
