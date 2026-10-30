#!/bin/bash

set -e

declare -g CGIT_PUBLIC_DOMAIN="YOUR_CGIT_PUBLIC_DOMAIN"
declare -g CGIT_EMAIL="YOUR_CGIT_EMAIL"

declare -g CGIT_REPOSITORY="https://git.zx2c4.com/cgit.git"
declare -g CGIT_SOURCE="/usr/local/src/cgit"
declare -g CGIT_ROOT="/var/www/htdocs/cgit"
declare -g CGIT_CACHE="/var/cache/cgit"
declare -g CGIT_CGITRC="/etc/cgitrc"

declare -g GIT_ROOT="/srv/git"

declare -g TLS_CERT="/etc/letsencrypt/live/${CGIT_PUBLIC_DOMAIN}/fullchain.pem"
declare -g TLS_KEY="/etc/letsencrypt/live/${CGIT_PUBLIC_DOMAIN}/privkey.pem"

declare -g NGINX_SITE="/etc/nginx/sites-available/cgit"

function distribution() {
    if [ ! -f "/etc/debian_version" ]; then
        echo "ERROR: Linux distribution must be Ubuntu!"
        exit 1
    fi
}

function root() {
    if [ "$(echo ${USER})" != "root" ]; then
        echo "WARNING: You must be root to run the script!"
        exit 1
    fi
}

# Install dependencies
function install_dependencies() {
apt-get update -y

apt-get install \
    build-essential \
    git \
    pkg-config \
    libssl-dev \
    libzip-dev \
    zlib1g-dev \
    nginx \
    fcgiwrap \
    certbot \
    python3-certbot-nginx -y
}

# Install cgit
function install_cgit() {
# Download cgit
if [ ! -d "${CGIT_SOURCE}" ]; then
    mkdir -p "$(dirname "${CGIT_SOURCE}")"
fi

if [ ! -d "${CGIT_SOURCE}/.git" ]; then
    git clone \
        --recurse-submodules \
        "${CGIT_REPOSITORY}" \
        "${CGIT_SOURCE}"
else
    git -C "${CGIT_SOURCE}" pull --ff-only
    git -C "${CGIT_SOURCE}" submodule update --init --recursive
fi

# Build and install cgit
make \
    -C "${CGIT_SOURCE}" \
    -j"$(nproc)" \
    NO_LUA=1

make \
    -C "${CGIT_SOURCE}" \
    NO_LUA=1 \
    install

# Create directories
if [ ! -d "${GIT_ROOT}" ]; then
    mkdir -p "${GIT_ROOT}"
fi

install \
    -d \
    -o www-data \
    -g www-data \
    -m 750 \
    "${CGIT_CACHE}"
}

# Configure cgit
function configure_cgit() {
cat >"${CGIT_CGITRC}" <<EOF
root-title=YOUR_NAME's Git Repositories
root-desc=Personal Git repositories hosted at YOUR_CGIT_PUBLIC_DOMAIN

virtual-root=/

css=/cgit.css
js=/cgit.js
logo=/cgit.png
favicon=/favicon.ico

cache-size=1000
cache-root=${CGIT_CACHE}

cache-root-ttl=1
cache-repo-ttl=1
cache-dynamic-ttl=1
cache-about-ttl=1
cache-scanrc-ttl=1

enable-index-owner=1
enable-index-links=1

enable-blame=1
enable-commit-graph=1
enable-log-filecount=1
enable-log-linecount=1
enable-tree-linenumbers=1
enable-remote-branches=1
enable-subject-links=1

enable-git-config=1
enable-http-clone=1

branch-sort=age
max-stats=year

clone-url=https://${CGIT_PUBLIC_DOMAIN}/$CGIT_REPO_URL

snapshots=tar.gz tar.xz zip

about-filter=/usr/local/lib/cgit/filters/about-formatting.sh

readme=:README.md
readme=:readme.md
readme=:README.mkd
readme=:readme.mkd
readme=:README.rst
readme=:readme.rst
readme=:README.html
readme=:readme.html
readme=:README.htm
readme=:readme.htm
readme=:README.txt
readme=:readme.txt
readme=:README
readme=:readme

readme=:INSTALL.md
readme=:install.md
readme=:INSTALL.mkd
readme=:install.mkd
readme=:INSTALL.rst
readme=:install.rst
readme=:INSTALL.html
readme=:install.html
readme=:INSTALL.htm
readme=:install.htm
readme=:INSTALL.txt
readme=:install.txt
readme=:INSTALL
readme=:install

remove-suffix=1

section-from-path=1
section-sort=1
scan-path=${GIT_ROOT}
EOF
}

# Start fcgiwrap
function start_fcgiwrap() {
systemctl enable --now fcgiwrap.socket
}

# Temporary HTTP configuration for Let's Encrypt
function configure_temp_nginx() {
cat >"${NGINX_SITE}" <<EOF
server {
    listen 80;

    server_name ${CGIT_PUBLIC_DOMAIN};

    root ${CGIT_ROOT};

    location = /cgit.css {
        try_files \$uri =404;
    }

    location = /cgit.js {
        try_files \$uri =404;
    }

    location = /cgit.png {
        try_files \$uri =404;
    }

    location = /favicon.ico {
        try_files \$uri =404;
    }

    location = /robots.txt {
        try_files \$uri =404;
    }

    location / {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME ${CGIT_ROOT}/cgit.cgi;
        fastcgi_param PATH_INFO \$uri;
        fastcgi_param QUERY_STRING \$args;

        fastcgi_pass unix:/run/fcgiwrap.socket;
    }
}
EOF

# Enable Nginx site
rm -f /etc/nginx/sites-enabled/default

ln -sfn \
    "${NGINX_SITE}" \
    /etc/nginx/sites-enabled/cgit

nginx -t

systemctl enable --now nginx
systemctl reload nginx
}

# Apply for Let's Encrypt TLS certificate
function configure_tls() {
certbot certonly \
    --nginx \
    --non-interactive \
    --agree-tos \
    --no-eff-email \
    --email "${CGIT_EMAIL}" \
    -d "${CGIT_PUBLIC_DOMAIN}"
}

# Final Nginx configuration
function configure_final_nginx() {
cat >"${NGINX_SITE}" <<EOF
# Reject unknown HTTP hosts
server {
    listen 80 default_server;

    server_name _;

    return 444;
}

# Redirect HTTP to HTTPS
server {
    listen 80;

    server_name ${CGIT_PUBLIC_DOMAIN};

    return 301 https://${CGIT_PUBLIC_DOMAIN}\$request_uri;
}

# Reject unknown HTTPS SNI
server {
    listen 443 ssl default_server;

    server_name _;

    ssl_reject_handshake on;
}

# cgit HTTPS
server {
    listen 443 ssl;

    server_name ${CGIT_PUBLIC_DOMAIN};

    ssl_certificate ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};

    root ${CGIT_ROOT};

    location = /cgit.css {
        try_files \$uri =404;
    }

    location = /cgit.js {
        try_files \$uri =404;
    }

    location = /cgit.png {
        try_files \$uri =404;
    }

    location = /favicon.ico {
        try_files \$uri =404;
    }

    location = /robots.txt {
        try_files \$uri =404;
    }

    location / {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME ${CGIT_ROOT}/cgit.cgi;
        fastcgi_param PATH_INFO \$uri;
        fastcgi_param QUERY_STRING \$args;
        fastcgi_param HTTPS on;
        fastcgi_param HTTP_HOST \$host;

        fastcgi_pass unix:/run/fcgiwrap.socket;
    }
}
EOF

# Reload Nginx
nginx -t
systemctl reload nginx
}

# Verify cgit
function verify_cgit() {
RESPONSE="$(mktemp)"

HTTP_CODE="$(
    curl \
        -s \
        -o "${RESPONSE}" \
        -w '%{http_code}' \
        --resolve "${CGIT_PUBLIC_DOMAIN}:443:127.0.0.1" \
        "https://${CGIT_PUBLIC_DOMAIN}/"
)"

if [ "${HTTP_CODE}" = "200" ]; then
    echo "NOTICE: cgit deployment successful!"
elif [ "${HTTP_CODE}" = "404" ] &&
     grep -q "No repositories found" "${RESPONSE}"; then
    echo "WARNING: cgit deployment successful, but no repositories found in ${GIT_ROOT}!"
    rm -f "${RESPONSE}"
    exit 1
else
    echo "ERROR: cgit verification failed. HTTP ${HTTP_CODE}!"
    cat "${RESPONSE}"
    rm -f "${RESPONSE}"
    exit 1
fi

rm -f "${RESPONSE}"
}

# Configure cgit permissions
function configure_cgit_permissions() {
    groupadd -f cgit

    usermod -aG cgit www-data
    usermod -aG cgit ubuntu

    chgrp -R cgit /srv/git
    chmod -R g+rX /srv/git
    chown -R ubuntu:cgit /srv/git

    find /srv/git -type d -exec chmod g+s {} +
}

function install_and_run() {
    install_dependencies
    install_cgit
    configure_cgit
    start_fcgiwrap
    configure_temp_nginx
    configure_tls
    configure_final_nginx
    verify_cgit
    configure_cgit_permissions
}

function remove() {
    # Remove Let's Encrypt certificate
    if command -v certbot >/dev/null 2>&1; then
        if certbot certificates 2>/dev/null |
           grep -q "Certificate Name: ${CGIT_PUBLIC_DOMAIN}"; then
            certbot delete \
                --non-interactive \
                --cert-name "${CGIT_PUBLIC_DOMAIN}"
        fi
    fi

    # Remove Nginx cgit site
    rm -f /etc/nginx/sites-enabled/cgit
    rm -f "${NGINX_SITE}"

    # Reload Nginx before uninstalling it
    if command -v nginx >/dev/null 2>&1 &&
       systemctl is-active --quiet nginx; then
        if nginx -t; then
            systemctl reload nginx
        fi
    fi

    # Stop and disable fcgiwrap
    systemctl disable --now fcgiwrap.socket 2>/dev/null || true
    systemctl disable --now fcgiwrap.service 2>/dev/null || true

    # Uninstall cgit files installed by Makefile
    if [ -f "${CGIT_SOURCE}/Makefile" ]; then
        make -C "${CGIT_SOURCE}" uninstall || true
    fi

    # Remove cgit configuration and generated files
    rm -f "${CGIT_CGITRC}"

    rm -rf \
        "${CGIT_SOURCE}" \
        "${CGIT_ROOT}" \
        "${CGIT_CACHE}" \
        /usr/local/lib/cgit

    # Remove cgit group safely while preserving Git repositories
    if getent group cgit >/dev/null 2>&1; then
        if id ubuntu >/dev/null 2>&1; then
            REPOSITORY_GROUP="$(id -gn ubuntu)"
        else
            REPOSITORY_GROUP="root"
        fi

        if [ -d "${GIT_ROOT}" ]; then
            # Replace the cgit group with a valid group before deleting it
            find "${GIT_ROOT}" \
                -group cgit \
                -exec chgrp "${REPOSITORY_GROUP}" {} +

            # Remove SetGID bits added by configure_cgit_permissions
            find "${GIT_ROOT}" \
                -type d \
                -perm -2000 \
                -exec chmod g-s {} +
        fi

        # Remove supplementary group memberships
        if id -nG www-data 2>/dev/null |
           tr ' ' '\n' |
           grep -qx cgit; then
            gpasswd -d www-data cgit >/dev/null 2>&1 || true
        fi

        if id -nG ubuntu 2>/dev/null |
           tr ' ' '\n' |
           grep -qx cgit; then
            gpasswd -d ubuntu cgit >/dev/null 2>&1 || true
        fi

        groupdel cgit
    fi

    # Remove packages installed for cgit
    apt-get purge \
        build-essential \
        git \
        pkg-config \
        libssl-dev \
        libzip-dev \
        zlib1g-dev \
        nginx \
        fcgiwrap \
        certbot \
        python3-certbot-nginx \
        -y

    # Remove dependencies that are no longer required
    apt-get autoremove --purge -y

    # Clean downloaded package cache
    apt-get clean

    echo "NOTICE: cgit removed successfully!"
    echo "NOTICE: Git repositories preserved: ${GIT_ROOT}"
    exit 0
}

function help() {
    cat <<EOF
USAGE
  bash cgit.sh [OPTION]

OPTION
  -h, --help        Show help manual
  -i, --install     Install "cgit" and run
  -p, --permissions Configure "cgit" repositories permissions
  -r, --remove      Remove "cgit" and all configuration files
EOF
    exit 0
}

function main() {
    distribution
    root

    if [ "$#" -eq 0 ]; then
        help
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                help
                ;;
            -i|--install)
                install_and_run
                ;;
            -p|--permissions)
                configure_cgit_permissions
                ;;
            -r|--remove)
                remove
                ;;
            *)
                echo "ERROR: Invalid option \"$1\"!"
                exit 1
                ;;
        esac
        shift
    done
}

main "$@"
