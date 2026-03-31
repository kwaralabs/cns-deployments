# syntax=docker/dockerfile:1.7
# ─────────────────────────────────────────────────────────────────────────────
# Frappe v16 custom image — ERPNext + Payments + Frappe LMS
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

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl wget gnupg2 ca-certificates \
        software-properties-common \
        pkg-config \
        mariadb-client libmariadb-dev \
        build-essential gcc g++ make \
        libffi-dev libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev \
        liblzma-dev libncurses-dev \
        libjpeg-dev libpng-dev libfreetype-dev \
        wkhtmltopdf \
        redis-tools gettext-base jq \
    && echo "deb https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu noble main" \
       > /etc/apt/sources.list.d/deadsnakes.list \
    && curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" \
       | gpg --dearmor -o /etc/apt/trusted.gpg.d/deadsnakes.gpg \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3.14 python3.14-dev python3.14-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3.14 -m ensurepip --altinstall \
    && python3.14 -m pip install --upgrade pip setuptools wheel

RUN mkdir -p "$NVM_DIR" \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    && bash -c "source $NVM_DIR/nvm.sh \
        && nvm install ${NODE_VERSION} \
        && nvm alias default ${NODE_VERSION} \
        && npm install -g yarn"

ENV PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH"

RUN python3.14 -m pip install --no-cache-dir frappe-bench

RUN useradd -ms /bin/bash frappe
WORKDIR /home/frappe

COPY --chown=root:root apps.json /opt/apps.json

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

RUN bash -c "source $NVM_DIR/nvm.sh && bench build --production"

RUN find apps -mindepth 1 -name ".git" -type d | xargs rm -rf

RUN echo '{}' > sites/common_site_config.json

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS runtime

ARG NODE_VERSION=24.0.2

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NVM_DIR=/usr/local/nvm

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates \
        software-properties-common \
        mariadb-client libmariadb3 \
        libjpeg8 libpng16-16 libfreetype6 \
        wkhtmltopdf \
        wait-for-it jq gettext-base \
        nginx \
    && echo "deb https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu noble main" \
       > /etc/apt/sources.list.d/deadsnakes.list \
    && curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" \
       | gpg --dearmor -o /etc/apt/trusted.gpg.d/deadsnakes.gpg \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3.14 python3.14-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3.14 -m ensurepip --altinstall \
    && python3.14 -m pip install --upgrade pip

RUN mkdir -p "$NVM_DIR" \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    && bash -c "source $NVM_DIR/nvm.sh \
        && nvm install ${NODE_VERSION} \
        && nvm alias default ${NODE_VERSION}"

ENV PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH"

RUN python3.14 -m pip install --no-cache-dir frappe-bench

RUN useradd -ms /bin/bash frappe

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

# ── Write nginx-entrypoint.sh using printf to avoid heredoc parse issues ──────
RUN printf '#!/bin/bash\n\
\n\
BACKEND=${BACKEND:-localhost:8000}\n\
SOCKETIO=${SOCKETIO:-localhost:9000}\n\
FRAPPE_SITE_NAME_HEADER=${FRAPPE_SITE_NAME_HEADER:-$host}\n\
UPSTREAM_REAL_IP_ADDRESS=${UPSTREAM_REAL_IP_ADDRESS:-127.0.0.1}\n\
UPSTREAM_REAL_IP_HEADER=${UPSTREAM_REAL_IP_HEADER:-X-Forwarded-For}\n\
UPSTREAM_REAL_IP_RECURSIVE=${UPSTREAM_REAL_IP_RECURSIVE:-off}\n\
PROXY_READ_TIMEOUT=${PROXY_READ_TIMEOUT:-120}\n\
CLIENT_MAX_BODY_SIZE=${CLIENT_MAX_BODY_SIZE:-50m}\n\
\n\
rm -f /etc/nginx/sites-enabled/default\n\
\n\
cat > /etc/nginx/conf.d/frappe.conf << NGINX\n\
upstream frappe-server {\n\
    server ${BACKEND} fail_timeout=0;\n\
}\n\
upstream frappe-socketio-server {\n\
    server ${SOCKETIO} fail_timeout=0;\n\
}\n\
server {\n\
    listen 8080;\n\
    server_name _;\n\
    root /home/frappe/frappe-bench/sites;\n\
    real_ip_header ${UPSTREAM_REAL_IP_HEADER};\n\
    set_real_ip_from ${UPSTREAM_REAL_IP_ADDRESS};\n\
    real_ip_recursive ${UPSTREAM_REAL_IP_RECURSIVE};\n\
    proxy_read_timeout ${PROXY_READ_TIMEOUT};\n\
    client_max_body_size ${CLIENT_MAX_BODY_SIZE};\n\
    add_header X-Frame-Options SAMEORIGIN;\n\
    add_header X-Content-Type-Options nosniff;\n\
    location /assets {\n\
        try_files \$uri =404;\n\
    }\n\
    location ~ ^/files/.*\.(htm|html|svg|xml) {\n\
        add_header Content-disposition "attachment";\n\
        try_files \$uri =404;\n\
    }\n\
    location /socket.io {\n\
        proxy_http_version 1.1;\n\
        proxy_buffering off;\n\
        proxy_set_header Upgrade \$http_upgrade;\n\
        proxy_set_header Connection "Upgrade";\n\
        proxy_set_header X-Frappe-Site-Name ${FRAPPE_SITE_NAME_HEADER};\n\
        proxy_set_header Origin \$scheme://\$http_host;\n\
        proxy_set_header Host \$http_host;\n\
        proxy_pass http://frappe-socketio-server;\n\
    }\n\
    location / {\n\
        rewrite ^(.+)/$ \$1 permanent;\n\
        rewrite ^(.+)/index\\.html$ \$1 permanent;\n\
        rewrite ^(.+)\\.html$ \$1 permanent;\n\
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n\
        proxy_set_header X-Forwarded-Proto \$scheme;\n\
        proxy_set_header X-Frappe-Site-Name ${FRAPPE_SITE_NAME_HEADER};\n\
        proxy_set_header Host \$http_host;\n\
        proxy_set_header X-Use-X-Accel-Redirect True;\n\
        proxy_read_timeout ${PROXY_READ_TIMEOUT};\n\
        proxy_redirect off;\n\
        proxy_pass http://frappe-server;\n\
    }\n\
}\n\
NGINX\n\
\n\
exec nginx -g "daemon off;"\n\
' > /usr/local/bin/nginx-entrypoint.sh \
    && chmod +x /usr/local/bin/nginx-entrypoint.sh

# ── Clear sites dir so Docker can mount the named volume cleanly ──────────────
RUN rm -rf /home/frappe/frappe-bench/sites \
    && mkdir -p /home/frappe/frappe-bench/sites \
    && chown frappe:frappe /home/frappe/frappe-bench/sites

WORKDIR /home/frappe/frappe-bench

USER frappe

CMD ["bash"]