#!/bin/bash

# Ubuntu Server Configuration Retriever and Recommender
# This script retrieves actual configurations and provides recommendations

# Color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================"
echo "     SERVER CONFIGURATION ANALYZER AND RECOMMENDER"
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

# Determine which spec fits - corrected logic
if [ $CPU_CORES -ge 16 ] && [ $TOTAL_MEM_MB -ge 32000 ]; then
    SPEC=6
elif [ $CPU_CORES -ge 8 ] && [ $TOTAL_MEM_MB -ge 15500 ]; then  # Closer to 16GB
    SPEC=5
elif [ $CPU_CORES -ge 4 ] && [ $TOTAL_MEM_MB -ge 7500 ]; then   # Closer to 8GB
    SPEC=4
elif [ $CPU_CORES -ge 2 ] && [ $TOTAL_MEM_MB -ge 3500 ]; then   # Closer to 4GB 
    SPEC=3
elif [ $CPU_CORES -ge 2 ] && [ $TOTAL_MEM_MB -ge 1800 ]; then   # Closer to 2GB
    SPEC=2
else
    SPEC=1
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

echo -e "\n${BLUE}Based on your hardware, your server best matches:${NC}"
echo -e "${YELLOW}Spec $SPEC: $SPEC_DESC${NC}"

# Check for in-between configurations for more accurate recommendations
if [ $SPEC -eq 4 ] && [ $CPU_CORES -ge 8 ]; then
    echo -e "${YELLOW}Note: Your server has more CPU cores than Spec 4${NC}"
    echo -e "${YELLOW}Consider using higher thread/worker counts${NC}"
elif [ $SPEC -eq 5 ] && [ $TOTAL_MEM_MB -lt 16000 ]; then
    echo -e "${YELLOW}Note: Your server has slightly less than 16GB RAM${NC}"
    echo -e "${YELLOW}The recommendations are still appropriate but monitor memory usage${NC}"
fi

# Helper function to compare values and return color
compare_values() {
    local current="$1"
    local recommended="$2"
    
    # Handle "Not Set" or "N/A" cases
    if [[ "$current" == "Not Set" || "$recommended" == "N/A" ]]; then
        echo -e "$YELLOW$current$NC"
        return
    fi
    
    # Normalize values for comparison (strip units like M, G, etc.)
    local current_normalized=$(echo "$current" | sed -E 's/([0-9.]+).*/\1/')
    local recommended_normalized=$(echo "$recommended" | sed -E 's/([0-9.]+).*/\1/')
    
    # Get units if they exist
    local current_unit=$(echo "$current" | sed -E 's/[0-9.]+([^0-9]*)/\1/')
    local recommended_unit=$(echo "$recommended" | sed -E 's/[0-9.]+([^0-9]*)/\1/')
    
    # Special case for On/Off or numeric values
    if [[ "$current" == "$recommended" ]] || 
       ([[ "$current_unit" == "$recommended_unit" ]] && 
        awk "BEGIN {exit !($current_normalized == $recommended_normalized)}"); then
        echo -e "$GREEN$current$NC"
    else
        echo -e "$RED$current$NC"
    fi
}

# --- APACHE INFORMATION ---
echo -e "\n${GREEN}Apache Configuration:${NC}"
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
    
    # Create arrays to store current and recommended values
    declare -A apache_current
    declare -A apache_recommended
    
    # Set recommended values based on spec
    case $SPEC in
        1)
            apache_recommended["StartServers"]="2"
            apache_recommended["MinSpareThreads"]="5"
            apache_recommended["MaxSpareThreads"]="10"
            apache_recommended["ThreadLimit"]="64"
            apache_recommended["ThreadsPerChild"]="25"
            apache_recommended["MaxRequestWorkers"]="50"
            apache_recommended["MaxConnectionsPerChild"]="1000"
            apache_recommended["KeepAlive"]="On"
            apache_recommended["MaxKeepAliveRequests"]="100"
            apache_recommended["KeepAliveTimeout"]="5"
            ;;
        2)
            apache_recommended["StartServers"]="3"
            apache_recommended["MinSpareThreads"]="10"
            apache_recommended["MaxSpareThreads"]="20"
            apache_recommended["ThreadLimit"]="64"
            apache_recommended["ThreadsPerChild"]="25"
            apache_recommended["MaxRequestWorkers"]="100"
            apache_recommended["MaxConnectionsPerChild"]="2000"
            apache_recommended["KeepAlive"]="On"
            apache_recommended["MaxKeepAliveRequests"]="150"
            apache_recommended["KeepAliveTimeout"]="5"
            ;;
        3)
            apache_recommended["StartServers"]="4"
            apache_recommended["MinSpareThreads"]="15"
            apache_recommended["MaxSpareThreads"]="30"
            apache_recommended["ThreadLimit"]="64"
            apache_recommended["ThreadsPerChild"]="25"
            apache_recommended["MaxRequestWorkers"]="150"
            apache_recommended["MaxConnectionsPerChild"]="3000"
            apache_recommended["KeepAlive"]="On"
            apache_recommended["MaxKeepAliveRequests"]="200"
            apache_recommended["KeepAliveTimeout"]="5"
            ;;
        4)
            apache_recommended["StartServers"]="8"
            apache_recommended["MinSpareThreads"]="25"
            apache_recommended["MaxSpareThreads"]="75"
            apache_recommended["ThreadLimit"]="128"
            apache_recommended["ThreadsPerChild"]="25"
            apache_recommended["MaxRequestWorkers"]="300"
            apache_recommended["MaxConnectionsPerChild"]="10000"
            apache_recommended["KeepAlive"]="On"
            apache_recommended["MaxKeepAliveRequests"]="300"
            apache_recommended["KeepAliveTimeout"]="3"
            ;;
        5)
            apache_recommended["StartServers"]="12"
            apache_recommended["MinSpareThreads"]="50"
            apache_recommended["MaxSpareThreads"]="150"
            apache_recommended["ThreadLimit"]="192"
            apache_recommended["ThreadsPerChild"]="30"
            apache_recommended["MaxRequestWorkers"]="600"
            apache_recommended["MaxConnectionsPerChild"]="15000"
            apache_recommended["KeepAlive"]="On"
            apache_recommended["MaxKeepAliveRequests"]="500"
            apache_recommended["KeepAliveTimeout"]="3"
            ;;
        6)
            apache_recommended["StartServers"]="20"
            apache_recommended["MinSpareThreads"]="100"
            apache_recommended["MaxSpareThreads"]="250"
            apache_recommended["ThreadLimit"]="256"
            apache_recommended["ThreadsPerChild"]="35"
            apache_recommended["MaxRequestWorkers"]="1200"
            apache_recommended["MaxConnectionsPerChild"]="20000"
            apache_recommended["KeepAlive"]="On"
            apache_recommended["MaxKeepAliveRequests"]="1000"
            apache_recommended["KeepAliveTimeout"]="2"
            ;;
    esac
    
    # Get current Apache settings
    if [ "$MPM_MODE" != "unknown" ] && [ -f "$MPM_FILE" ]; then
        # Extract values from MPM config
        while IFS= read -r line; do
            # Skip comment lines and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            
            for param in StartServers MinSpareThreads MinSpareServers MaxSpareThreads MaxSpareServers ThreadLimit ThreadsPerChild MaxRequestWorkers MaxClients MaxConnectionsPerChild MaxRequestsPerChild; do
                if [[ "$line" =~ $param[[:space:]]+([0-9]+) ]]; then
                    apache_current["$param"]="${BASH_REMATCH[1]}"
                fi
            done
        done < "$MPM_FILE"
    fi
    
    # Get Apache global settings
    if [ -f /etc/apache2/apache2.conf ]; then
        while IFS= read -r line; do
            # Skip comment lines and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            
            if [[ "$line" =~ KeepAlive[[:space:]]+([Oo]n|[Oo]ff) ]]; then
                apache_current["KeepAlive"]="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ MaxKeepAliveRequests[[:space:]]+([0-9]+) ]]; then
                apache_current["MaxKeepAliveRequests"]="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ KeepAliveTimeout[[:space:]]+([0-9]+) ]]; then
                apache_current["KeepAliveTimeout"]="${BASH_REMATCH[1]}"
            fi
        done < /etc/apache2/apache2.conf
    fi
    
    # Display table for Apache
    echo -e "\n${BLUE}Apache Settings Comparison:${NC}"
    echo "Setting                         Current Value              Recommended Value"
    echo "-------                         ------------              -----------------"
    
    for param in StartServers MinSpareThreads MaxSpareThreads ThreadLimit ThreadsPerChild MaxRequestWorkers MaxConnectionsPerChild KeepAlive MaxKeepAliveRequests KeepAliveTimeout; do
        current="${apache_current[$param]:-Not Set}"
        recommended="${apache_recommended[$param]:-N/A}"
        colored_current=$(compare_values "$current" "$recommended")
        printf "%-30s %-30b %-20s\n" "$param" "$colored_current" "$recommended"
    done
    
else
    echo -e "${RED}Apache not installed or not detected${NC}"
fi

# --- PHP-FPM INFORMATION ---
echo -e "\n${GREEN}PHP-FPM Configuration:${NC}"
if command -v php &> /dev/null; then
    PHP_VERSION=$(php -v | head -n 1 | cut -d " " -f 2)
    PHP_MAIN_VER=$(echo $PHP_VERSION | cut -d "." -f 1,2)
    echo -e "PHP Version: ${YELLOW}$PHP_VERSION${NC}"
    
    # Check if PHP-FPM is installed
    if [ -d "/etc/php/$PHP_MAIN_VER/fpm" ]; then
        echo -e "PHP-FPM: ${YELLOW}Installed${NC}"
        
        # Create arrays to store current and recommended values
        declare -A php_current
        declare -A php_recommended
        
        # Set recommended values based on spec
        case $SPEC in
            1)
                php_recommended["pm"]="dynamic"
                php_recommended["pm.max_children"]="10"
                php_recommended["pm.start_servers"]="2"
                php_recommended["pm.min_spare_servers"]="1"
                php_recommended["pm.max_spare_servers"]="3"
                php_recommended["pm.max_requests"]="500"
                php_recommended["memory_limit"]="128M"
                php_recommended["upload_max_filesize"]="2M"
                php_recommended["post_max_size"]="8M"
                php_recommended["max_execution_time"]="30"
                ;;
            2)
                php_recommended["pm"]="dynamic"
                php_recommended["pm.max_children"]="15"
                php_recommended["pm.start_servers"]="3"
                php_recommended["pm.min_spare_servers"]="2"
                php_recommended["pm.max_spare_servers"]="5"
                php_recommended["pm.max_requests"]="500"
                php_recommended["memory_limit"]="256M"
                php_recommended["upload_max_filesize"]="4M"
                php_recommended["post_max_size"]="16M"
                php_recommended["max_execution_time"]="30"
                ;;
            3)
                php_recommended["pm"]="dynamic"
                php_recommended["pm.max_children"]="25"
                php_recommended["pm.start_servers"]="5"
                php_recommended["pm.min_spare_servers"]="3"
                php_recommended["pm.max_spare_servers"]="10"
                php_recommended["pm.max_requests"]="1000"
                php_recommended["memory_limit"]="512M"
                php_recommended["upload_max_filesize"]="8M"
                php_recommended["post_max_size"]="32M"
                php_recommended["max_execution_time"]="60"
                ;;
            4)
                php_recommended["pm"]="dynamic"
                php_recommended["pm.max_children"]="50"
                php_recommended["pm.start_servers"]="8"
                php_recommended["pm.min_spare_servers"]="5"
                php_recommended["pm.max_spare_servers"]="15"
                php_recommended["pm.max_requests"]="2000"
                php_recommended["memory_limit"]="1024M"
                php_recommended["upload_max_filesize"]="16M"
                php_recommended["post_max_size"]="64M"
                php_recommended["max_execution_time"]="60"
                ;;
            5)
                php_recommended["pm"]="dynamic"
                php_recommended["pm.max_children"]="100"
                php_recommended["pm.start_servers"]="20"
                php_recommended["pm.min_spare_servers"]="10"
                php_recommended["pm.max_spare_servers"]="30"
                php_recommended["pm.max_requests"]="5000"
                php_recommended["memory_limit"]="2048M"
                php_recommended["upload_max_filesize"]="32M"
                php_recommended["post_max_size"]="128M"
                php_recommended["max_execution_time"]="90"
                ;;
            6)
                php_recommended["pm"]="dynamic"
                php_recommended["pm.max_children"]="200"
                php_recommended["pm.start_servers"]="30"
                php_recommended["pm.min_spare_servers"]="20"
                php_recommended["pm.max_spare_servers"]="60"
                php_recommended["pm.max_requests"]="10000"
                php_recommended["memory_limit"]="4096M"
                php_recommended["upload_max_filesize"]="64M"
                php_recommended["post_max_size"]="256M"
                php_recommended["max_execution_time"]="120"
                ;;
        esac
        
        # Get PHP-FPM pool settings
        PHP_FPM_POOL="/etc/php/$PHP_MAIN_VER/fpm/pool.d/www.conf"
        if [ -f "$PHP_FPM_POOL" ]; then
            # Extract values from PHP-FPM pool config
            while IFS= read -r line; do
                # Skip comment lines and empty lines
                [[ "$line" =~ ^[[:space:]]*\; ]] && continue
                [[ -z "$line" ]] && continue
                
                for param in pm pm.max_children pm.start_servers pm.min_spare_servers pm.max_spare_servers pm.max_requests; do
                    if [[ "$line" =~ ^$param[[:space:]]*=[[:space:]]*(.+) ]]; then
                        php_current["$param"]="${BASH_REMATCH[1]}"
                    fi
                done
            done < "$PHP_FPM_POOL"
        fi
        
        # Get PHP memory settings
        PHP_INI="/etc/php/$PHP_MAIN_VER/fpm/php.ini"
        if [ -f "$PHP_INI" ]; then
            # Extract values from PHP.ini
            while IFS= read -r line; do
                # Skip comment lines and empty lines
                [[ "$line" =~ ^[[:space:]]*\; ]] && continue
                [[ -z "$line" ]] && continue
                
                for param in memory_limit upload_max_filesize post_max_size max_execution_time; do
                    if [[ "$line" =~ ^$param[[:space:]]*=[[:space:]]*(.+) ]]; then
                        php_current["$param"]="${BASH_REMATCH[1]}"
                    fi
                done
            done < "$PHP_INI"
        fi
        
        # Display table for PHP-FPM
        echo -e "\n${BLUE}PHP-FPM Settings Comparison:${NC}"
        echo "Setting                         Current Value              Recommended Value"
        echo "-------                         ------------              -----------------"
        
        for param in pm pm.max_children pm.start_servers pm.min_spare_servers pm.max_spare_servers pm.max_requests memory_limit upload_max_filesize post_max_size max_execution_time; do
            current="${php_current[$param]:-Not Set}"
            recommended="${php_recommended[$param]:-N/A}"
            colored_current=$(compare_values "$current" "$recommended")
            printf "%-30s %-30b %-20s\n" "$param" "$colored_current" "$recommended"
        done
        
    else
        echo -e "PHP-FPM: ${RED}Not installed${NC}"
    fi
else
    echo -e "${RED}PHP not installed or not detected${NC}"
fi

# --- MYSQL INFORMATION ---
echo -e "\n${GREEN}MySQL/MariaDB Configuration:${NC}"
if command -v mysql &> /dev/null; then
    if mysql --version | grep -q MariaDB; then
        DB_TYPE="MariaDB"
    else
        DB_TYPE="MySQL"
    fi
    DB_VERSION=$(mysql --version | awk '{print $3}')
    echo -e "Database: ${YELLOW}$DB_TYPE $DB_VERSION${NC}"
    
    # Create arrays to store current and recommended values
    declare -A mysql_current
    declare -A mysql_recommended
    
    # Set recommended values based on spec
    case $SPEC in
        1)
            mysql_recommended["innodb_buffer_pool_size"]="512M"
            mysql_recommended["innodb_buffer_pool_instances"]="1"
            mysql_recommended["innodb_buffer_pool_chunk_size"]="128M"
            mysql_recommended["innodb_dedicated_server"]="OFF"
            mysql_recommended["innodb_log_file_size"]="64M"
            mysql_recommended["innodb_redo_log_capacity"]="128M"
            mysql_recommended["max_connections"]="100"
            mysql_recommended["table_open_cache"]="256"
            mysql_recommended["table_open_cache_instances"]="2"
            mysql_recommended["open_files_limit"]="1024"
            mysql_recommended["query_cache_size"]="32M"
            mysql_recommended["query_cache_type"]="1"
            mysql_recommended["key_buffer_size"]="32M"
            mysql_recommended["thread_cache_size"]="8"
            mysql_recommended["innodb_file_per_table"]="1"
            mysql_recommended["innodb_flush_method"]="O_DIRECT"
            mysql_recommended["innodb_flush_neighbors"]="1"
            mysql_recommended["innodb_io_capacity"]="200"
            mysql_recommended["innodb_io_capacity_max"]="400"
            mysql_recommended["join_buffer_size"]="128K"
            mysql_recommended["sort_buffer_size"]="256K"
            mysql_recommended["read_buffer_size"]="128K"
            mysql_recommended["read_rnd_buffer_size"]="256K"
            mysql_recommended["innodb_buffer_pool_dump_at_shutdown"]="1"
            mysql_recommended["innodb_buffer_pool_load_at_startup"]="1"
            ;;
        2)
            mysql_recommended["innodb_buffer_pool_size"]="768M"
            mysql_recommended["innodb_buffer_pool_instances"]="1"
            mysql_recommended["innodb_buffer_pool_chunk_size"]="128M"
            mysql_recommended["innodb_dedicated_server"]="OFF"
            mysql_recommended["innodb_log_file_size"]="128M"
            mysql_recommended["innodb_redo_log_capacity"]="256M"
            mysql_recommended["max_connections"]="150"
            mysql_recommended["table_open_cache"]="400"
            mysql_recommended["table_open_cache_instances"]="2"
            mysql_recommended["open_files_limit"]="2048"
            mysql_recommended["query_cache_size"]="64M"
            mysql_recommended["query_cache_type"]="1"
            mysql_recommended["key_buffer_size"]="64M"
            mysql_recommended["thread_cache_size"]="16"
            mysql_recommended["innodb_file_per_table"]="1"
            mysql_recommended["innodb_flush_method"]="O_DIRECT"
            mysql_recommended["innodb_flush_neighbors"]="1"
            mysql_recommended["innodb_io_capacity"]="400"
            mysql_recommended["innodb_io_capacity_max"]="800"
            mysql_recommended["join_buffer_size"]="256K"
            mysql_recommended["sort_buffer_size"]="256K"
            mysql_recommended["read_buffer_size"]="128K"
            mysql_recommended["read_rnd_buffer_size"]="256K"
            mysql_recommended["innodb_buffer_pool_dump_at_shutdown"]="1"
            mysql_recommended["innodb_buffer_pool_load_at_startup"]="1"
            ;;
        3)
            mysql_recommended["innodb_buffer_pool_size"]="1536M"
            mysql_recommended["innodb_buffer_pool_instances"]="2"
            mysql_recommended["innodb_buffer_pool_chunk_size"]="128M"
            mysql_recommended["innodb_dedicated_server"]="OFF"
            mysql_recommended["innodb_log_file_size"]="256M"
            mysql_recommended["innodb_redo_log_capacity"]="512M"
            mysql_recommended["max_connections"]="200"
            mysql_recommended["table_open_cache"]="800"
            mysql_recommended["table_open_cache_instances"]="4"
            mysql_recommended["open_files_limit"]="4096"
            mysql_recommended["query_cache_size"]="128M"
            mysql_recommended["query_cache_type"]="1"
            mysql_recommended["key_buffer_size"]="128M"
            mysql_recommended["thread_cache_size"]="32"
            mysql_recommended["innodb_file_per_table"]="1"
            mysql_recommended["innodb_flush_method"]="O_DIRECT"
            mysql_recommended["innodb_flush_neighbors"]="0"
            mysql_recommended["innodb_io_capacity"]="600"
            mysql_recommended["innodb_io_capacity_max"]="1200"
            mysql_recommended["join_buffer_size"]="256K"
            mysql_recommended["sort_buffer_size"]="256K"
            mysql_recommended["read_buffer_size"]="128K"
            mysql_recommended["read_rnd_buffer_size"]="256K"
            mysql_recommended["innodb_buffer_pool_dump_at_shutdown"]="1"
            mysql_recommended["innodb_buffer_pool_load_at_startup"]="1"
            ;;
        4)
            mysql_recommended["innodb_buffer_pool_size"]="4G"
            mysql_recommended["innodb_buffer_pool_instances"]="4"
            mysql_recommended["innodb_buffer_pool_chunk_size"]="128M"
            mysql_recommended["innodb_dedicated_server"]="OFF"
            mysql_recommended["innodb_log_file_size"]="512M"
            mysql_recommended["innodb_redo_log_capacity"]="1G"
            mysql_recommended["max_connections"]="300"
            mysql_recommended["table_open_cache"]="1500"
            mysql_recommended["table_open_cache_instances"]="4"
            mysql_recommended["open_files_limit"]="8192"
            mysql_recommended["query_cache_size"]="256M"
            mysql_recommended["query_cache_type"]="1"
            mysql_recommended["key_buffer_size"]="256M"
            mysql_recommended["thread_cache_size"]="50"
            mysql_recommended["innodb_file_per_table"]="1"
            mysql_recommended["innodb_flush_method"]="O_DIRECT"
            mysql_recommended["innodb_flush_neighbors"]="0"
            mysql_recommended["innodb_io_capacity"]="800"
            mysql_recommended["innodb_io_capacity_max"]="1600"
            mysql_recommended["join_buffer_size"]="256K"
            mysql_recommended["sort_buffer_size"]="256K"
            mysql_recommended["read_buffer_size"]="128K"
            mysql_recommended["read_rnd_buffer_size"]="128K"
            mysql_recommended["innodb_buffer_pool_dump_at_shutdown"]="1"
            mysql_recommended["innodb_buffer_pool_load_at_startup"]="1"
            ;;
        5)
            mysql_recommended["innodb_buffer_pool_size"]="10G"
            mysql_recommended["innodb_buffer_pool_instances"]="8"
            mysql_recommended["innodb_buffer_pool_chunk_size"]="128M"
            mysql_recommended["innodb_dedicated_server"]="OFF"
            mysql_recommended["innodb_log_file_size"]="1G"
            mysql_recommended["innodb_redo_log_capacity"]="2G"
            mysql_recommended["max_connections"]="800"
            mysql_recommended["table_open_cache"]="3000"
            mysql_recommended["table_open_cache_instances"]="8"
            mysql_recommended["open_files_limit"]="16384"
            mysql_recommended["query_cache_size"]="512M"
            mysql_recommended["query_cache_type"]="1"
            mysql_recommended["key_buffer_size"]="512M"
            mysql_recommended["thread_cache_size"]="128"
            mysql_recommended["innodb_file_per_table"]="1"
            mysql_recommended["innodb_flush_method"]="O_DIRECT"
            mysql_recommended["innodb_flush_neighbors"]="0"
            mysql_recommended["innodb_io_capacity"]="1000"
            mysql_recommended["innodb_io_capacity_max"]="2000"
            mysql_recommended["join_buffer_size"]="512K"
            mysql_recommended["sort_buffer_size"]="1M"
            mysql_recommended["read_buffer_size"]="256K"
            mysql_recommended["read_rnd_buffer_size"]="512K"
            mysql_recommended["innodb_buffer_pool_dump_at_shutdown"]="1"
            mysql_recommended["innodb_buffer_pool_load_at_startup"]="1"
            mysql_recommended["innodb_flush_log_at_trx_commit"]="2"
            ;;
        6)
            mysql_recommended["innodb_buffer_pool_size"]="20G"
            mysql_recommended["innodb_buffer_pool_instances"]="16"
            mysql_recommended["innodb_buffer_pool_chunk_size"]="128M"
            mysql_recommended["innodb_dedicated_server"]="OFF"
            mysql_recommended["innodb_log_file_size"]="2G"
            mysql_recommended["innodb_redo_log_capacity"]="4G"
            mysql_recommended["max_connections"]="1500"
            mysql_recommended["table_open_cache"]="6000"
            mysql_recommended["table_open_cache_instances"]="16"
            mysql_recommended["open_files_limit"]="32768"
            mysql_recommended["query_cache_size"]="0"
            mysql_recommended["query_cache_type"]="0"
            mysql_recommended["key_buffer_size"]="1G"
            mysql_recommended["thread_cache_size"]="256"
            mysql_recommended["innodb_file_per_table"]="1"
            mysql_recommended["innodb_flush_method"]="O_DIRECT"
            mysql_recommended["innodb_flush_neighbors"]="0"
            mysql_recommended["innodb_io_capacity"]="2000"
            mysql_recommended["innodb_io_capacity_max"]="4000"
            mysql_recommended["join_buffer_size"]="1M"
            mysql_recommended["sort_buffer_size"]="2M"
            mysql_recommended["read_buffer_size"]="512K"
            mysql_recommended["read_rnd_buffer_size"]="1M"
            mysql_recommended["innodb_buffer_pool_dump_at_shutdown"]="1"
            mysql_recommended["innodb_buffer_pool_load_at_startup"]="1"
            mysql_recommended["innodb_flush_log_at_trx_commit"]="2"
            mysql_recommended["innodb_read_io_threads"]="8"
            mysql_recommended["innodb_write_io_threads"]="8"
            ;;
    esac
    
    # Read MySQL configuration files
    MYSQL_CONFIGS=("/etc/mysql/my.cnf" "/etc/mysql/mysql.conf.d/mysqld.cnf" "/etc/mysql/mariadb.conf.d/50-server.cnf")
    
    for CONFIG_FILE in "${MYSQL_CONFIGS[@]}"; do
        if [ -f "$CONFIG_FILE" ]; then
            # Extract values from MySQL config
            while IFS= read -r line; do
                # Skip comment lines and empty lines
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ -z "$line" ]] && continue
                
                for param in innodb_buffer_pool_size innodb_buffer_pool_instances innodb_buffer_pool_chunk_size innodb_dedicated_server innodb_log_file_size innodb_redo_log_capacity max_connections table_open_cache table_open_cache_instances open_files_limit query_cache_size query_cache_type key_buffer_size thread_cache_size innodb_file_per_table innodb_flush_method innodb_flush_neighbors innodb_io_capacity innodb_io_capacity_max innodb_flush_log_at_trx_commit innodb_read_io_threads innodb_write_io_threads innodb_buffer_pool_dump_at_shutdown innodb_buffer_pool_load_at_startup join_buffer_size sort_buffer_size read_buffer_size read_rnd_buffer_size; do
                    if [[ "$line" =~ ^$param[[:space:]]*=[[:space:]]*(.+) ]]; then
                        mysql_current["$param"]="${BASH_REMATCH[1]}"
                    fi
                done
            done < "$CONFIG_FILE"
        fi
    done
    
    # Display table for MySQL main settings
    echo -e "\n${BLUE}MySQL/MariaDB Settings Comparison:${NC}"
    echo "Setting                         Current Value              Recommended Value"
    echo "-------                         ------------              -----------------"
    
    mysql_main_params=(
        "innodb_buffer_pool_size"
        "innodb_log_file_size"
        "innodb_redo_log_capacity"
        "max_connections"
        "table_open_cache"
        "query_cache_size"
        "query_cache_type"
        "key_buffer_size"
        "thread_cache_size"
        "innodb_flush_method"
        "innodb_flush_log_at_trx_commit"
    )
    
    for param in "${mysql_main_params[@]}"; do
        current="${mysql_current[$param]:-Not Set}"
        recommended="${mysql_recommended[$param]:-N/A}"
        colored_current=$(compare_values "$current" "$recommended")
        printf "%-30s %-30b %-20s\n" "$param" "$colored_current" "$recommended"
    done
    
    # Display table for MySQL buffer/pool settings
    echo -e "\n${BLUE}MySQL/MariaDB Buffer Pool Settings:${NC}"
    echo "Setting                         Current Value              Recommended Value"
    echo "-------                         ------------              -----------------"
    
    mysql_buffer_params=(
        "innodb_buffer_pool_instances"
        "innodb_buffer_pool_chunk_size"
        "innodb_dedicated_server"
        "innodb_buffer_pool_dump_at_shutdown"
        "innodb_buffer_pool_load_at_startup"
    )
    
    for param in "${mysql_buffer_params[@]}"; do
        current="${mysql_current[$param]:-Not Set}"
        recommended="${mysql_recommended[$param]:-N/A}"
        colored_current=$(compare_values "$current" "$recommended")
        printf "%-30s %-30b %-20s\n" "$param" "$colored_current" "$recommended"
    done
    
    # Display table for MySQL system resource settings
    echo -e "\n${BLUE}MySQL/MariaDB System Resource Settings:${NC}"
    echo "Setting                         Current Value              Recommended Value"
    echo "-------                         ------------              -----------------"
    
    mysql_resource_params=(
        "open_files_limit"
        "table_open_cache_instances"
    )
    
    for param in "${mysql_resource_params[@]}"; do
        current="${mysql_current[$param]:-Not Set}"
        recommended="${mysql_recommended[$param]:-N/A}"
        colored_current=$(compare_values "$current" "$recommended")
        printf "%-30s %-30b %-20s\n" "$param" "$colored_current" "$recommended"
    done
    
    # Display table for MySQL InnoDB settings
    echo -e "\n${BLUE}MySQL/MariaDB InnoDB Settings:${NC}"
    echo "Setting                         Current Value              Recommended Value"
    echo "-------                         ------------              -----------------"
    
    mysql_innodb_params=(
        "innodb_file_per_table"
        "innodb_flush_neighbors"
        "innodb_io_capacity"
        "innodb_io_capacity_max"
        "innodb_read_io_threads"
        "innodb_write_io_threads"
    )
    
    for param in "${mysql_innodb_params[@]}"; do
        current="${mysql_current[$param]:-Not Set}"
        recommended="${mysql_recommended[$param]:-N/A}"
        colored_current=$(compare_values "$current" "$recommended")
        printf "%-30s %-30b %-20s\n" "$param" "$colored_current" "$recommended"
    done
    
    # Display table for MySQL memory settings
    echo -e "\n${BLUE}MySQL/MariaDB Memory Settings:${NC}"
    echo "Setting                         Current Value              Recommended Value"
    echo "-------                         ------------              -----------------"
    
    mysql_memory_params=(
        "join_buffer_size"
        "sort_buffer_size"
        "read_buffer_size"
        "read_rnd_buffer_size"
    )
    
    for param in "${mysql_memory_params[@]}"; do
        current="${mysql_current[$param]:-Not Set}"
        recommended="${mysql_recommended[$param]:-N/A}"
        colored_current=$(compare_values "$current" "$recommended")
        printf "%-30s %-30b %-20s\n" "$param" "$colored_current" "$recommended"
    done
    
else
    echo -e "${RED}MySQL/MariaDB not installed or not detected${NC}"
fi

echo -e "\n${BLUE}======================================================${NC}"