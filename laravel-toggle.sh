#!/bin/bash

# Laravel Instance Toggle Script
# Toggles all Laravel instances up/down with correct PHP version detection

LARAVEL_ROOT="/opt/www"
NGINX_CONF_DIR="/etc/nginx/sites-enabled"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get PHP version from nginx config for a given document root
get_php_version() {
    local doc_root="$1"
    local php_version=""

    # Search nginx configs for the document root and extract PHP version
    for conf in "$NGINX_CONF_DIR"/*; do
        if [[ -f "$conf" ]] && grep -q "$doc_root" "$conf" 2>/dev/null; then
            # Extract PHP version from socket path (e.g., php8.2-fpm.sock or php-fpm82.sock)
            php_version=$(grep -oP 'php\K[0-9]+\.[0-9]+' "$conf" | head -1)
            if [[ -n "$php_version" ]]; then
                break
            fi
        fi
    done

    # Fallback: try to find from unix socket pattern
    if [[ -z "$php_version" ]]; then
        for conf in "$NGINX_CONF_DIR"/*; do
            if [[ -f "$conf" ]] && grep -q "$doc_root" "$conf" 2>/dev/null; then
                php_version=$(grep -oP 'php-fpm\K[0-9]+' "$conf" | head -1)
                if [[ -n "$php_version" ]]; then
                    # Convert 82 to 8.2
                    php_version="${php_version:0:1}.${php_version:1}"
                    break
                fi
            fi
        done
    fi

    echo "$php_version"
}

# Get PHP binary path
get_php_binary() {
    local version="$1"

    if [[ -z "$version" ]]; then
        # Default to system php
        echo "php"
        return
    fi

    # Try common paths
    local paths=(
        "/usr/bin/php$version"
        "/usr/bin/php${version//./}"
        "/usr/local/bin/php$version"
    )

    for path in "${paths[@]}"; do
        if [[ -x "$path" ]]; then
            echo "$path"
            return
        fi
    done

    # Fallback to system php
    echo "php"
}

# Check if instance is in maintenance mode
is_down() {
    local path="$1"
    [[ -f "$path/storage/framework/down" ]]
}

# Toggle a single Laravel instance
toggle_instance() {
    local path="$1"
    local action="$2"
    local php_version
    local php_bin

    # Get PHP version from nginx config
    php_version=$(get_php_version "$path")
    php_bin=$(get_php_binary "$php_version")

    local instance_name=$(basename "$path")

    if [[ "$action" == "auto" ]]; then
        if is_down "$path"; then
            action="up"
        else
            action="down"
        fi
    fi

    echo -n "[$instance_name] Using $php_bin: php artisan $action... "

    cd "$path" || return 1

    if $php_bin artisan "$action" 2>/dev/null; then
        if [[ "$action" == "down" ]]; then
            echo -e "${YELLOW}DOWN${NC}"
        else
            echo -e "${GREEN}UP${NC}"
        fi
    else
        echo -e "${RED}FAILED${NC}"
        return 1
    fi
}

# Find all Laravel instances
find_laravel_instances() {
    local instances=()

    for dir in "$LARAVEL_ROOT"/*/; do
        if [[ -f "${dir}artisan" ]]; then
            instances+=("${dir%/}")
        fi
    done

    echo "${instances[@]}"
}

# Main
main() {
    local action="${1:-auto}"

    if [[ "$action" != "up" && "$action" != "down" && "$action" != "auto" ]]; then
        echo "Usage: $0 [up|down|auto]"
        echo "  up   - Bring all instances up"
        echo "  down - Put all instances in maintenance mode"
        echo "  auto - Toggle each instance (default)"
        exit 1
    fi

    echo "=== Laravel Instance Toggle ==="
    echo "Root: $LARAVEL_ROOT"
    echo "Action: $action"
    echo ""

    local instances
    read -ra instances <<< "$(find_laravel_instances)"

    if [[ ${#instances[@]} -eq 0 ]]; then
        echo -e "${RED}No Laravel instances found in $LARAVEL_ROOT${NC}"
        exit 1
    fi

    echo "Found ${#instances[@]} Laravel instance(s)"
    echo ""

    local success=0
    local failed=0

    for instance in "${instances[@]}"; do
        if toggle_instance "$instance" "$action"; then
            ((success++))
        else
            ((failed++))
        fi
    done

    echo ""
    echo "=== Summary ==="
    echo -e "Success: ${GREEN}$success${NC}"
    echo -e "Failed: ${RED}$failed${NC}"
}

main "$@"
