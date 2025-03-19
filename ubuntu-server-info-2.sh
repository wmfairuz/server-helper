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

# Determine which spec fits
# Initialize with the lowest spec
SPEC=1

# Upgrade specs based on hardware
if [ $CPU_CORES -ge 2 ] && [ $TOTAL_MEM_MB -ge 2048 ]; then
    SPEC=2
fi

if [ $CPU_CORES -ge 2 ] && [ $TOTAL_MEM_MB -ge 4096 ]; then
    SPEC=3
fi

if [ $CPU_CORES -ge 4 ] && [ $TOTAL_MEM_MB -ge 8192 ]; then
    SPEC=4
fi

if [ $CPU_CORES -ge 8 ] && [ $TOTAL_MEM_MB -ge 16384 ]; then
    SPEC=5
fi

if [ $CPU_CORES -ge 16 ] && [ $TOTAL_MEM_MB -ge 32768 ]; then
    SPEC=6
fi

# Define server spec descriptions
case $SPEC in
    1) SPEC_DESC="CPU 1, 2GB Memory" ;;
    2) SPEC_DESC="CPU 2, 2GB Memory" ;;
    3) SPEC_DESC="CPU 2, 4GB Memory" ;;
    4) SPEC_DESC="CPU 4, 8GB Memory" ;;
    5) SPEC_DESC="CPU 8, 16GB Memory" ;;
    6) SPEC_DESC="CPU 16, 32GB Memory" ;;
esac

echo -e "\n${BLUE}Based on your hardware, your server matches:${NC}"
echo -e "${YELLOW}Spec $SPEC: $SPEC_DESC${NC}"

# Additional spec determination logic
if [ $CPU_CORES -ge 8 ] && [ $TOTAL_MEM_MB -lt 16384 ]; then
    echo -e "${YELLOW}Note: Your server has Spec 5 CPU cores but less than 16GB RAM${NC}"
    echo -e "${YELLOW}Consider using Spec 4 settings with some Spec 5 adjustments${NC}"
elif [ $CPU_CORES -lt 8 ] && [ $TOTAL_MEM_MB -ge 16384 ]; then
    echo -e "${YELLOW}Note: Your server has Spec 5 memory but fewer than 8 CPU cores${NC}"
    echo -e "${YELLOW}Consider using Spec 4 settings with increased memory allocations${NC}"
fi

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

# --- RECOMMENDED SETTINGS BASED ON SPEC ---
echo -e "\n${BLUE}======================================================"
echo "      RECOMMENDED SETTINGS FOR SPEC $SPEC"
echo "======================================================${NC}"

# Display recommended settings based on server spec
case $SPEC in
    1)
        echo -e "\n${GREEN}Recommended Apache Settings:${NC}"
        echo "StartServers             2"
        echo "MinSpareThreads          5"
        echo "MaxSpareThreads          10"
        echo "ThreadLimit              64"
        echo "ThreadsPerChild          25"
        echo "MaxRequestWorkers        50"
        echo "MaxConnectionsPerChild   1000"
        echo "KeepAlive                On"
        echo "MaxKeepAliveRequests     100"
        echo "KeepAliveTimeout         5"
        
        echo -e "\n${GREEN}Recommended PHP-FPM Settings:${NC}"
        echo "pm = dynamic"
        echo "pm.max_children = 10"
        echo "pm.start_servers = 2"
        echo "pm.min_spare_servers = 1"
        echo "pm.max_spare_servers = 3"
        echo "pm.max_requests = 500"
        echo "memory_limit = 128M"
        
        echo -e "\n${GREEN}Recommended MySQL Settings:${NC}"
        echo "innodb_buffer_pool_size = 512M"
        echo "innodb_log_file_size = 64M"
        echo "max_connections = 100"
        echo "table_open_cache = 256"
        echo "query_cache_size = 32M"
        echo "key_buffer_size = 32M"
        echo "thread_cache_size = 8"
        ;;
    2)
        echo -e "\n${GREEN}Recommended Apache Settings:${NC}"
        echo "StartServers             3"
        echo "MinSpareThreads          10"
        echo "MaxSpareThreads          20"
        echo "ThreadLimit              64"
        echo "ThreadsPerChild          25"
        echo "MaxRequestWorkers        100"
        echo "MaxConnectionsPerChild   2000"
        echo "KeepAlive                On"
        echo "MaxKeepAliveRequests     150"
        echo "KeepAliveTimeout         5"
        
        echo -e "\n${GREEN}Recommended PHP-FPM Settings:${NC}"
        echo "pm = dynamic"
        echo "pm.max_children = 15"
        echo "pm.start_servers = 3"
        echo "pm.min_spare_servers = 2"
        echo "pm.max_spare_servers = 5"
        echo "pm.max_requests = 500"
        echo "memory_limit = 256M"
        
        echo -e "\n${GREEN}Recommended MySQL Settings:${NC}"
        echo "innodb_buffer_pool_size = 768M"
        echo "innodb_log_file_size = 128M"
        echo "max_connections = 150"
        echo "table_open_cache = 400"
        echo "query_cache_size = 64M"
        echo "key_buffer_size = 64M"
        echo "thread_cache_size = 16"
        ;;
    3)
        echo -e "\n${GREEN}Recommended Apache Settings:${NC}"
        echo "StartServers             4"
        echo "MinSpareThreads          15"
        echo "MaxSpareThreads          30"
        echo "ThreadLimit              64"
        echo "ThreadsPerChild          25"
        echo "MaxRequestWorkers        150"
        echo "MaxConnectionsPerChild   3000"
        echo "KeepAlive                On"
        echo "MaxKeepAliveRequests     200"
        echo "KeepAliveTimeout         5"
        
        echo -e "\n${GREEN}Recommended PHP-FPM Settings:${NC}"
        echo "pm = dynamic"
        echo "pm.max_children = 25"
        echo "pm.start_servers = 5"
        echo "pm.min_spare_servers = 3"
        echo "pm.max_spare_servers = 10"
        echo "pm.max_requests = 1000"
        echo "memory_limit = 512M"
        
        echo -e "\n${GREEN}Recommended MySQL Settings:${NC}"
        echo "innodb_buffer_pool_size = 1536M"
        echo "innodb_log_file_size = 256M"
        echo "max_connections = 200"
        echo "table_open_cache = 800"
        echo "query_cache_size = 128M"
        echo "key_buffer_size = 128M"
        echo "thread_cache_size = 32"
        ;;
    4)
        echo -e "\n${GREEN}Recommended Apache Settings:${NC}"
        echo "StartServers             8"
        echo "MinSpareThreads          25"
        echo "MaxSpareThreads          75"
        echo "ThreadLimit              128"
        echo "ThreadsPerChild          25"
        echo "MaxRequestWorkers        300"
        echo "MaxConnectionsPerChild   10000"
        echo "KeepAlive                On"
        echo "MaxKeepAliveRequests     300"
        echo "KeepAliveTimeout         3"
        
        echo -e "\n${GREEN}Recommended PHP-FPM Settings:${NC}"
        echo "pm = dynamic"
        echo "pm.max_children = 50"
        echo "pm.start_servers = 8"
        echo "pm.min_spare_servers = 5"
        echo "pm.max_spare_servers = 15"
        echo "pm.max_requests = 2000"
        echo "memory_limit = 1024M"
        
        echo -e "\n${GREEN}Recommended MySQL Settings:${NC}"
        echo "innodb_buffer_pool_size = 4G"
        echo "innodb_log_file_size = 512M"
        echo "max_connections = 400"
        echo "table_open_cache = 1500"
        echo "query_cache_size = 256M"
        echo "key_buffer_size = 256M"
        echo "thread_cache_size = 64"
        echo "innodb_flush_method = O_DIRECT"
        ;;
    5)
        echo -e "\n${GREEN}Recommended Apache Settings:${NC}"
        echo "StartServers             12"
        echo "MinSpareThreads          50"
        echo "MaxSpareThreads          150"
        echo "ThreadLimit              192"
        echo "ThreadsPerChild          30"
        echo "MaxRequestWorkers        600"
        echo "MaxConnectionsPerChild   15000"
        echo "KeepAlive                On"
        echo "MaxKeepAliveRequests     500"
        echo "KeepAliveTimeout         3"
        
        echo -e "\n${GREEN}Recommended PHP-FPM Settings:${NC}"
        echo "pm = dynamic"
        echo "pm.max_children = 100"
        echo "pm.start_servers = 20"
        echo "pm.min_spare_servers = 10"
        echo "pm.max_spare_servers = 30"
        echo "pm.max_requests = 5000"
        echo "memory_limit = 2048M"
        
        echo -e "\n${GREEN}Recommended MySQL Settings:${NC}"
        echo "innodb_buffer_pool_size = 10G"
        echo "innodb_log_file_size = 1G"
        echo "max_connections = 800"
        echo "table_open_cache = 3000"
        echo "query_cache_size = 512M"
        echo "key_buffer_size = 512M"
        echo "thread_cache_size = 128"
        echo "innodb_flush_method = O_DIRECT"
        echo "innodb_flush_log_at_trx_commit = 2"
        ;;
    6)
        echo -e "\n${GREEN}Recommended Apache Settings:${NC}"
        echo "StartServers             20"
        echo "MinSpareThreads          100"
        echo "MaxSpareThreads          250"
        echo "ThreadLimit              256"
        echo "ThreadsPerChild          35"
        echo "MaxRequestWorkers        1200"
        echo "MaxConnectionsPerChild   20000"
        echo "KeepAlive                On"
        echo "MaxKeepAliveRequests     1000"
        echo "KeepAliveTimeout         2"
        
        echo -e "\n${GREEN}Recommended PHP-FPM Settings:${NC}"
        echo "pm = dynamic"
        echo "pm.max_children = 200"
        echo "pm.start_servers = 30"
        echo "pm.min_spare_servers = 20"
        echo "pm.max_spare_servers = 60"
        echo "pm.max_requests = 10000"
        echo "memory_limit = 4096M"
        
        echo -e "\n${GREEN}Recommended MySQL Settings:${NC}"
        echo "innodb_buffer_pool_size = 20G"
        echo "innodb_log_file_size = 2G"
        echo "max_connections = 1500"
        echo "table_open_cache = 6000"
        echo "query_cache_size = 0"
        echo "query_cache_type = 0"
        echo "key_buffer_size = 1G"
        echo "thread_cache_size = 256"
        echo "innodb_flush_method = O_DIRECT"
        echo "innodb_flush_log_at_trx_commit = 2"
        echo "innodb_read_io_threads = 8"
        echo "innodb_write_io_threads = 8"
        ;;
esac

echo -e "\n${BLUE}======================================================${NC}"