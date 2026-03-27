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
    && rm -rf /var/lib/apt/lists/*

# ── frappe user — bench must never run as root ────────────────────────────────
RUN useradd -ms /bin/bash frappe

USER frappe
WORKDIR /home/frappe

# ── Python via uv ─────────────────────────────────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && /home/frappe/.local/bin/uv python install ${PYTHON_VERSION} --default \
    && /home/frappe/.local/bin/uv python pin ${PYTHON_VERSION} \
    && /home/frappe/.local/bin/uv pip install --upgrade "pip>=25.3" \
    && /home/frappe/.local/bin/uv run python --version

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
# Official frappe_docker pattern: APPS_JSON_BASE64 → /opt/frappe/apps.json
# bench init --apps_path then clones all listed apps in one pass.
RUN if [ -n "${APPS_JSON_BASE64}" ]; then \
        mkdir -p /opt/frappe && \
        printf '%s' "${APPS_JSON_BASE64}" | base64 -d > /opt/frappe/apps.json && \
        echo "--- apps.json decoded ---" && \
        cat /opt/frappe/apps.json && \
        echo "--- end apps.json ---"; \
    fi

# ── bench init: clone frappe + all apps ───────────────────────────────────────
RUN bash -c " \
    source ${NVM_DIR}/nvm.sh && \
    PYTHON_BIN=\$( /home/frappe/.local/bin/uv python find ${PYTHON_VERSION} ) && \
    echo \"Using Python: \${PYTHON_BIN}\" && \
    APP_INSTALL_ARGS='' && \
    if [ -f /opt/frappe/apps.json ]; then \
        APP_INSTALL_ARGS='--apps_path /opt/frappe/apps.json'; \
    fi && \
    /home/frappe/.local/bin/bench init \${APP_INSTALL_ARGS} \
        --frappe-branch ${FRAPPE_BRANCH} \
        --frappe-path ${FRAPPE_PATH} \
        --skip-redis-config-generation \
        --python \${PYTHON_BIN} \
        --verbose \
        frappe-bench && \
    cd frappe-bench && \
    echo '{}' > sites/common_site_config.json && \
    find apps -mindepth 1 -path '*/.git' | xargs rm -rf"

# ── Compile production JS/CSS assets ──────────────────────────────────────────
RUN bash -c " \
    source ${NVM_DIR}/nvm.sh && \
    cd frappe-bench && \
    /home/frappe/.local/bin/bench build --production"

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
# Must install from the official wkhtmltopdf release.
RUN curl -fsSL \
    https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb \
    -o /tmp/wkhtmltox.deb \
    && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
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
