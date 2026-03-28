# =============================================================================
# Shared Frappe/ERPNext base image — Kwaralabs multi-brand ecosystem
#
# Follows the official frappe_docker build pattern:
#   images/layered/Containerfile  (APPS_JSON_BASE64 + bench init --apps_path)
#
# Apps to bake in are declared in apps.json at the repo root.
# The GitHub Actions workflow encodes it and passes it as APPS_JSON_BASE64.
#
# Official Frappe v16 prerequisites:
#   Python   3.14   (via uv)
#   Node.js  24     (via nvm — major version, nvm resolves to latest patch)
#   Yarn     1.22+
#   pip      25.3+
#
# Build args:
#   FRAPPE_PATH       frappe Git URL        default: https://github.com/frappe/frappe
#   FRAPPE_BRANCH     frappe branch         default: version-16
#   PYTHON_VERSION    uv python target      default: 3.14
#   NODE_VERSION      nvm major version     default: 24
#   APPS_JSON_BASE64  base64(apps.json)     set as secret build arg in GitHub Actions
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: builder
# Full toolchain — uv, nvm/node/yarn, bench CLI, all apps, compiled assets.
# Only the resulting bench directory ships in the final image.
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

ARG FRAPPE_PATH=https://github.com/frappe/frappe
ARG FRAPPE_BRANCH=version-16
ARG PYTHON_VERSION=3.14
ARG NODE_VERSION=24
ARG APPS_JSON_BASE64

ENV DEBIAN_FRONTEND=noninteractive
ENV NVM_DIR=/home/frappe/.nvm
# PATH gets nvm's default alias symlink — works regardless of resolved patch version
ENV PATH="/home/frappe/.local/bin:/home/frappe/.nvm/alias/default/bin:$PATH"
# Force yarn to skip optional deps and engine checks globally for all invocations,
# including those spawned by bench internals. This prevents failures caused by
# app yarn.lock files committed from Windows containing platform-specific optional
# deps (e.g. @rollup/rollup-win32-*) that don't exist in the Linux yarn cache.
ENV YARN_IGNORE_OPTIONAL=true
ENV YARN_IGNORE_ENGINES=true

# ── System build deps ─────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    libffi-dev \
    libssl-dev \
    libjpeg-dev \
    libpng-dev \
    libmariadb-dev \
    pkg-config \
    xz-utils \
    cron \
    && rm -rf /var/lib/apt/lists/*

# ── frappe user — bench must never run as root ────────────────────────────────
RUN useradd -ms /bin/bash frappe

USER frappe
WORKDIR /home/frappe

# ── Global .yarnrc — belt-and-suspenders alongside the ENV vars above ─────────
# Some yarn versions read .yarnrc preferentially over environment variables.
RUN printf 'ignore-optional true\nignore-engines true\n' > /home/frappe/.yarnrc

# ── Python via uv ─────────────────────────────────────────────────────────────
# uv manages its own Python installation. bench init will create its own
# virtualenv with its own pip — no need to install or upgrade pip here.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && /home/frappe/.local/bin/uv python install ${PYTHON_VERSION} --default \
    && /home/frappe/.local/bin/uv python pin ${PYTHON_VERSION} \
    && python --version

# ── Node.js via nvm ───────────────────────────────────────────────────────────
# nvm install <major> resolves to the latest LTS patch for that major.
# We source nvm.sh in every subsequent RUN that needs node/yarn.
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
RUN bash -c " \
    source ${NVM_DIR}/nvm.sh && \
    nvm install ${NODE_VERSION} && \
    nvm alias default ${NODE_VERSION} && \
    npm install -g yarn && \
    node --version && \
    yarn --version"

# ── bench CLI via uv tool install ─────────────────────────────────────────────
RUN /home/frappe/.local/bin/uv tool install frappe-bench \
    && /home/frappe/.local/bin/bench --version

# ── Decode apps.json ──────────────────────────────────────────────────────────
# Written to /home/frappe (frappe-owned) rather than /opt (root-owned).
# This step runs as frappe (USER frappe is already set above).
RUN if [ -n "${APPS_JSON_BASE64}" ]; then \
        printf '%s' "${APPS_JSON_BASE64}" | base64 -d > /home/frappe/apps.json && \
        echo "--- apps.json decoded ---" && \
        cat /home/frappe/apps.json && \
        echo "--- end apps.json ---"; \
    fi

# ── bench init: clone frappe + all apps, skip internal asset build ─────────────
# --skip-assets prevents bench from running `bench build` internally, which
# would fail because common_site_config.json is empty at this point and CRM's
# socket.js requires socketio_port to be defined at Rollup/Vite build time.
# We run our own controlled build in the next step after writing the config.
RUN bash -c " \
    source ${NVM_DIR}/nvm.sh && \
    PYTHON_BIN=\$( /home/frappe/.local/bin/uv python find ${PYTHON_VERSION} ) && \
    echo \"Using Python: \${PYTHON_BIN}\" && \
    APP_INSTALL_ARGS='' && \
    if [ -f /home/frappe/apps.json ]; then \
        APP_INSTALL_ARGS='--apps_path /home/frappe/apps.json'; \
    fi && \
    /home/frappe/.local/bin/bench init \${APP_INSTALL_ARGS} \
        --frappe-branch ${FRAPPE_BRANCH} \
        --frappe-path ${FRAPPE_PATH} \
        --skip-redis-config-generation \
        --skip-assets \
        --python \${PYTHON_BIN} \
        --verbose \
        frappe-bench && \
    cd frappe-bench && \
    find apps -mindepth 1 -path '*/.git' | xargs rm -rf"

# ── Write common_site_config.json with socketio_port for asset build ──────────
# CRM's socket.js imports socketio_port from this file at Rollup/Vite build
# time. An empty {} causes a RollupError. We set a real value for the build,
# then reset to a clean runtime config after assets are compiled.
RUN echo '{"socketio_port": 9000}' \
    > /home/frappe/frappe-bench/sites/common_site_config.json

# ── Compile production JS/CSS assets ──────────────────────────────────────────
RUN bash -c " \
    source ${NVM_DIR}/nvm.sh && \
    cd frappe-bench && \
    /home/frappe/.local/bin/bench build --production"

# ── Reset common_site_config.json to empty for runtime ────────────────────────
# The actual value is injected by the entrypoint at container start.
RUN echo '{}' > /home/frappe/frappe-bench/sites/common_site_config.json

# -----------------------------------------------------------------------------
# Stage 2: runtime
# Lean final image — runtime deps only, no compilers, no build toolchain.
# Copies the fully-built bench directory, uv Python, and nvm Node from builder.
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV NVM_DIR=/home/frappe/.nvm
ENV PATH="/home/frappe/.local/bin:/home/frappe/.nvm/alias/default/bin:$PATH"
ENV FRAPPE_BENCH_ROOT=/home/frappe/frappe-bench

# ── Runtime system deps ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    mariadb-client \
    libmagic1 \
    libjpeg62-turbo \
    libpng16-16 \
    xvfb \
    fontconfig \
    xfonts-75dpi \
    xfonts-base \
    libfontconfig1 \
    libxrender1 \
    libxext6 \
    wait-for-it \
    curl \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# ── wkhtmltopdf 0.12.6 with patched Qt ───────────────────────────────────────
# The apt package (0.12.6-2) is unpatched and breaks Frappe PDF generation.
# Must install from the official wkhtmltopdf project release.
# Note: --no-install-recommends is intentionally omitted here — the .deb
# resolver requires it absent to correctly satisfy wkhtmltox dependencies.
RUN curl -fsSL \
    https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb \
    -o /tmp/wkhtmltox.deb \
    && apt-get install -y /tmp/wkhtmltox.deb \
    && rm /tmp/wkhtmltox.deb \
    && rm -rf /var/lib/apt/lists/* \
    && wkhtmltopdf --version

# ── Recreate frappe user (same UID=1000 as builder stage) ─────────────────────
RUN useradd -ms /bin/bash frappe

# ── Copy built artifacts from builder ─────────────────────────────────────────
COPY --from=builder --chown=frappe:frappe \
    /home/frappe/frappe-bench /home/frappe/frappe-bench

COPY --from=builder --chown=frappe:frappe \
    /home/frappe/.local /home/frappe/.local

COPY --from=builder --chown=frappe:frappe \
    /home/frappe/.nvm /home/frappe/.nvm

USER frappe
WORKDIR /home/frappe/frappe-bench

# ── Sanity check — verify all tools are reachable in runtime image ────────────
RUN /home/frappe/.local/bin/bench --version \
    && python --version \
    && node --version \
    && yarn --version

CMD ["bench", "serve", "--port", "8000"]