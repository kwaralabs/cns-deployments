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
# Prevent yarn engine checks from failing due to mismatched Node version
# declarations in app package.json files.
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

# ── Global .yarnrc ────────────────────────────────────────────────────────────
# ignore-engines: suppress Node version mismatch warnings/errors from apps
#   whose package.json engines field doesn't match our Node 24.
# NOTE: ignore-optional is intentionally NOT set here. The Linux-native Rollup
#   binary (@rollup/rollup-linux-x64-gnu) is an optional dep that IS required
#   on Linux. Setting ignore-optional strips it and breaks vite builds.
#   Windows-specific optional packages (@rollup/rollup-win32-*) that appear
#   in yarn.lock files committed from Windows are handled by purging them from
#   the yarn cache after bench init (see RUN step below).
RUN printf 'ignore-engines true\n' > /home/frappe/.yarnrc

# ── Python via uv ─────────────────────────────────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && /home/frappe/.local/bin/uv python install ${PYTHON_VERSION} --default \
    && /home/frappe/.local/bin/uv python pin ${PYTHON_VERSION} \
    && python --version

# ── Node.js via nvm ───────────────────────────────────────────────────────────
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

# ── Purge Windows-specific optional packages from yarn cache ──────────────────
# Some app yarn.lock files are committed from Windows and contain entries for
# platform-specific optional packages (e.g. @rollup/rollup-win32-*,
# @swc/core-win32-*, esbuild-windows-*) that don't exist in the Linux yarn
# cache. When yarn --check-files runs during bench build it tries to validate
# these and fails with ENOENT on the missing .yarn-metadata.json files.
# Deleting the Windows cache entries lets yarn skip them cleanly without
# needing ignore-optional (which would also strip the required Linux natives).
RUN find /home/frappe/.cache/yarn -type d \( \
        -name '*win32*' \
        -o -name '*windows*' \
        -o -name '*darwin*' \
    \) -exec rm -rf {} + 2>/dev/null || true

# ── Write common_site_config.json with socketio_port for asset build ──────────
# CRM's socket.js imports socketio_port from this file at Rollup/Vite build
# time. An empty {} causes a RollupError.
RUN echo '{"socketio_port": 9000}' \
    > /home/frappe/frappe-bench/sites/common_site_config.json

# ── Compile production JS/CSS assets ──────────────────────────────────────────
RUN bash -c " \
    source ${NVM_DIR}/nvm.sh && \
    cd frappe-bench && \
    /home/frappe/.local/bin/bench build --production"

# ── Reset common_site_config.json to empty for runtime ────────────────────────
RUN echo '{}' > /home/frappe/frappe-bench/sites/common_site_config.json

# -----------------------------------------------------------------------------
# Stage 2: runtime
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
RUN curl -fsSL \
    https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb \
    -o /tmp/wkhtmltox.deb \
    && apt-get install -y /tmp/wkhtmltox.deb \
    && rm /tmp/wkhtmltox.deb \
    && rm -rf /var/lib/apt/lists/* \
    && wkhtmltopdf --version

# ── Recreate frappe user ───────────────────────────────────────────────────────
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

# ── Sanity check ──────────────────────────────────────────────────────────────
RUN /home/frappe/.local/bin/bench --version \
    && python --version \
    && node --version \
    && yarn --version

CMD ["bench", "serve", "--port", "8000"]