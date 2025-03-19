#!/bin/bash

# Ubuntu Server Configuration Retriever
# This script retrieves actual configuration values from an Ubuntu server

# Color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================"
echo "      UBUNTU SERVER CONFIGURATION RETRIEVER"
echo "======================================================${NC}"

# --- HARDWARE INFORMATION ---
echo -e "\n${GREEN}Hardware Information:${NC}"

# Get CPU information
CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d ":" -f2 | sed 's/^ *//')
echo -e "CPU Model: ${YELLOW}$CPU_MODEL${NC}"
echo -e "CPU Cores: ${YELLOW}$CPU_CORES${NC}"

# Get memory information
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
TOTAL_MEM_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_MEM_MB/1024}")
echo -e "Total Memory: ${YELLOW}${TOTAL_MEM_GB} GB${NC} (${TOTAL_MEM_MB} MB)"

# --- APACHE INFORMATION ---
echo -e "\n${GREEN}Apache Information:${NC}"
if command -v apache2 &> /dev/null; then
    APACHE_VERSION=$(apache2 -v | grep version | awk -F'/' '{print $2}' | awk '{print $1}')
    echo -e "Apache Version: ${YELLOW}$APACHE_VERSION${NC}"
    
    # Check MPM mode
    if [ -f /etc/apache2/mods-enabled/mpm_event.conf ]; then
        MPM_MODE="event"
        MPM_FILE="/etc/apache2/mods-enabled/mpm_event.conf"
    elif [ -f /etc/apache2/mods-enabled/mpm_worker.conf ]; then
        MPM_MODE="worker"
        MPM_FILE="/etc/apache2/mods-enabled/mpm_worker.conf"
    elif [ -f /etc/apache2/mods-enabled/mpm_prefork.conf ]; then
        MPM_MODE="prefork"
        MPM_FILE="/etc/apache2/mods-enabled/mpm_prefork.conf"
    else
        MPM_MODE="unknown"
    fi
    echo -e "MPM Mode: ${YELLOW}$MPM_MODE${NC}"
    
    # Get MPM settings
    if [ "$MPM_MODE" != "unknown" ] && [ -f "$MPM_FILE" ]; then
        echo -e "\n${BLUE}Apache MPM Settings:${NC}"
        grep -E "StartServers|MinSpareThreads|MinSpareServers|MaxSpareThreads|MaxSpareServers|ThreadLimit|ThreadsPerChild|MaxRequestWorkers|MaxClients|MaxConnectionsPerChild|MaxRequestsPerChild" "$MPM_FILE" | sed 's/^[ \t]*//'
    fi
    
    # Get Apache global settings
    if [ -f /etc/apache2/apache2.conf ]; then
        echo -e "\n${BLUE}Apache Global Settings:${NC}"
        grep -E "^[ \t]*Timeout|^[ \t]*KeepAlive|^[ \t]*MaxKeepAliveRequests|^[ \t]*KeepAliveTimeout" /etc/apache2/apache2.conf | sed 's/^[ \t]*//'
    fi
else
    echo -e "${RED}Apache not installed or not detected${NC}"
fi

# --- PHP-FPM INFORMATION ---
echo -e "\n${GREEN}PHP-FPM Information:${NC}"
if command -v php &> /dev/null; then
    PHP_VERSION=$(php -v | head -n 1 | cut -d " " -f 2)
    PHP_MAIN_VER=$(echo $PHP_VERSION | cut -d "." -f 1,2)
    echo -e "PHP Version: ${YELLOW}$PHP_VERSION${NC}"
    
    # Check if PHP-FPM is installed
    if [ -d "/etc/php/$PHP_MAIN_VER/fpm" ]; then
        echo -e "PHP-FPM: ${YELLOW}Installed${NC}"
        
        # Get PHP-FPM pool settings
        PHP_FPM_POOL="/etc/php/$PHP_MAIN_VER/fpm/pool.d/www.conf"
        if [ -f "$PHP_FPM_POOL" ]; then
            echo -e "\n${BLUE}PHP-FPM Pool Settings:${NC}"
            grep -E "^pm = |^pm.max_children = |^pm.start_servers = |^pm.min_spare_servers = |^pm.max_spare_servers = |^pm.max_requests = " "$PHP_FPM_POOL" | sed 's/^[ \t]*//'
        fi
        
        # Get PHP memory settings
        PHP_INI="/etc/php/$PHP_MAIN_VER/fpm/php.ini"
        if [ -f "$PHP_INI" ]; then
            echo -e "\n${BLUE}PHP Memory Settings:${NC}"
            grep -E "^memory_limit = |^upload_max_filesize = |^post_max_size = |^max_execution_time = " "$PHP_INI" | sed 's/^[ \t]*//'
        fi
        
        # Get PHP OpCache settings
        PHP_OPCACHE="/etc/php/$PHP_MAIN_VER/fpm/conf.d/10-opcache.ini"
        if [ -f "$PHP_OPCACHE" ]; then
            echo -e "\n${BLUE}PHP OpCache Settings:${NC}"
            grep -E "^opcache.enable|^opcache.memory_consumption|^opcache.interned_strings_buffer|^opcache.max_accelerated_files|^opcache.jit" "$PHP_OPCACHE" 2>/dev/null | sed 's/^[ \t]*//'
        fi
    else
        echo -e "PHP-FPM: ${RED}Not installed${NC}"
    fi
else
    echo -e "${RED}PHP not installed or not detected${NC}"
fi

# --- MYSQL INFORMATION ---
echo -e "\n${GREEN}MySQL/MariaDB Information:${NC}"
if command -v mysql &> /dev/null; then
    if mysql --version | grep -q MariaDB; then
        DB_TYPE="MariaDB"
    else
        DB_TYPE="MySQL"
    fi
    DB_VERSION=$(mysql --version | awk '{print $3}')
    echo -e "Database: ${YELLOW}$DB_TYPE $DB_VERSION${NC}"
    
    # Read configuration files
    echo -e "\n${BLUE}Database Configuration:${NC}"
    MYSQL_CONFIGS=("/etc/mysql/my.cnf" "/etc/mysql/mysql.conf.d/mysqld.cnf" "/etc/mysql/mariadb.conf.d/50-server.cnf")
    
    CONFIG_FOUND=false
    for CONFIG_FILE in "${MYSQL_CONFIGS[@]}"; do
        if [ -f "$CONFIG_FILE" ]; then
            echo -e "Reading from ${YELLOW}$CONFIG_FILE${NC}:"
            MYSQL_SETTINGS=$(grep -E "^innodb_buffer_pool_size|^max_connections|^query_cache_size|^query_cache_type|^key_buffer_size|^innodb_log_file_size|^table_open_cache|^thread_cache_size|^join_buffer_size|^sort_buffer_size|^read_buffer_size|^read_rnd_buffer_size|^innodb_flush_method|^innodb_flush_log_at_trx_commit" "$CONFIG_FILE" 2>/dev/null)
            
            if [ -n "$MYSQL_SETTINGS" ]; then
                echo "$MYSQL_SETTINGS"
                CONFIG_FOUND=true
            else
                echo -e "${YELLOW}No relevant settings found in this file${NC}"
            fi
        fi
    done
    
    if [ "$CONFIG_FOUND" = false ]; then
        echo -e "${YELLOW}No MySQL/MariaDB configuration found in standard locations.${NC}"
        echo -e "${YELLOW}You might need to check other locations or the database might be using default values.${NC}"
    fi
else
    echo -e "${RED}MySQL/MariaDB not installed or not detected${NC}"
fi

echo -e "\n${BLUE}======================================================${NC}"