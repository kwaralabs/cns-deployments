# =============================================================================
# cns-deployments — Frappe Custom Image
# Frappe v16 · ERPNext · HRMS · CRM
# Shared by all brands. One image, one build pipeline.
# =============================================================================
#
# Prerequisites (Frappe v16 — source: docs.frappe.io/framework/user/en/installation):
#   Python  3.14   (NOT 3.12 — that is v15)
#   Node    24     (NOT 20  — that is v15)
#   MariaDB 11.8   (NOT 10.6 — that is v14/v15)
#
# Local build:
#   export APPS_JSON_BASE64=$(base64 -w 0 apps.json)
#   docker build \
#     --build-arg APPS_JSON_BASE64="$APPS_JSON_BASE64" \
#     --build-arg FRAPPE_BRANCH=version-16 \
#     -t ghcr.io/kwaralabs/frappe-cns:latest \
#     -f Dockerfile .
#
# Pattern: frappe/frappe_docker images/custom/Containerfile
# =============================================================================

ARG FRAPPE_PATH=https://github.com/frappe/frappe
ARG FRAPPE_BRANCH=version-16
ARG PYTHON_VERSION=3.14
ARG NODE_VERSION=24
ARG APPS_JSON_BASE64

# =============================================================================
# Stage 1 — builder
# =============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

ARG FRAPPE_PATH
ARG FRAPPE_BRANCH
ARG APPS_JSON_BASE64
ARG NODE_VERSION

# System build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      build-essential \
      pkg-config \
      libmariadb-dev \
      libmariadb-dev-compat \
      libffi-dev \
      libssl-dev \
      libjpeg-dev \
      libpng-dev \
      libtiff-dev \
      libwebp-dev \
      libcairo2-dev \
      libpango1.0-dev \
      librsvg2-dev \
      libldap2-dev \
      libsasl2-dev \
      wkhtmltopdf \
      xvfb \
      curl \
      ca-certificates \
      wait-for-it \
    && rm -rf /var/lib/apt/lists/*

# Node.js + yarn
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g yarn \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -ms /bin/bash frappe

# Decode apps.json from build arg (done as root before USER switch)
# This is the canonical frappe/frappe_docker pattern.
RUN if [ -n "${APPS_JSON_BASE64}" ]; then \
      mkdir -p /opt/frappe && \
      echo "${APPS_JSON_BASE64}" | base64 -d > /opt/frappe/apps.json && \
      echo "[builder] apps.json decoded:" && \
      cat /opt/frappe/apps.json; \
    else \
      echo "[builder] No APPS_JSON_BASE64 — Frappe only, no extra apps."; \
    fi

USER frappe
WORKDIR /home/frappe

ENV PATH="/home/frappe/.local/bin:$PATH"

RUN pip install --user frappe-bench

# ---------------------------------------------------------------------------
# bench init — pass --apps_path directly so bench init fetches all apps
# atomically. This is the upstream frappe_docker pattern. Do NOT use
# bench get-app in a separate loop — it bypasses dependency resolution.
# ---------------------------------------------------------------------------
RUN export APP_INSTALL_ARGS="" && \
    if [ -f /opt/frappe/apps.json ]; then \
      export APP_INSTALL_ARGS="--apps_path=/opt/frappe/apps.json"; \
    fi && \
    bench init \
      ${APP_INSTALL_ARGS} \
      --frappe-branch="${FRAPPE_BRANCH}" \
      --frappe-path="${FRAPPE_PATH}" \
      --python=python3 \
      --no-procfile \
      --no-backups \
      --skip-redis-config-generation \
      --verbose \
      /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

# Write a build-time common_site_config.json.
#
# CRM's frontend (src/socket.js) imports `socketio_port` from this file as a
# named ES module export at Vite build time — NOT at runtime. If the key is
# missing the build hard-fails with:
#   "socketio_port" is not exported by "common_site_config.json"
#
# All values here are build-time placeholders only. The configurator service
# overwrites this file with real values on first deploy.
RUN echo '{ \
  "db_host": "db", \
  "db_port": 3306, \
  "redis_cache": "redis://redis-cache:6379", \
  "redis_queue": "redis://redis-queue:6379", \
  "redis_socketio": "redis://redis-queue:6379", \
  "socketio_port": 9000 \
}' > sites/common_site_config.json

# Strip .git directories — saves several hundred MB of image size.
RUN find apps -mindepth 1 -path "*/.git" -type d | xargs rm -rf

# Build JS / CSS production assets
RUN bench build --production

# =============================================================================
# Stage 2 — production (slim, no build toolchain)
# =============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm AS production

ARG NODE_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      ca-certificates \
      libmariadb3 \
      libssl3 \
      libjpeg62-turbo \
      libpng16-16 \
      libtiff6 \
      libwebp7 \
      libcairo2 \
      libpango-1.0-0 \
      librsvg2-2 \
      libldap-2.5-0 \
      libsasl2-2 \
      wkhtmltopdf \
      xvfb \
      fonts-liberation \
      wait-for-it \
      jq \
      gettext-base \
      mariadb-client \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -ms /bin/bash frappe

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
COPY --from=builder --chown=frappe:frappe /home/frappe/.local /home/frappe/.local

# Entrypoint scripts (nginx-entrypoint.sh lives here)
COPY --chown=root:root entrypoints/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

USER frappe
WORKDIR /home/frappe/frappe-bench

ENV PATH="/home/frappe/.local/bin:$PATH"
ENV FRAPPE_BENCH_PATH="/home/frappe/frappe-bench"

# Smoke-test: confirm bench CLI is functional
RUN bench --version

VOLUME ["/home/frappe/frappe-bench/sites", "/home/frappe/frappe-bench/logs"]

CMD ["bench", "serve", "--port", "8000"]