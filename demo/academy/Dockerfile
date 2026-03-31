# syntax=docker/dockerfile:1.7
# ─────────────────────────────────────────────────────────────────────────────
# Frappe v16 custom image — ERPNext + Payments + Frappe LMS
#
# Runtime requirements for Frappe v16:
#   Python  3.14
#   Node.js 24 LTS
#   MariaDB 10.6+ (external service)
#   Redis         (external service)
#
# apps.json lives in the same directory as this Dockerfile and is copied
# directly into the build context — no base64 encoding needed.
# ─────────────────────────────────────────────────────────────────────────────

ARG FRAPPE_PATH=https://github.com/frappe/frappe
ARG FRAPPE_BRANCH=version-16
ARG PYTHON_VERSION=3.14.0
ARG NODE_VERSION=24.0.2

# ── Stage 1: builder ──────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

ARG FRAPPE_PATH
ARG FRAPPE_BRANCH
ARG PYTHON_VERSION
ARG NODE_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NVM_DIR=/usr/local/nvm

# ── System deps ───────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl wget gnupg2 ca-certificates \
        software-properties-common \
        mariadb-client libmariadb-dev \
        build-essential gcc g++ make \
        libffi-dev libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev \
        liblzma-dev libncurses-dev \
        libjpeg-dev libpng-dev libfreetype-dev \
        wkhtmltopdf \
        redis-tools gettext-base jq \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3.14 python3.14-dev python3.14-venv \
    && rm -rf /var/lib/apt/lists/*

# ── Bootstrap pip for Python 3.14 cleanly ─────────────────────────────────────
# Use get-pip.py directly — avoids the conflict between system pip (installed
# by debian for python3.12) and python3.14's ensurepip trying to overwrite it.
RUN python3.14 -m ensurepip --altinstall \
    && python3.14 -m pip install --upgrade pip setuptools wheel

# ── Node.js 24 via NVM ────────────────────────────────────────────────────────
RUN mkdir -p "$NVM_DIR" \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    && bash -c "source $NVM_DIR/nvm.sh \
        && nvm install ${NODE_VERSION} \
        && nvm alias default ${NODE_VERSION} \
        && npm install -g yarn"

ENV PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH"

# ── frappe-bench CLI ──────────────────────────────────────────────────────────
RUN python3.14 -m pip install --no-cache-dir frappe-bench

# ── frappe user ───────────────────────────────────────────────────────────────
RUN useradd -ms /bin/bash frappe
WORKDIR /home/frappe

# ── Copy apps.json from build context ─────────────────────────────────────────
# apps.json sits next to this Dockerfile in the repo.
# Edit it to add/remove apps, then push — Dokploy rebuilds automatically.
COPY --chown=root:root apps.json /opt/apps.json

# ── bench init ────────────────────────────────────────────────────────────────
USER frappe
RUN bash -c "source $NVM_DIR/nvm.sh \
    && bench init \
        --frappe-path=${FRAPPE_PATH} \
        --frappe-branch=${FRAPPE_BRANCH} \
        --apps_path=/opt/apps.json \
        --python=python3.14 \
        --no-procfile \
        --no-backups \
        --skip-redis-config-generation \
        --skip-assets \
        --verbose \
        /home/frappe/frappe-bench"

WORKDIR /home/frappe/frappe-bench

# ── Build JS/CSS assets ───────────────────────────────────────────────────────
RUN bash -c "source $NVM_DIR/nvm.sh && bench build --production"

# ── Strip .git dirs to slim the image ────────────────────────────────────────
RUN find apps -mindepth 1 -name ".git" -type d | xargs rm -rf

RUN echo '{}' > sites/common_site_config.json

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS runtime

ARG NODE_VERSION=24.0.2

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NVM_DIR=/usr/local/nvm

# ── Runtime system packages ───────────────────────────────────────────────────
# NOTE: Do NOT install python3-pip here — it installs pip for the system
# python3.12 and conflicts when we bootstrap pip for python3.14.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates \
        software-properties-common \
        mariadb-client libmariadb3 \
        libjpeg8 libpng16-16 libfreetype6 \
        wkhtmltopdf \
        wait-for-it jq gettext-base \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3.14 python3.14-venv \
    && rm -rf /var/lib/apt/lists/*

# ── Bootstrap pip for Python 3.14 (runtime stage) ─────────────────────────────
# --altinstall installs pip3.14 without touching /usr/bin/pip3 or pip,
# so there is no conflict with any system-managed pip package.
RUN python3.14 -m ensurepip --altinstall \
    && python3.14 -m pip install --upgrade pip

# ── Node 24 (needed by socketio.js) ──────────────────────────────────────────
RUN mkdir -p "$NVM_DIR" \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    && bash -c "source $NVM_DIR/nvm.sh \
        && nvm install ${NODE_VERSION} \
        && nvm alias default ${NODE_VERSION}"

ENV PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH"

# ── frappe-bench CLI ──────────────────────────────────────────────────────────
RUN python3.14 -m pip install --no-cache-dir frappe-bench

# ── frappe user ───────────────────────────────────────────────────────────────
RUN useradd -ms /bin/bash frappe

# ── Copy bench from builder ───────────────────────────────────────────────────
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

USER frappe

CMD ["bash"]
