#!/bin/bash
# server-snapshot.sh
# Dumps current tuning values for comparison between servers.
#
# Usage:
#   ./server-snapshot.sh              # plain key=value output
#   ./server-snapshot.sh > server1.txt
#   diff server1.txt server2.txt

set -uo pipefail

# ─── Helpers ────────────────────────────────────────────────────────
val()  { printf "%-45s = %s\n" "$1" "$2"; }
section() { echo ""; echo "## $1"; }

php_ini_get() {
    local key="$1" ini="${2:-}"
    if [[ -n "$ini" && -f "$ini" ]]; then
        grep -E "^\s*${key}\s*=" "$ini" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ' || echo "not set"
    else
        php -i 2>/dev/null | grep "^${key}" | head -1 | awk '{print $3}' || echo "not set"
    fi
}

# ─── System ─────────────────────────────────────────────────────────
section "SYSTEM"
val "hostname"                "$(hostname -f 2>/dev/null || hostname)"
val "os"                      "$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
val "kernel"                  "$(uname -r)"
val "cpu_cores"               "$(nproc)"
val "ram_total_mb"            "$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
val "ram_available_mb"        "$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"
val "swap_total_mb"           "$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
val "uptime"                  "$(uptime -p)"
val "load_avg"                "$(cut -d' ' -f1-3 /proc/loadavg)"

# ─── PHP-FPM ────────────────────────────────────────────────────────
section "PHP-FPM"
PHP_VERSION=$(php -v 2>/dev/null | head -1 | grep -oP '\d+\.\d+' | head -1 || echo "")
FPM_CONF=""
if [[ -n "$PHP_VERSION" ]]; then
    FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    [[ ! -f "$FPM_CONF" ]] && FPM_CONF=$(find /etc/php -name "www.conf" -path "*/fpm/*" 2>/dev/null | head -1 || echo "")
fi

val "php_version"             "${PHP_VERSION:-not found}"
val "fpm_config"              "${FPM_CONF:-not found}"

if [[ -n "$FPM_CONF" && -f "$FPM_CONF" ]]; then
    fpm() { grep -E "^${1}" "$FPM_CONF" 2>/dev/null | awk '{print $3}' || echo "not set"; }
    val "fpm.pm"                  "$(fpm 'pm\s*=')"
    val "fpm.pm.max_children"     "$(fpm 'pm\.max_children')"
    val "fpm.pm.start_servers"    "$(fpm 'pm\.start_servers')"
    val "fpm.pm.min_spare_servers" "$(fpm 'pm\.min_spare_servers')"
    val "fpm.pm.max_spare_servers" "$(fpm 'pm\.max_spare_servers')"
    val "fpm.pm.max_requests"     "$(fpm 'pm\.max_requests')"
else
    val "fpm.pm" "config not found"
fi

# ─── PHP INI ────────────────────────────────────────────────────────
section "PHP INI"
PHP_INI=""
[[ -n "$PHP_VERSION" ]] && PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
[[ ! -f "${PHP_INI:-}" ]] && PHP_INI=""

val "php_ini"                 "${PHP_INI:-not found}"
val "upload_max_filesize"     "$(php_ini_get upload_max_filesize "$PHP_INI")"
val "post_max_size"           "$(php_ini_get post_max_size "$PHP_INI")"
val "memory_limit"            "$(php_ini_get memory_limit "$PHP_INI")"
val "max_execution_time"      "$(php_ini_get max_execution_time "$PHP_INI")"
val "max_input_time"          "$(php_ini_get max_input_time "$PHP_INI")"

# ─── OPcache ────────────────────────────────────────────────────────
section "OPCACHE"
val "opcache.enable"                  "$(php -i 2>/dev/null | grep '^opcache.enable =>' | head -1 | awk '{print $3}' || echo 'not set')"
val "opcache.memory_consumption"      "$(php -i 2>/dev/null | grep '^opcache.memory_consumption =>' | head -1 | awk '{print $3}' || echo 'not set')"
val "opcache.max_accelerated_files"   "$(php -i 2>/dev/null | grep '^opcache.max_accelerated_files =>' | head -1 | awk '{print $3}' || echo 'not set')"
val "opcache.validate_timestamps"     "$(php -i 2>/dev/null | grep '^opcache.validate_timestamps =>' | head -1 | awk '{print $3}' || echo 'not set')"
val "opcache.revalidate_freq"         "$(php -i 2>/dev/null | grep '^opcache.revalidate_freq =>' | head -1 | awk '{print $3}' || echo 'not set')"
val "opcache.interned_strings_buffer" "$(php -i 2>/dev/null | grep '^opcache.interned_strings_buffer =>' | head -1 | awk '{print $3}' || echo 'not set')"

# ─── Nginx ──────────────────────────────────────────────────────────
section "NGINX"
NGINX_CONF="/etc/nginx/nginx.conf"
val "nginx_version"           "$(nginx -v 2>&1 | grep -oP '[\d.]+'  | head -1 || echo 'not found')"
val "nginx_config"            "$NGINX_CONF"

if [[ -f "$NGINX_CONF" ]]; then
    nginx_get() { grep -E "^\s*${1}" "$NGINX_CONF" 2>/dev/null | grep -v "#" | head -1 | awk '{print $2}' | tr -d ';' || echo "not set"; }
    val "worker_processes"        "$(nginx_get 'worker_processes')"
    val "worker_connections"      "$(grep 'worker_connections' "$NGINX_CONF" 2>/dev/null | grep -v '#' | head -1 | awk '{print $2}' | tr -d ';' || echo 'not set')"
    val "multi_accept"            "$(grep 'multi_accept' "$NGINX_CONF" 2>/dev/null | grep -v '#' | head -1 | awk '{print $2}' | tr -d ';' || echo 'not set')"
    val "keepalive_timeout"       "$(nginx_get 'keepalive_timeout')"
    val "gzip"                    "$(grep -E '^\s*gzip\s+' "$NGINX_CONF" 2>/dev/null | grep -v '#' | head -1 | awk '{print $2}' | tr -d ';' || echo 'not set')"
    val "server_tokens"           "$(nginx_get 'server_tokens')"
    val "client_max_body_size"    "$(grep -h 'client_max_body_size' /etc/nginx/nginx.conf /etc/nginx/sites-enabled/* 2>/dev/null | grep -v '#' | head -1 | awk '{print $2}' | tr -d ';' || echo 'not set')"
else
    val "nginx" "config not found"
fi

# ─── MySQL ──────────────────────────────────────────────────────────
section "MYSQL"
if command -v mysql &>/dev/null; then
    mysql_var() { mysql -N -e "SHOW VARIABLES LIKE '${1}'" 2>/dev/null | awk '{print $2}' || echo "n/a"; }
    val "mysql_version"           "$(mysql --version 2>/dev/null | awk '{print $3}' || echo 'not found')"
    val "max_connections"         "$(mysql_var max_connections)"
    POOL=$(mysql_var innodb_buffer_pool_size)
    if [[ "$POOL" =~ ^[0-9]+$ ]]; then
        val "innodb_buffer_pool_size" "${POOL} ($(( POOL / 1024 / 1024 ))MB)"
    else
        val "innodb_buffer_pool_size" "${POOL}"
    fi
    val "innodb_log_file_size"    "$(mysql_var innodb_log_file_size)"
    val "query_cache_size"        "$(mysql_var query_cache_size)"
    val "slow_query_log"          "$(mysql_var slow_query_log)"
    val "long_query_time"         "$(mysql_var long_query_time)"
else
    val "mysql" "client not found"
fi

# ─── System Limits ──────────────────────────────────────────────────
section "SYSTEM LIMITS"
val "open_files_soft"         "$(ulimit -Sn)"
val "open_files_hard"         "$(ulimit -Hn)"
val "limits_conf_www-data"    "$(grep 'www-data.*nofile' /etc/security/limits.conf 2>/dev/null | tr '\n' ' ' || echo 'not set')"

# ─── Redis ──────────────────────────────────────────────────────────
section "REDIS"
if command -v redis-cli &>/dev/null; then
    r() { redis-cli config get "$1" 2>/dev/null | tail -1 || echo "n/a"; }
    val "redis_version"       "$(redis-cli --version 2>/dev/null | awk '{print $2}' || echo 'not found')"
    val "redis.maxmemory"     "$(r maxmemory)"
    val "redis.maxmemory_policy" "$(r maxmemory-policy)"
    val "redis.bind"          "$(r bind)"
else
    val "redis" "not installed"
fi

echo ""
