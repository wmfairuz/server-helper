#!/bin/bash
# setup-deployers.sh
# Run once to configure the deployers group, app directory permissions, and sudoers.
#
# Usage: ./setup-deployers.sh [app_path] [php_version]
# Example: ./setup-deployers.sh /opt/www/myapp 8.1

set -euo pipefail

APP_PATH="${1:-/opt/www/app}"
PHP_VERSION="${2:-8.1}"
GROUP="deployers"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi

echo "==> Deployers setup"
echo "    App path    : $APP_PATH"
echo "    PHP version : $PHP_VERSION"
echo "    Group       : $GROUP"
echo ""

# Create group
if ! getent group "$GROUP" > /dev/null 2>&1; then
    groupadd "$GROUP"
    echo "[+] Created group: $GROUP"
else
    echo "[~] Group already exists: $GROUP"
fi

# Create and configure app directory
mkdir -p "$APP_PATH"
chown -R root:"$GROUP" "$APP_PATH"
chmod -R 775 "$APP_PATH"
# Setgid so new files/dirs inherit the group automatically
find "$APP_PATH" -type d -exec chmod g+s {} \;
echo "[+] Permissions set on: $APP_PATH"

# Sudoers file for deployers group
SUDOERS_FILE="/etc/sudoers.d/deployers"
cat > "$SUDOERS_FILE" << EOF
# Deployers — service management only, no general sudo
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart nginx
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart php${PHP_VERSION}-fpm
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload php${PHP_VERSION}-fpm
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart supervisor
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart redis-server
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl status nginx
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl status php${PHP_VERSION}-fpm
%deployers ALL=(ALL) NOPASSWD: /usr/bin/systemctl status supervisor
%deployers ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl *
EOF

chmod 440 "$SUDOERS_FILE"

# Validate before keeping
if visudo -c -f "$SUDOERS_FILE" > /dev/null 2>&1; then
    echo "[+] Sudoers configured: $SUDOERS_FILE"
else
    rm "$SUDOERS_FILE"
    echo "[!] Sudoers syntax error — file removed. Check PHP version parameter." >&2
    exit 1
fi

echo ""
echo "==> Done. Run ./add-deploy-user.sh <username> to add team members."
