#!/bin/bash
# add-deploy-user.sh
# Add a new team member to a per-app deployers group.
#
# Usage: GROUP=<group> ./add-deploy-user.sh <username> [ssh_public_key]
# Example: GROUP=deployers-appA ./add-deploy-user.sh alice 'ssh-ed25519 AAAA...'
#
# APP_PATH is only used in the summary output — set it to match your app.
# APP_PATH=/opt/www/appA GROUP=deployers-appA ./add-deploy-user.sh alice

set -euo pipefail

APP_PATH="${APP_PATH:-/opt/www/app}"
GROUP="${GROUP:?Usage: GROUP=<group_name> $0 <username> [ssh_public_key]}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: GROUP=<group_name> $0 <username> [ssh_public_key]"
    echo ""
    echo "Examples:"
    echo "  GROUP=deployers-appA $0 alice"
    echo "  GROUP=deployers-appA $0 alice 'ssh-ed25519 AAAA...'"
    echo "  APP_PATH=/opt/www/appA GROUP=deployers-appA $0 alice 'ssh-ed25519 AAAA...'"
    exit 1
fi

USERNAME="$1"
SSH_KEY="${2:-}"

# Validate username
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "[!] Invalid username: $USERNAME" >&2
    exit 1
fi

echo "==> Adding deploy user: $USERNAME"
echo ""

# Create user or add to group if already exists
if ! id "$USERNAME" > /dev/null 2>&1; then
    useradd -m -s /bin/bash "$USERNAME"
    echo "[+] Created user: $USERNAME"
else
    echo "[~] User already exists: $USERNAME"
fi

usermod -aG "$GROUP" "$USERNAME"
echo "[+] Added to group: $GROUP"

# Log access — adm covers /var/log/, systemd-journal covers journalctl
usermod -aG adm "$USERNAME"
usermod -aG systemd-journal "$USERNAME"
echo "[+] Added to log groups: adm, systemd-journal"

# SSH directory
SSH_DIR="/home/$USERNAME/.ssh"
mkdir -p "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
echo "[+] SSH directory ready: $SSH_DIR"

# SSH public key
if [ -n "$SSH_KEY" ]; then
    # Avoid duplicate keys
    if grep -qF "$SSH_KEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        echo "[~] SSH key already present — skipped"
    else
        echo "$SSH_KEY" >> "$SSH_DIR/authorized_keys"
        echo "[+] SSH public key added"
    fi
else
    echo ""
    echo "[!] No SSH key provided. Add it manually when you have it:"
    echo "    echo 'ssh-ed25519 AAAA...' >> $SSH_DIR/authorized_keys"
fi

echo ""
echo "==> $USERNAME is ready."
echo "    Groups : $(id -nG "$USERNAME")"
echo "    Keys   : $(wc -l < "$SSH_DIR/authorized_keys") key(s) in authorized_keys"
echo ""
echo "    Can do:"
echo "    - SSH into server on your configured port"
echo "    - git pull / composer install / php artisan * in $APP_PATH"
echo "    - sudo systemctl restart nginx, php-fpm, supervisor"
echo "    - journalctl, tail /var/log/nginx/*, /var/log/php*"
