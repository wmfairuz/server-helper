#!/bin/bash

# Server Performance Tuner for Laravel + Nginx + PHP-FPM + MySQL
# Audits current config, proposes optimizations, applies with backup

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BACKUP_DIR="/opt/config-backups/$(date +%Y%m%d-%H%M%S)"
CHANGES=()
DRY_RUN=false

# ─── Helpers ────────────────────────────────────────────────────────
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
bad()   { echo -e "${RED}[BAD]${NC} $1"; }
header(){ echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

confirm() {
    local msg="$1"
    echo -en "${YELLOW}$msg [y/N]: ${NC}"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

backup_file() {
    local src="$1"
    if [[ -f "$src" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp "$src" "$BACKUP_DIR/$(basename "$src")"
        info "Backed up: $src -> $BACKUP_DIR/$(basename "$src")"
    fi
}

add_change() {
    # Avoid duplicates
    for existing in "${CHANGES[@]+"${CHANGES[@]}"}"; do
        [[ "$existing" == "$1" ]] && return
    done
    CHANGES+=("$1")
}

# ─── Gather System Info ────────────────────────────────────────────
gather_info() {
    header "System Information"

    CPU_CORES=$(nproc)
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    TOTAL_MEM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_MEM_MB/1024}")
    AVAIL_MEM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    AVAIL_MEM_MB=$((AVAIL_MEM_KB / 1024))

    echo -e "  CPU Cores:        ${BOLD}$CPU_CORES${NC}"
    echo -e "  Total Memory:     ${BOLD}${TOTAL_MEM_GB} GB${NC} (${TOTAL_MEM_MB} MB)"
    echo -e "  Available Memory: ${BOLD}${AVAIL_MEM_MB} MB${NC}"
    echo -e "  OS:               $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo -e "  Kernel:           $(uname -r)"
    echo -e "  Uptime:           $(uptime -p)"
}

# ─── PHP-FPM ───────────────────────────────────────────────────────
check_phpfpm() {
    header "PHP-FPM"

    # Find the active PHP-FPM pool config
    PHP_VERSION=$(php -v 2>/dev/null | head -1 | grep -oP '\d+\.\d+' | head -1)
    FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

    if [[ ! -f "$FPM_CONF" ]]; then
        FPM_CONF=$(find /etc/php -name "www.conf" -path "*/fpm/*" 2>/dev/null | head -1)
    fi

    if [[ -z "$FPM_CONF" || ! -f "$FPM_CONF" ]]; then
        warn "PHP-FPM pool config not found"
        return
    fi

    echo -e "  Config: $FPM_CONF"
    echo -e "  PHP Version: $PHP_VERSION"

    PM_MODE=$(grep -E "^pm\s*=" "$FPM_CONF" | awk '{print $3}')
    PM_MAX=$(grep -E "^pm\.max_children" "$FPM_CONF" | awk '{print $3}')
    PM_START=$(grep -E "^pm\.start_servers" "$FPM_CONF" | awk '{print $3}')
    PM_MIN_SPARE=$(grep -E "^pm\.min_spare_servers" "$FPM_CONF" | awk '{print $3}')
    PM_MAX_SPARE=$(grep -E "^pm\.max_spare_servers" "$FPM_CONF" | awk '{print $3}')
    PM_MAX_REQ=$(grep -E "^pm\.max_requests" "$FPM_CONF" 2>/dev/null | awk '{print $3}' || echo "0")

    echo -e "  pm = $PM_MODE"
    echo -e "  pm.max_children = ${BOLD}$PM_MAX${NC}"
    echo -e "  pm.start_servers = $PM_START"
    echo -e "  pm.min_spare_servers = $PM_MIN_SPARE"
    echo -e "  pm.max_spare_servers = $PM_MAX_SPARE"
    echo -e "  pm.max_requests = ${PM_MAX_REQ:-not set}"

    # Calculate recommended values
    # Each PHP-FPM worker uses ~40-60MB for Laravel
    PHP_MEM_PER_WORKER=60
    # Reserve 2GB for OS/MySQL/Nginx, use the rest for PHP
    RESERVED_MB=2048
    AVAILABLE_FOR_PHP=$((TOTAL_MEM_MB - RESERVED_MB))
    REC_MAX_CHILDREN=$((AVAILABLE_FOR_PHP / PHP_MEM_PER_WORKER))
    # Cap at reasonable values
    [[ $REC_MAX_CHILDREN -gt 200 ]] && REC_MAX_CHILDREN=200
    [[ $REC_MAX_CHILDREN -lt 10 ]] && REC_MAX_CHILDREN=10
    REC_START=$((REC_MAX_CHILDREN / 4))
    REC_MIN_SPARE=$((REC_MAX_CHILDREN / 8))
    [[ $REC_MIN_SPARE -lt 2 ]] && REC_MIN_SPARE=2
    REC_MAX_SPARE=$((REC_MAX_CHILDREN / 3))
    REC_MAX_REQ=500

    echo ""
    if [[ "$PM_MAX" -lt "$REC_MAX_CHILDREN" ]]; then
        bad "pm.max_children ($PM_MAX) is too low for ${TOTAL_MEM_GB}GB RAM"
        echo -e "  ${GREEN}Recommended:${NC}"
        echo -e "    pm.max_children = $REC_MAX_CHILDREN"
        echo -e "    pm.start_servers = $REC_START"
        echo -e "    pm.min_spare_servers = $REC_MIN_SPARE"
        echo -e "    pm.max_spare_servers = $REC_MAX_SPARE"
        echo -e "    pm.max_requests = $REC_MAX_REQ"
        add_change "phpfpm"
    else
        ok "pm.max_children ($PM_MAX) looks good"
    fi

    if [[ -z "$PM_MAX_REQ" || "$PM_MAX_REQ" == "0" ]]; then
        warn "pm.max_requests not set (workers never recycle — potential memory leaks)"
        add_change "phpfpm"
    fi

    # Store for apply phase
    export FPM_CONF REC_MAX_CHILDREN REC_START REC_MIN_SPARE REC_MAX_SPARE REC_MAX_REQ
}

# ─── Nginx ─────────────────────────────────────────────────────────
check_nginx() {
    header "Nginx"

    NGINX_CONF="/etc/nginx/nginx.conf"
    if [[ ! -f "$NGINX_CONF" ]]; then
        warn "nginx.conf not found"
        return
    fi

    WORKER_PROC=$(grep -E "^worker_processes" "$NGINX_CONF" 2>/dev/null | awk '{print $2}' | tr -d ';' || echo "auto")
    WORKER_CONN=$(grep "worker_connections" "$NGINX_CONF" 2>/dev/null | awk '{print $2}' | tr -d ';' || echo "0")
    MULTI_ACCEPT=$(grep "multi_accept" "$NGINX_CONF" 2>/dev/null | grep -v "#" | awk '{print $2}' | tr -d ';' || echo "")
    GZIP_ON=$(grep -E "^\s*gzip\s+on" "$NGINX_CONF" 2>/dev/null || echo "")
    SERVER_TOKENS=$(grep -E "^\s*server_tokens" "$NGINX_CONF" 2>/dev/null | grep -v "#" || echo "")

    echo -e "  Config: $NGINX_CONF"
    echo -e "  worker_processes = $WORKER_PROC"
    echo -e "  worker_connections = ${BOLD}$WORKER_CONN${NC}"
    echo -e "  multi_accept = ${MULTI_ACCEPT:-not set}"
    echo -e "  gzip = $([ -n "$GZIP_ON" ] && echo 'on' || echo 'off')"
    echo -e "  server_tokens = $([ -n "$SERVER_TOKENS" ] && echo "$SERVER_TOKENS" || echo 'not set (default: on)')"

    REC_WORKER_CONN=2048
    NGINX_NEEDS_TUNING=false

    echo ""
    if [[ "$WORKER_CONN" -lt "$REC_WORKER_CONN" ]]; then
        bad "worker_connections ($WORKER_CONN) is low"
        echo -e "  ${GREEN}Recommended: worker_connections $REC_WORKER_CONN${NC}"
        NGINX_NEEDS_TUNING=true
    else
        ok "worker_connections ($WORKER_CONN) looks good"
    fi

    if [[ -z "$MULTI_ACCEPT" || "$MULTI_ACCEPT" != "on" ]]; then
        warn "multi_accept is not enabled"
        NGINX_NEEDS_TUNING=true
    fi

    if [[ -z "$SERVER_TOKENS" ]]; then
        warn "server_tokens not set (server version exposed)"
        NGINX_NEEDS_TUNING=true
    fi

    if $NGINX_NEEDS_TUNING; then
        add_change "nginx"
    fi

    export NGINX_CONF REC_WORKER_CONN
}

# ─── MySQL ─────────────────────────────────────────────────────────
check_mysql() {
    header "MySQL"

    # Check if MySQL/MariaDB is running locally
    MYSQL_LOCAL=false
    if pgrep -x "mysqld|mariadbd|mariadb" &>/dev/null; then
        MYSQL_LOCAL=true
    fi

    if ! command -v mysql &>/dev/null; then
        warn "MySQL client not found"
        return
    fi

    MAX_CONN=$(mysql -N -e "SHOW VARIABLES LIKE 'max_connections'" 2>/dev/null | awk '{print $2}' || echo "0")
    INNODB_POOL=$(mysql -N -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" 2>/dev/null | awk '{print $2}' || echo "0")
    INNODB_POOL_MB=$((INNODB_POOL / 1024 / 1024))
    SLOW_QUERY=$(mysql -N -e "SHOW VARIABLES LIKE 'slow_query_log'" 2>/dev/null | awk '{print $2}' || echo "N/A")

    echo -e "  max_connections = ${BOLD}$MAX_CONN${NC}"
    echo -e "  innodb_buffer_pool_size = ${BOLD}${INNODB_POOL_MB} MB${NC}"
    echo -e "  slow_query_log = ${SLOW_QUERY:-not set}"

    if ! $MYSQL_LOCAL; then
        info "MySQL is not running locally (remote DB server)"
        echo -e "  ${YELLOW}Tuning recommendations are shown but must be applied on the DB server${NC}"
    fi

    # Recommend ~25% of total RAM for InnoDB buffer pool
    REC_INNODB_MB=$((TOTAL_MEM_MB / 4))
    [[ $REC_INNODB_MB -gt 4096 ]] && REC_INNODB_MB=4096
    REC_MAX_CONN=200
    MYSQL_NEEDS_TUNING=false

    # Find MySQL config file (only relevant if local)
    MYSQL_CONF=""
    if $MYSQL_LOCAL; then
        for f in /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/my.cnf /etc/my.cnf; do
            if [[ -f "$f" ]]; then
                MYSQL_CONF="$f"
                break
            fi
        done
    fi

    echo ""
    if [[ "$INNODB_POOL_MB" -lt "$REC_INNODB_MB" ]]; then
        bad "innodb_buffer_pool_size (${INNODB_POOL_MB}MB) is low for ${TOTAL_MEM_GB}GB RAM"
        echo -e "  ${GREEN}Recommended: ${REC_INNODB_MB}MB${NC}"
        MYSQL_NEEDS_TUNING=true
    else
        ok "innodb_buffer_pool_size (${INNODB_POOL_MB}MB) looks good"
    fi

    if [[ "$MAX_CONN" -lt "$REC_MAX_CONN" ]]; then
        warn "max_connections ($MAX_CONN) might be low"
        echo -e "  ${GREEN}Recommended: $REC_MAX_CONN${NC}"
        MYSQL_NEEDS_TUNING=true
    else
        ok "max_connections ($MAX_CONN) looks good"
    fi

    # Only offer to apply changes if MySQL is local
    if $MYSQL_NEEDS_TUNING && $MYSQL_LOCAL; then
        add_change "mysql"
    elif $MYSQL_NEEDS_TUNING; then
        warn "Apply these changes on the remote DB server"
    fi

    export MYSQL_CONF MYSQL_LOCAL REC_INNODB_MB REC_MAX_CONN
}

# ─── PHP OPcache ───────────────────────────────────────────────────
check_opcache() {
    header "PHP OPcache"

    OPC_ENABLE=$(php -i 2>/dev/null | grep "opcache.enable =>" | head -1 | awk '{print $3}' || echo "")
    OPC_MEMORY=$(php -i 2>/dev/null | grep "opcache.memory_consumption =>" | head -1 | awk '{print $3}' || echo "0")
    OPC_MAX_FILES=$(php -i 2>/dev/null | grep "opcache.max_accelerated_files =>" | head -1 | awk '{print $3}' || echo "0")
    OPC_VALIDATE=$(php -i 2>/dev/null | grep "opcache.validate_timestamps =>" | head -1 | awk '{print $3}' || echo "")
    OPC_REVALIDATE=$(php -i 2>/dev/null | grep "opcache.revalidate_freq =>" | head -1 | awk '{print $3}' || echo "")
    OPC_INTERNED=$(php -i 2>/dev/null | grep "opcache.interned_strings_buffer =>" | head -1 | awk '{print $3}' || echo "0")

    echo -e "  opcache.enable = ${OPC_ENABLE:-not set}"
    echo -e "  opcache.memory_consumption = ${OPC_MEMORY:-not set} MB"
    echo -e "  opcache.max_accelerated_files = ${OPC_MAX_FILES:-not set}"
    echo -e "  opcache.validate_timestamps = ${OPC_VALIDATE:-not set}"
    echo -e "  opcache.revalidate_freq = ${OPC_REVALIDATE:-not set}"
    echo -e "  opcache.interned_strings_buffer = ${OPC_INTERNED:-not set} MB"

    OPC_CONF=""
    PHP_VERSION=$(php -v 2>/dev/null | head -1 | grep -oP '\d+\.\d+' | head -1)
    for f in "/etc/php/${PHP_VERSION}/fpm/conf.d/10-opcache.ini" \
             "/etc/php/${PHP_VERSION}/mods-available/opcache.ini"; do
        if [[ -f "$f" ]]; then
            OPC_CONF="$f"
            break
        fi
    done

    echo ""
    if [[ "$OPC_ENABLE" != "On" ]]; then
        bad "OPcache is disabled!"
        add_change "opcache"
    elif [[ "${OPC_MEMORY:-0}" -lt 256 ]]; then
        warn "OPcache memory (${OPC_MEMORY}MB) could be higher for production"
        echo -e "  ${GREEN}Recommended: 256MB${NC}"
        add_change "opcache"
    else
        ok "OPcache config looks good"
    fi

    export OPC_CONF
}

# ─── File Limits ───────────────────────────────────────────────────
check_limits() {
    header "System Limits"

    NOFILE_SOFT=$(ulimit -Sn)
    NOFILE_HARD=$(ulimit -Hn)

    echo -e "  Open files (soft): ${BOLD}$NOFILE_SOFT${NC}"
    echo -e "  Open files (hard): ${BOLD}$NOFILE_HARD${NC}"

    echo ""
    if [[ "$NOFILE_SOFT" -lt 65535 ]]; then
        bad "Open file limit ($NOFILE_SOFT) is too low"
        echo -e "  ${GREEN}Recommended: 65535${NC}"
        add_change "limits"
    else
        ok "Open file limits look good"
    fi
}

# ─── Laravel Caches ────────────────────────────────────────────────
check_laravel() {
    header "Laravel Optimization"

    # Try to find Laravel root
    LARAVEL_ROOT=""
    for d in /opt/www/app /var/www/html /var/www/app /home/*/app; do
        if [[ -f "$d/artisan" ]]; then
            LARAVEL_ROOT="$d"
            break
        fi
    done

    if [[ -z "$LARAVEL_ROOT" ]]; then
        warn "Laravel root not found (checked /opt/www/app, /var/www/html, /var/www/app)"
        echo -en "  ${YELLOW}Enter Laravel root path: ${NC}"
        read -r LARAVEL_ROOT
        if [[ ! -f "$LARAVEL_ROOT/artisan" ]]; then
            warn "Not a valid Laravel root"
            return
        fi
    fi

    echo -e "  Laravel root: $LARAVEL_ROOT"

    CONFIG_CACHED=false
    ROUTE_CACHED=false
    VIEW_CACHED=false
    EVENT_CACHED=false

    [[ -f "$LARAVEL_ROOT/bootstrap/cache/config.php" ]] && CONFIG_CACHED=true || true
    [[ -f "$LARAVEL_ROOT/bootstrap/cache/routes-v7.php" ]] && ROUTE_CACHED=true || true
    VIEW_COUNT=$(find "$LARAVEL_ROOT/storage/framework/views" -name "*.php" 2>/dev/null | wc -l || echo "0")
    [[ "$VIEW_COUNT" -gt 0 ]] && VIEW_CACHED=true || true
    [[ -f "$LARAVEL_ROOT/bootstrap/cache/events.php" ]] && EVENT_CACHED=true || true

    echo -e "  config:cache  = $($CONFIG_CACHED && echo -e "${GREEN}cached${NC}" || echo -e "${RED}not cached${NC}")"
    echo -e "  route:cache   = $($ROUTE_CACHED && echo -e "${GREEN}cached${NC}" || echo -e "${RED}not cached${NC}")"
    echo -e "  view:cache    = $($VIEW_CACHED && echo -e "${GREEN}cached${NC}" || echo -e "${RED}not cached${NC}")"
    echo -e "  event:cache   = $($EVENT_CACHED && echo -e "${GREEN}cached${NC}" || echo -e "${RED}not cached${NC}")"

    # Check .env for drivers
    if [[ -f "$LARAVEL_ROOT/.env" ]]; then
        SESSION_DRV=$(grep "^SESSION_DRIVER=" "$LARAVEL_ROOT/.env" | cut -d= -f2)
        CACHE_DRV=$(grep -E "^CACHE_(STORE|DRIVER)=" "$LARAVEL_ROOT/.env" | head -1 | cut -d= -f2 || echo "")
        QUEUE_DRV=$(grep "^QUEUE_CONNECTION=" "$LARAVEL_ROOT/.env" | cut -d= -f2)
        echo -e "  SESSION_DRIVER = ${BOLD}${SESSION_DRV:-not set}${NC}"
        echo -e "  CACHE_STORE = ${BOLD}${CACHE_DRV:-not set}${NC}"
        echo -e "  QUEUE_CONNECTION = ${BOLD}${QUEUE_DRV:-not set}${NC}"

        if [[ "$SESSION_DRV" == "database" ]]; then
            warn "SESSION_DRIVER=database adds DB load per request. Consider 'redis' or 'file'"
        fi
        if [[ "$QUEUE_DRV" == "database" || "$QUEUE_DRV" == "sync" ]]; then
            warn "QUEUE_CONNECTION=$QUEUE_DRV is not ideal for production. Consider 'redis'"
        fi
    fi

    echo ""
    if ! $CONFIG_CACHED || ! $ROUTE_CACHED || ! $VIEW_CACHED || ! $EVENT_CACHED; then
        warn "Some Laravel caches are not built"
        add_change "laravel"
    else
        ok "All Laravel caches are built"
    fi

    export LARAVEL_ROOT
}

# ═══════════════════════════════════════════════════════════════════
# APPLY CHANGES
# ═══════════════════════════════════════════════════════════════════

apply_phpfpm() {
    backup_file "$FPM_CONF"

    sed -i "s/^pm\.max_children\s*=.*/pm.max_children = $REC_MAX_CHILDREN/" "$FPM_CONF"
    sed -i "s/^pm\.start_servers\s*=.*/pm.start_servers = $REC_START/" "$FPM_CONF"
    sed -i "s/^pm\.min_spare_servers\s*=.*/pm.min_spare_servers = $REC_MIN_SPARE/" "$FPM_CONF"
    sed -i "s/^pm\.max_spare_servers\s*=.*/pm.max_spare_servers = $REC_MAX_SPARE/" "$FPM_CONF"

    if grep -q "^pm\.max_requests" "$FPM_CONF"; then
        sed -i "s/^pm\.max_requests\s*=.*/pm.max_requests = $REC_MAX_REQ/" "$FPM_CONF"
    elif grep -q "^;pm\.max_requests" "$FPM_CONF"; then
        sed -i "s/^;pm\.max_requests\s*=.*/pm.max_requests = $REC_MAX_REQ/" "$FPM_CONF"
    else
        echo "pm.max_requests = $REC_MAX_REQ" >> "$FPM_CONF"
    fi

    ok "PHP-FPM config updated"
    info "Restarting PHP-FPM..."
    if systemctl restart "php${PHP_VERSION}-fpm"; then
        ok "PHP-FPM restarted"
    else
        bad "Failed to restart PHP-FPM. Check: systemctl status php${PHP_VERSION}-fpm"
    fi
}

apply_nginx() {
    backup_file "$NGINX_CONF"

    # Update worker_connections
    sed -i "s/worker_connections\s\+[0-9]\+/worker_connections $REC_WORKER_CONN/" "$NGINX_CONF"

    # Enable multi_accept
    if grep -q "#.*multi_accept" "$NGINX_CONF"; then
        sed -i 's/#\s*multi_accept.*/multi_accept on;/' "$NGINX_CONF"
    elif ! grep -q "multi_accept on" "$NGINX_CONF"; then
        sed -i '/worker_connections/a\\tmulti_accept on;' "$NGINX_CONF"
    fi

    # Add server_tokens off if not present
    if ! grep -qE "^\s*server_tokens\s+off" "$NGINX_CONF"; then
        sed -i '/sendfile on;/a\\tserver_tokens off;' "$NGINX_CONF"
    fi

    ok "Nginx config updated"
    info "Testing nginx config..."
    if nginx -t 2>&1; then
        info "Reloading nginx..."
        systemctl reload nginx
        ok "Nginx reloaded"
    else
        bad "Nginx config test failed! Restoring backup..."
        cp "$BACKUP_DIR/nginx.conf" "$NGINX_CONF"
        bad "Backup restored. Please fix manually."
    fi
}

apply_mysql() {
    if [[ -z "$MYSQL_CONF" ]]; then
        warn "MySQL config file not found. Please set manually:"
        echo "  innodb_buffer_pool_size = ${REC_INNODB_MB}M"
        echo "  max_connections = $REC_MAX_CONN"
        return
    fi

    backup_file "$MYSQL_CONF"

    # Update or add innodb_buffer_pool_size
    if grep -q "^innodb_buffer_pool_size" "$MYSQL_CONF"; then
        sed -i "s/^innodb_buffer_pool_size\s*=.*/innodb_buffer_pool_size = ${REC_INNODB_MB}M/" "$MYSQL_CONF"
    else
        sed -i "/^\[mysqld\]/a innodb_buffer_pool_size = ${REC_INNODB_MB}M" "$MYSQL_CONF"
    fi

    # Update or add max_connections
    if grep -q "^max_connections" "$MYSQL_CONF"; then
        sed -i "s/^max_connections\s*=.*/max_connections = $REC_MAX_CONN/" "$MYSQL_CONF"
    else
        sed -i "/^\[mysqld\]/a max_connections = $REC_MAX_CONN" "$MYSQL_CONF"
    fi

    ok "MySQL config updated"
    warn "MySQL requires restart to apply changes"

    # Detect the correct service name
    MYSQL_SVC=""
    for svc in mysql mariadb mysqld; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null && systemctl list-unit-files "${svc}.service" | grep -q "$svc"; then
            MYSQL_SVC="$svc"
            break
        fi
    done

    if [[ -z "$MYSQL_SVC" ]]; then
        warn "Could not detect MySQL service name. Restart manually."
        return
    fi

    if confirm "Restart $MYSQL_SVC now?"; then
        if systemctl restart "$MYSQL_SVC"; then
            ok "$MYSQL_SVC restarted"
        else
            bad "Failed to restart $MYSQL_SVC. Check: systemctl status $MYSQL_SVC"
        fi
    else
        warn "Remember to restart later: systemctl restart $MYSQL_SVC"
    fi
}

apply_limits() {
    LIMITS_CONF="/etc/security/limits.conf"
    backup_file "$LIMITS_CONF"

    # Add limits if not already present
    if ! grep -q "www-data.*nofile.*65535" "$LIMITS_CONF"; then
        echo "" >> "$LIMITS_CONF"
        echo "# Added by server-tuner" >> "$LIMITS_CONF"
        echo "www-data soft nofile 65535" >> "$LIMITS_CONF"
        echo "www-data hard nofile 65535" >> "$LIMITS_CONF"
        echo "root soft nofile 65535" >> "$LIMITS_CONF"
        echo "root hard nofile 65535" >> "$LIMITS_CONF"
        ok "File limits updated in $LIMITS_CONF"
    fi

    # Create systemd override for PHP-FPM
    PHP_VERSION=$(php -v 2>/dev/null | head -1 | grep -oP '\d+\.\d+' | head -1)
    FPM_OVERRIDE_DIR="/etc/systemd/system/php${PHP_VERSION}-fpm.service.d"
    mkdir -p "$FPM_OVERRIDE_DIR"

    if [[ ! -f "$FPM_OVERRIDE_DIR/override.conf" ]]; then
        cat > "$FPM_OVERRIDE_DIR/override.conf" <<EOF
[Service]
LimitNOFILE=65535
EOF
        ok "PHP-FPM systemd override created"
        systemctl daemon-reload
        info "Restarting PHP-FPM to apply new limits..."
        systemctl restart "php${PHP_VERSION}-fpm"
        ok "PHP-FPM restarted with new file limits"
    else
        ok "PHP-FPM systemd override already exists"
    fi
}

apply_opcache() {
    if [[ -z "$OPC_CONF" ]]; then
        warn "OPcache config not found. Set these values in your PHP ini:"
        echo "  opcache.memory_consumption=256"
        echo "  opcache.interned_strings_buffer=32"
        echo "  opcache.max_accelerated_files=20000"
        echo "  opcache.validate_timestamps=0"
        return
    fi

    backup_file "$OPC_CONF"

    # Helper to set or add an opcache directive
    set_opcache() {
        local key="$1" val="$2"
        if grep -q "^${key}" "$OPC_CONF"; then
            sed -i "s/^${key}\s*=.*/${key}=${val}/" "$OPC_CONF"
        elif grep -q "^;${key}" "$OPC_CONF"; then
            sed -i "s/^;${key}\s*=.*/${key}=${val}/" "$OPC_CONF"
        else
            echo "${key}=${val}" >> "$OPC_CONF"
        fi
    }

    set_opcache "opcache.memory_consumption" "256"
    set_opcache "opcache.interned_strings_buffer" "32"
    set_opcache "opcache.max_accelerated_files" "20000"
    set_opcache "opcache.validate_timestamps" "0"

    ok "OPcache config updated"
    warn "opcache.validate_timestamps=0 means you must restart PHP-FPM after code deploys"
}

apply_laravel() {
    if [[ -z "$LARAVEL_ROOT" || ! -f "$LARAVEL_ROOT/artisan" ]]; then
        warn "Laravel root not set"
        return
    fi

    cd "$LARAVEL_ROOT"
    info "Running Laravel cache commands..."
    php artisan config:cache 2>&1 | sed 's/^/  /'
    php artisan route:cache 2>&1 | sed 's/^/  /'
    php artisan view:cache 2>&1 | sed 's/^/  /'
    php artisan event:cache 2>&1 | sed 's/^/  /'
    ok "Laravel caches built"
}

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════

main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║       SERVER PERFORMANCE TUNER               ║"
    echo "║  Laravel + Nginx + PHP-FPM + MySQL            ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Check root
    if [[ $EUID -ne 0 ]]; then
        bad "This script must be run as root (for config changes)"
        echo "  Usage: sudo $0"
        exit 1
    fi

    # ── Audit Phase ──
    gather_info
    check_phpfpm
    check_nginx
    check_mysql
    check_opcache
    check_limits
    check_laravel

    # ── Summary ──
    header "Summary"

    if [[ ${#CHANGES[@]} -eq 0 ]]; then
        ok "Everything looks well-tuned! No changes needed."
        exit 0
    fi

    echo -e "  ${YELLOW}${#CHANGES[@]} area(s) need attention:${NC}"
    for c in "${CHANGES[@]}"; do
        case $c in
            phpfpm)  echo -e "    - PHP-FPM pool settings" ;;
            nginx)   echo -e "    - Nginx worker settings" ;;
            mysql)   echo -e "    - MySQL buffer/connections" ;;
            opcache) echo -e "    - PHP OPcache settings" ;;
            limits)  echo -e "    - System file limits" ;;
            laravel) echo -e "    - Laravel cache commands" ;;
        esac
    done

    # ── Apply Phase (per-item) ──
    header "Apply Changes"
    echo -e "  ${CYAN}I'll ask for each change individually. Configs will be backed up to:${NC}"
    echo -e "  $BACKUP_DIR"
    echo ""
    mkdir -p "$BACKUP_DIR"

    APPLIED=0
    SKIPPED=0

    for c in "${CHANGES[@]}"; do
        case $c in
            phpfpm)
                if confirm "Apply PHP-FPM tuning? (max_children $PM_MAX -> $REC_MAX_CHILDREN, etc.)"; then
                    apply_phpfpm
                    ((APPLIED++))
                else
                    info "Skipped PHP-FPM"
                    ((SKIPPED++))
                fi
                ;;
            nginx)
                if confirm "Apply Nginx tuning? (worker_connections -> $REC_WORKER_CONN, multi_accept on, server_tokens off)"; then
                    apply_nginx
                    ((APPLIED++))
                else
                    info "Skipped Nginx"
                    ((SKIPPED++))
                fi
                ;;
            mysql)
                if confirm "Apply MySQL tuning? (innodb_buffer_pool -> ${REC_INNODB_MB}MB, max_connections -> $REC_MAX_CONN)"; then
                    apply_mysql
                    ((APPLIED++))
                else
                    info "Skipped MySQL"
                    ((SKIPPED++))
                fi
                ;;
            opcache)
                if confirm "Apply OPcache tuning? (memory 256MB, max_files 20000, validate_timestamps off)"; then
                    apply_opcache
                    ((APPLIED++))
                else
                    info "Skipped OPcache"
                    ((SKIPPED++))
                fi
                ;;
            limits)
                if confirm "Increase open file limits? (nofile -> 65535)"; then
                    apply_limits
                    ((APPLIED++))
                else
                    info "Skipped file limits"
                    ((SKIPPED++))
                fi
                ;;
            laravel)
                if confirm "Run Laravel cache commands? (config:cache, route:cache, view:cache, event:cache)"; then
                    apply_laravel
                    ((APPLIED++))
                else
                    info "Skipped Laravel caches"
                    ((SKIPPED++))
                fi
                ;;
        esac
        echo ""
    done

    echo -e "  ${GREEN}Applied: $APPLIED${NC} | ${YELLOW}Skipped: $SKIPPED${NC}"

    header "Done"
    ok "All changes applied. Backups saved to: $BACKUP_DIR"
    echo ""
    echo -e "  ${YELLOW}To restore:${NC}"
    echo -e "    cp $BACKUP_DIR/<filename> <original_path>"
    echo -e "    systemctl restart php${PHP_VERSION}-fpm nginx mysql"
}

main "$@"
