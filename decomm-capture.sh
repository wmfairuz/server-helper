#!/bin/bash
###############################################################################
# decomm-capture.sh
# Captures everything needed to migrate Laravel apps from Server A to Server B
#
# Usage:
#   sudo bash decomm-capture.sh /var/www/myapp
#   sudo bash decomm-capture.sh /var/www/myapp1 /var/www/myapp2
#   sudo bash decomm-capture.sh -o /mnt/backup/decomm /var/www/myapp
#
# Output: Creates <output-dir>/<app-name>_<timestamp>/ with all captured data
#         Default output dir: ~/decomm
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASE_OUTPUT="$HOME/decomm"

while getopts ":o:" opt; do
    case "$opt" in
        o) BASE_OUTPUT="$OPTARG" ;;
        :) err "Option -$OPTARG requires an argument."; exit 1 ;;
        \?) err "Unknown option: -$OPTARG"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ $# -eq 0 ]; then
    echo "Usage: sudo bash $0 [-o /output/dir] /path/to/laravel-app [/path/to/another-app ...]"
    exit 1
fi
mkdir -p "$BASE_OUTPUT"

# ─── Server-wide info (captured once) ────────────────────────────────────────
capture_server_info() {
    local SERVER_DIR="$BASE_OUTPUT/server_info_${TIMESTAMP}"
    mkdir -p "$SERVER_DIR"

    log "Capturing server-wide info..."

    # PHP version & extensions
    php -v > "$SERVER_DIR/php_version.txt" 2>&1 || warn "Could not get PHP version"
    php -m > "$SERVER_DIR/php_modules.txt" 2>&1 || true
    php -i > "$SERVER_DIR/phpinfo.txt" 2>&1 || true

    # PHP-FPM pool configs
    if [ -d /etc/php ]; then
        find /etc/php -name "*.conf" -path "*/fpm/*" -exec cp --parents {} "$SERVER_DIR/" \; 2>/dev/null || true
    fi

    # Composer version
    composer --version > "$SERVER_DIR/composer_version.txt" 2>&1 || true

    # OS info
    cat /etc/os-release > "$SERVER_DIR/os_release.txt" 2>&1 || true
    uname -a > "$SERVER_DIR/uname.txt" 2>&1 || true

    # All crontabs
    {
        echo "=== root crontab ==="
        crontab -l 2>/dev/null || echo "(none)"
        echo ""
        for user in $(cut -f1 -d: /etc/passwd); do
            local cron
            cron=$(crontab -u "$user" -l 2>/dev/null) || continue
            if [ -n "$cron" ]; then
                echo "=== $user crontab ==="
                echo "$cron"
                echo ""
            fi
        done
        echo "=== /etc/cron.d/ ==="
        ls -la /etc/cron.d/ 2>/dev/null || echo "(none)"
        for f in /etc/cron.d/*; do
            [ -f "$f" ] && echo "--- $f ---" && cat "$f"
        done
    } > "$SERVER_DIR/all_crontabs.txt" 2>&1

    # Custom /etc/hosts entries
    cp /etc/hosts "$SERVER_DIR/etc_hosts.txt" 2>/dev/null || true

    # Logrotate configs
    mkdir -p "$SERVER_DIR/logrotate"
    cp /etc/logrotate.conf "$SERVER_DIR/logrotate/" 2>/dev/null || true
    cp -r /etc/logrotate.d/ "$SERVER_DIR/logrotate/" 2>/dev/null || true

    # Nginx global config
    cp /etc/nginx/nginx.conf "$SERVER_DIR/nginx_global.conf" 2>/dev/null || true

    # All supervisord config (global)
    if [ -f /etc/supervisor/supervisord.conf ]; then
        cp /etc/supervisor/supervisord.conf "$SERVER_DIR/supervisord_global.conf"
    fi

    # Firewall rules
    iptables -L -n > "$SERVER_DIR/iptables.txt" 2>&1 || true
    ufw status verbose > "$SERVER_DIR/ufw_status.txt" 2>&1 || true

    # Installed packages (useful for matching Server B)
    dpkg --get-selections > "$SERVER_DIR/installed_packages.txt" 2>&1 || true

    log "Server info saved to $SERVER_DIR"
}

# ─── Per-app capture ─────────────────────────────────────────────────────────
capture_app() {
    local APP_PATH="$1"

    # Resolve symlinks and validate
    APP_PATH=$(realpath "$APP_PATH" 2>/dev/null || echo "$APP_PATH")
    if [ ! -d "$APP_PATH" ]; then
        err "Directory not found: $APP_PATH"
        return 1
    fi

    local APP_NAME
    APP_NAME=$(basename "$APP_PATH")
    local OUTPUT_DIR="$BASE_OUTPUT/${APP_NAME}_${TIMESTAMP}"
    mkdir -p "$OUTPUT_DIR"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Capturing: $APP_NAME ($APP_PATH)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── 1. Git info ──────────────────────────────────────────────────────────
    if [ -d "$APP_PATH/.git" ]; then
        log "Capturing git info..."
        (
            cd "$APP_PATH"
            {
                echo "Branch:    $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'detached')"
                echo "Commit:    $(git rev-parse HEAD 2>/dev/null)"
                echo "Short:     $(git rev-parse --short HEAD 2>/dev/null)"
                echo "Date:      $(git log -1 --format=%ci 2>/dev/null)"
                echo "Message:   $(git log -1 --format=%s 2>/dev/null)"
                echo "Remote(s):"
                git remote -v 2>/dev/null
                echo ""
                echo "Status:"
                git status --short 2>/dev/null
                echo ""
                echo "Recent commits (last 10):"
                git log --oneline -10 2>/dev/null
            } > "$OUTPUT_DIR/git_info.txt"
        )
    else
        warn "No .git directory found in $APP_PATH"
        echo "No git repository found" > "$OUTPUT_DIR/git_info.txt"
    fi

    # ── 2. Enterstripe package (symlink check) ──────────────────────────────
    local ES_PATH="$APP_PATH/enterstripe-package"
    if [ -e "$ES_PATH" ]; then
        log "Found enterstripe-package, capturing info..."
        local REAL_ES_PATH
        REAL_ES_PATH=$(realpath "$ES_PATH")

        {
            echo "Symlink:     $ES_PATH"
            echo "Resolves to: $REAL_ES_PATH"
            echo "Is symlink:  $([ -L "$ES_PATH" ] && echo 'yes' || echo 'no')"
            echo ""
        } > "$OUTPUT_DIR/enterstripe_package_info.txt"

        if [ -d "$REAL_ES_PATH/.git" ]; then
            (
                cd "$REAL_ES_PATH"
                {
                    echo "Branch:    $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'detached')"
                    echo "Commit:    $(git rev-parse HEAD 2>/dev/null)"
                    echo "Short:     $(git rev-parse --short HEAD 2>/dev/null)"
                    echo "Date:      $(git log -1 --format=%ci 2>/dev/null)"
                    echo "Message:   $(git log -1 --format=%s 2>/dev/null)"
                    echo "Remote(s):"
                    git remote -v 2>/dev/null
                } >> "$OUTPUT_DIR/enterstripe_package_info.txt"
            )
        else
            echo "No .git directory in enterstripe-package" >> "$OUTPUT_DIR/enterstripe_package_info.txt"
        fi
    else
        echo "No enterstripe-package found" > "$OUTPUT_DIR/enterstripe_package_info.txt"
    fi

    # ── 3. Repo URL ──────────────────────────────────────────────────────────
    if [ -d "$APP_PATH/.git" ]; then
        (cd "$APP_PATH" && git remote -v) > "$OUTPUT_DIR/repo_url.txt" 2>&1
    fi

    # ── 4. Nginx vhost ───────────────────────────────────────────────────────
    log "Capturing nginx vhost configs..."
    mkdir -p "$OUTPUT_DIR/nginx"
    local FOUND_VHOST=false

    for CONF_DIR in /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d; do
        if [ -d "$CONF_DIR" ]; then
            for conf in "$CONF_DIR"/*; do
                [ -f "$conf" ] || continue
                if grep -ql "$APP_PATH\|$APP_NAME" "$conf" 2>/dev/null; then
                    cp "$conf" "$OUTPUT_DIR/nginx/$(basename "$conf")"
                    FOUND_VHOST=true
                    log "  Found vhost: $conf"

                    # Extract SSL cert paths
                    grep -E 'ssl_certificate|ssl_certificate_key' "$conf" >> "$OUTPUT_DIR/ssl_info.txt" 2>/dev/null || true
                fi
            done
        fi
    done

    if [ "$FOUND_VHOST" = false ]; then
        warn "No nginx vhost found referencing $APP_NAME"
        # Dump all enabled sites for manual review
        ls -la /etc/nginx/sites-enabled/ > "$OUTPUT_DIR/nginx/all_enabled_sites.txt" 2>/dev/null || true
    fi

    # ── 5. SSL certificate info ──────────────────────────────────────────────
    if [ -f "$OUTPUT_DIR/ssl_info.txt" ]; then
        log "Capturing SSL certificate details..."
        while IFS= read -r line; do
            CERT_PATH=$(echo "$line" | awk '{print $2}' | tr -d ';')
            if [ -f "$CERT_PATH" ]; then
                echo "--- $CERT_PATH ---" >> "$OUTPUT_DIR/ssl_details.txt"
                openssl x509 -in "$CERT_PATH" -noout -subject -issuer -dates -serial \
                    >> "$OUTPUT_DIR/ssl_details.txt" 2>/dev/null || true
                echo "" >> "$OUTPUT_DIR/ssl_details.txt"
            fi
        done < "$OUTPUT_DIR/ssl_info.txt"
    fi

    # Check Let's Encrypt renewal config
    if [ -d /etc/letsencrypt/renewal ]; then
        for renewal in /etc/letsencrypt/renewal/*.conf; do
            [ -f "$renewal" ] || continue
            if grep -ql "$APP_NAME" "$renewal" 2>/dev/null; then
                cp "$renewal" "$OUTPUT_DIR/nginx/letsencrypt_$(basename "$renewal")"
            fi
        done
    fi

    # ── 6. Supervisord config ────────────────────────────────────────────────
    log "Capturing supervisord configs..."
    mkdir -p "$OUTPUT_DIR/supervisor"
    local FOUND_SUPERVISOR=false

    for CONF_DIR in /etc/supervisor/conf.d /etc/supervisord.d; do
        if [ -d "$CONF_DIR" ]; then
            for conf in "$CONF_DIR"/*; do
                [ -f "$conf" ] || continue
                if grep -ql "$APP_PATH\|$APP_NAME" "$conf" 2>/dev/null; then
                    cp "$conf" "$OUTPUT_DIR/supervisor/$(basename "$conf")"
                    FOUND_SUPERVISOR=true
                    log "  Found supervisor config: $conf"
                fi
            done
        fi
    done

    if [ "$FOUND_SUPERVISOR" = false ]; then
        warn "No supervisord config found referencing $APP_NAME"
        ls -la /etc/supervisor/conf.d/ > "$OUTPUT_DIR/supervisor/all_configs.txt" 2>/dev/null || true
    fi

    # ── 7. .env file ─────────────────────────────────────────────────────────
    if [ -f "$APP_PATH/.env" ]; then
        log "Capturing .env file..."
        cp "$APP_PATH/.env" "$OUTPUT_DIR/dot_env"
    else
        warn "No .env file found"
    fi

    # ── 8. Database dump ─────────────────────────────────────────────────────
    if [ -f "$APP_PATH/.env" ]; then
        log "Attempting database dump..."

        DB_CONNECTION=$(grep -E '^DB_CONNECTION=' "$APP_PATH/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        DB_HOST=$(grep -E '^DB_HOST=' "$APP_PATH/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        DB_PORT=$(grep -E '^DB_PORT=' "$APP_PATH/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        DB_DATABASE=$(grep -E '^DB_DATABASE=' "$APP_PATH/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        DB_USERNAME=$(grep -E '^DB_USERNAME=' "$APP_PATH/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$APP_PATH/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'")

        if [ -n "$DB_DATABASE" ]; then
            local DUMP_FILE="$OUTPUT_DIR/${DB_DATABASE}_dump.sql.gz"

            case "$DB_CONNECTION" in
                mysql|mariadb)
                    DB_PORT=${DB_PORT:-3306}
                    mysqldump \
                        -h "${DB_HOST:-127.0.0.1}" \
                        -P "$DB_PORT" \
                        -u "$DB_USERNAME" \
                        -p"$DB_PASSWORD" \
                        --single-transaction \
                        --routines \
                        --triggers \
                        --events \
                        "$DB_DATABASE" 2>"$OUTPUT_DIR/db_dump_errors.log" | gzip > "$DUMP_FILE"

                    if [ -s "$DUMP_FILE" ]; then
                        log "Database dumped: $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"
                    else
                        err "Database dump failed — check $OUTPUT_DIR/db_dump_errors.log"
                        rm -f "$DUMP_FILE"
                    fi
                    ;;
                pgsql)
                    DB_PORT=${DB_PORT:-5432}
                    PGPASSWORD="$DB_PASSWORD" pg_dump \
                        -h "${DB_HOST:-127.0.0.1}" \
                        -p "$DB_PORT" \
                        -U "$DB_USERNAME" \
                        "$DB_DATABASE" 2>"$OUTPUT_DIR/db_dump_errors.log" | gzip > "$DUMP_FILE"

                    if [ -s "$DUMP_FILE" ]; then
                        log "Database dumped: $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"
                    else
                        err "Database dump failed — check $OUTPUT_DIR/db_dump_errors.log"
                        rm -f "$DUMP_FILE"
                    fi
                    ;;
                *)
                    warn "Unsupported DB connection type: $DB_CONNECTION — skipping dump"
                    ;;
            esac
        else
            warn "No DB_DATABASE found in .env"
        fi
    fi

    # ── 9. App directory archive ─────────────────────────────────────────────
    log "Archiving app directory..."
    tar czf "$OUTPUT_DIR/${APP_NAME}_app.tar.gz" \
        -C "$(dirname "$APP_PATH")" \
        "$APP_NAME" 2>/dev/null

    if [ -s "$OUTPUT_DIR/${APP_NAME}_app.tar.gz" ]; then
        log "App archived: ${APP_NAME}_app.tar.gz ($(du -h "$OUTPUT_DIR/${APP_NAME}_app.tar.gz" | cut -f1))"
    else
        err "App archive failed"
        rm -f "$OUTPUT_DIR/${APP_NAME}_app.tar.gz"
    fi

    # ── 10. Composer lock & json ─────────────────────────────────────────────
    log "Capturing composer files..."
    [ -f "$APP_PATH/composer.json" ] && cp "$APP_PATH/composer.json" "$OUTPUT_DIR/"
    [ -f "$APP_PATH/composer.lock" ] && cp "$APP_PATH/composer.lock" "$OUTPUT_DIR/"

    # ── 11. Cron entries for this app ────────────────────────────────────────
    log "Capturing cron entries for this app..."
    {
        grep -r "$APP_PATH\|$APP_NAME" /etc/cron* /var/spool/cron 2>/dev/null || echo "No cron entries found"
        echo ""
        echo "=== Laravel schedule:list ==="
        cd "$APP_PATH" && php artisan schedule:list 2>/dev/null || echo "Could not run schedule:list"
    } > "$OUTPUT_DIR/cron_entries.txt"

    # ── 12. Queue & Horizon config ───────────────────────────────────────────
    [ -f "$APP_PATH/config/queue.php" ] && cp "$APP_PATH/config/queue.php" "$OUTPUT_DIR/" 2>/dev/null || true
    [ -f "$APP_PATH/config/horizon.php" ] && cp "$APP_PATH/config/horizon.php" "$OUTPUT_DIR/" 2>/dev/null || true

    # ── 13. Laravel version & route list ─────────────────────────────────────
    log "Capturing Laravel info..."
    {
        echo "=== Laravel Version ==="
        (cd "$APP_PATH" && php artisan --version 2>/dev/null) || echo "Could not determine"
        echo ""
        echo "=== Route Count ==="
        (cd "$APP_PATH" && php artisan route:list --compact 2>/dev/null | wc -l) || echo "N/A"
    } > "$OUTPUT_DIR/laravel_info.txt"

    # ── 14. Node / NPM assets ────────────────────────────────────────────────
    if [ -f "$APP_PATH/package.json" ]; then
        log "Capturing package.json..."
        cp "$APP_PATH/package.json" "$OUTPUT_DIR/"
        [ -f "$APP_PATH/package-lock.json" ] && cp "$APP_PATH/package-lock.json" "$OUTPUT_DIR/"
        [ -f "$APP_PATH/yarn.lock" ] && cp "$APP_PATH/yarn.lock" "$OUTPUT_DIR/"
        [ -f "$APP_PATH/vite.config.js" ] && cp "$APP_PATH/vite.config.js" "$OUTPUT_DIR/"
        [ -f "$APP_PATH/webpack.mix.js" ] && cp "$APP_PATH/webpack.mix.js" "$OUTPUT_DIR/"
    fi

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    log "Capture complete for $APP_NAME"
    log "Output: $OUTPUT_DIR"
    echo ""

    # Generate a summary manifest
    {
        echo "============================================="
        echo " DECOMM CAPTURE MANIFEST"
        echo " App:       $APP_NAME"
        echo " Path:      $APP_PATH"
        echo " Date:      $(date)"
        echo " Server:    $(hostname)"
        echo "============================================="
        echo ""
        echo "Files captured:"
        ls -la "$OUTPUT_DIR/"
        echo ""
        echo "Total size: $(du -sh "$OUTPUT_DIR" | cut -f1)"
    } > "$OUTPUT_DIR/MANIFEST.txt"

    cat "$OUTPUT_DIR/MANIFEST.txt"
}

# ─── Main ────────────────────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║         Laravel App Decommission Capture Script          ║"
echo "║         $(date)                    ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Capture server-wide info first
capture_server_info

# Process each app
for app_path in "$@"; do
    capture_app "$app_path"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " All captures complete!"
echo " Output directory: $BASE_OUTPUT"
echo ""
echo " Next steps:"
echo "   1. Review the captured data, especially .env files"
echo "   2. tar czf decomm_${TIMESTAMP}.tar.gz -C $BASE_OUTPUT ."
echo "   3. scp the archive to Server B"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
