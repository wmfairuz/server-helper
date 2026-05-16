#!/bin/bash
# setup-deployers.sh
# Run once per app to configure a per-app deployers group, directory permissions, and sudoers.
#
# Usage: ./setup-deployers.sh <app_path> <php_version> <group_name>
# Example: ./setup-deployers.sh /opt/www/appA 8.1 deployers-appA

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <app_path> <php_version> <group_name>"
    echo ""
    echo "Examples:"
    echo "  $0 /opt/www/appA 8.1 deployers-appA"
    echo "  $0 /opt/www/appB 8.2 deployers-appB"
    exit 1
fi

APP_PATH="$1"
PHP_VERSION="$2"
GROUP="$3"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi

# Validate group name
if ! [[ "$GROUP" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "[!] Invalid group name: $GROUP" >&2
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

# Per-app sudoers file — named after the group to avoid collisions
SUDOERS_FILE="/etc/sudoers.d/${GROUP}"
cat > "$SUDOERS_FILE" << EOF
# ${GROUP} — service management only, no general sudo
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart nginx
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart php${PHP_VERSION}-fpm
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload php${PHP_VERSION}-fpm
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart supervisor
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart redis-server
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl status nginx
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl status php${PHP_VERSION}-fpm
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/systemctl status supervisor
%${GROUP} ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl *
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
echo "==> Done. Add teammates with:"
echo "    GROUP=$GROUP ./add-deploy-user.sh <username> [ssh_public_key]"
