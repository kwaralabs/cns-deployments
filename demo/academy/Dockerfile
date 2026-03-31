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
#
# To add or remove apps, just edit apps.json and redeploy.
#
# Build args (all have defaults; override via Dokploy env panel if needed):
#   FRAPPE_PATH    Frappe git URL
#   FRAPPE_BRANCH  Frappe branch
#   PYTHON_VERSION Full Python version string (e.g. 3.14.0)
#   NODE_VERSION   Full Node version string  (e.g. 24.0.2)
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

RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.14 10 \
    && python3.14 -m ensurepip --upgrade \
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
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates \
        software-properties-common \
        python3-pip \
        mariadb-client libmariadb3 \
        libjpeg8 libpng16-16 libfreetype6 \
        wkhtmltopdf \
        wait-for-it jq gettext-base \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3.14 python3.14-venv \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.14 10 \
    && python3.14 -m ensurepip --upgrade \
    && python3.14 -m pip install --upgrade pip \
    && rm -rf /var/lib/apt/lists/*

# ── Node 24 (needed by socketio.js) ──────────────────────────────────────────
RUN mkdir -p "$NVM_DIR" \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    && bash -c "source $NVM_DIR/nvm.sh \
        && nvm install ${NODE_VERSION} \
        && nvm alias default ${NODE_VERSION}"

ENV PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH"

RUN python3.14 -m pip install --no-cache-dir frappe-bench

RUN useradd -ms /bin/bash frappe

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

USER frappe

CMD ["bash"]
