# ──────────────────────────────────────────────────────────────────────────────
# Stage 1 — builder
#
# Clones MISP, resolves PHP (Composer) and Python (pip) dependencies.
# Keeping build tooling out of the final image reduces attack surface and size.
# ──────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

ARG MISP_VERSION=v2.5.37
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates \
        php8.3-cli php8.3-xml php8.3-mbstring php8.3-zip php8.3-curl \
        php8.3-gd php8.3-intl php8.3-bcmath \
        composer \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone the pinned tag — --progress emits transfer stats even without a TTY
RUN git clone --depth 1 --branch "${MISP_VERSION}" --progress \
        https://github.com/MISP/MISP.git misp

# Pull submodules in a separate layer so a hang is immediately identifiable.
# --progress keeps git reporting per-submodule transfer stats during the wait.
RUN git -C misp submodule update --init --recursive --depth 1 --jobs 8 --progress

# PHP vendor dependencies — skip platform checks that require runtime extensions
WORKDIR /build/misp/app
RUN composer install \
        --no-dev \
        --optimize-autoloader \
        --ignore-platform-reqs \
        --no-interaction

# Python virtual environment with PyMISP and common MISP Python libs
WORKDIR /build/misp
RUN python3 -m venv /opt/misp-venv \
    && /opt/misp-venv/bin/pip install --upgrade pip --quiet \
    && /opt/misp-venv/bin/pip install --quiet pymisp plyara \
    && if [ -f requirements.txt ]; then \
           /opt/misp-venv/bin/pip install --quiet -r requirements.txt; \
       fi

# ──────────────────────────────────────────────────────────────────────────────
# Stage 2 — runtime / pusher
#
# Lean Ubuntu image with only what MISP needs at run time.
# This is the image that gets tagged and pushed to the registry.
# ──────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        apache2 \
        libapache2-mod-php8.3 \
        php8.3 php8.3-cli \
        php8.3-mysql php8.3-gd php8.3-xml php8.3-zip \
        php8.3-mbstring php8.3-curl php8.3-redis \
        php8.3-intl php8.3-bcmath \
        python3 \
        mariadb-client \
        redis-tools \
        supervisor \
        gnupg \
        curl \
        openssl \
    && apt-get install -y php8.3-gnupg 2>/dev/null \
        || (pecl install gnupg \
            && echo "extension=gnupg.so" > /etc/php/8.3/apache2/conf.d/20-gnupg.ini \
            && echo "extension=gnupg.so" > /etc/php/8.3/cli/conf.d/20-gnupg.ini) \
    && a2enmod rewrite headers expires \
    && rm -rf /var/lib/apt/lists/*

# ── Application ───────────────────────────────────────────────────────────────

COPY --from=builder --chown=www-data:www-data /build/misp /var/www/MISP
COPY --from=builder /opt/misp-venv /opt/misp-venv

# ── Apache ────────────────────────────────────────────────────────────────────

COPY config/apache-misp.conf /etc/apache2/sites-available/misp.conf
RUN a2ensite misp.conf && a2dissite 000-default.conf

# ── Supervisor ────────────────────────────────────────────────────────────────

COPY config/supervisord.conf /etc/supervisor/conf.d/misp.conf

# ── Provisioning scripts ──────────────────────────────────────────────────────

COPY provisioning/entrypoint.sh     /entrypoint.sh
COPY provisioning/configure-misp.sh /provisioning/configure-misp.sh
COPY provisioning/wait-for-tcp.sh   /provisioning/wait-for-tcp.sh

RUN chmod +x \
        /entrypoint.sh \
        /provisioning/configure-misp.sh \
        /provisioning/wait-for-tcp.sh

# ── Writable directories ──────────────────────────────────────────────────────

# COPY --chown already set ownership; only chmod is needed here.
# chmod -R 750 on the full tree is slow but unavoidable — don't add a second
# chown pass on top of it.
RUN mkdir -p \
        /var/www/MISP/app/tmp/cache/models \
        /var/www/MISP/app/tmp/cache/persistent \
        /var/www/MISP/app/tmp/logs \
        /var/www/MISP/app/webroot/img/orgs \
        /var/www/MISP/app/webroot/img/custom \
        /var/www/MISP/app/files \
        /var/www/MISP/app/attachments \
    && chmod -R 750 /var/www/MISP \
    && chmod -R 770 \
        /var/www/MISP/app/tmp \
        /var/www/MISP/app/webroot/img/orgs \
        /var/www/MISP/app/webroot/img/custom \
        /var/www/MISP/app/files \
        /var/www/MISP/app/attachments

# Shared volume — admin auth-key written by entrypoint, read by provisioner
RUN mkdir -p /keys && chmod 770 /keys

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=6 \
    CMD curl -sf http://localhost/users/login | grep -qi "misp" || exit 1

ENTRYPOINT ["/entrypoint.sh"]
