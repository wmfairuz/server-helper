#!/bin/bash

# MySQL Database Export/Import Script
# Automatically reads database configuration from .env file

set -e  # Exit on any error

# Default paths
DEFAULT_PROJECT_DIR="./"
DEFAULT_BACKUP_DIR="./"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

print_info() {
    echo -e "$1"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] COMMAND"
    echo ""
    echo "COMMANDS:"
    echo "  export                Export database to compressed file"
    echo "  import FILE          Import database from compressed file"
    echo ""
    echo "OPTIONS:"
    echo "  -p, --project-dir DIR    Project directory containing .env file (default: $DEFAULT_PROJECT_DIR)"
    echo "  -b, --backup-dir DIR     Backup directory (default: $DEFAULT_BACKUP_DIR)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 export"
    echo "  $0 import /home/vetpn9/vetpn9_staging_20250609_1022GMT+8.sql.gz"
    echo "  $0 -p /custom/path -b /custom/backup export"
}

# Function to read .env file and extract database configuration
read_env_config() {
    local env_file="$1/.env"
    
    if [[ ! -f "$env_file" ]]; then
        print_error ".env file not found at $env_file"
        exit 1
    fi
    
    print_info "Reading database configuration from $env_file"
    
    # Extract database configuration
    DB_HOST=$(grep "^DB_HOST=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_PORT=$(grep "^DB_PORT=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_DATABASE=$(grep "^DB_DATABASE=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_USERNAME=$(grep "^DB_USERNAME=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_PASSWORD=$(grep "^DB_PASSWORD=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    
    # Validate required fields
    if [[ -z "$DB_HOST" || -z "$DB_PORT" || -z "$DB_DATABASE" || -z "$DB_USERNAME" ]]; then
        print_error "Missing required database configuration in .env file"
        print_error "Required: DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME"
        exit 1
    fi
    
    if [[ -z "$DB_PASSWORD" ]]; then
        print_warning "DB_PASSWORD is empty - you will be prompted for password"
    fi
    
    print_info "Database configuration loaded:"
    print_info "  Host: $DB_HOST"
    print_info "  Port: $DB_PORT"
    print_info "  Database: $DB_DATABASE"
    print_info "  Username: $DB_USERNAME"
}

# Function to export database
export_database() {
    local backup_dir="$1"
    local project_dir="$2"
    
    # Read configuration
    read_env_config "$project_dir"
    
    # Create backup directory if it doesn't exist
    mkdir -p "$backup_dir"
    
    # Generate timestamp
    DATETIME=$(date +'%Y%m%d_%H%M')
    BACKUP_FILE="${backup_dir}/${DB_DATABASE}_${DATETIME}.sql.gz"
    
    print_info "Starting database export..."
    print_info "Backup file: $BACKUP_FILE"
    
    # Build mysqldump command
    MYSQLDUMP_CMD="mysqldump --single-transaction --quick --no-tablespaces"
    MYSQLDUMP_CMD="$MYSQLDUMP_CMD -h $DB_HOST -P $DB_PORT -u $DB_USERNAME"
    
    if [[ -n "$DB_PASSWORD" ]]; then
        MYSQLDUMP_CMD="$MYSQLDUMP_CMD -p$DB_PASSWORD"
    else
        MYSQLDUMP_CMD="$MYSQLDUMP_CMD -p"
    fi
    
    MYSQLDUMP_CMD="$MYSQLDUMP_CMD $DB_DATABASE"
    
    # Execute export
    if eval "$MYSQLDUMP_CMD | gzip > $BACKUP_FILE"; then
        print_success "Database exported successfully to $BACKUP_FILE"
        
        # Show file size
        FILE_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        print_info "Backup file size: $FILE_SIZE"
    else
        print_error "Database export failed"
        exit 1
    fi
}

# Function to import database
import_database() {
    local import_file="$1"
    local project_dir="$2"
    
    # Check if import file exists
    if [[ ! -f "$import_file" ]]; then
        print_error "Import file not found: $import_file"
        exit 1
    fi
    
    # Read configuration
    read_env_config "$project_dir"
    
    print_info "Starting database import..."
    print_info "Import file: $import_file"
    print_warning "This will overwrite the existing database: $DB_DATABASE"
    
    # Ask for confirmation
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Import cancelled"
        exit 0
    fi
    
    # Build mysql command
    MYSQL_CMD="mysql -h $DB_HOST -P $DB_PORT -u $DB_USERNAME"
    
    if [[ -n "$DB_PASSWORD" ]]; then
        MYSQL_CMD="$MYSQL_CMD -p$DB_PASSWORD"
    else
        MYSQL_CMD="$MYSQL_CMD -p"
    fi
    
    MYSQL_CMD="$MYSQL_CMD $DB_DATABASE"
    
    # Execute import
    if zcat "$import_file" | eval "$MYSQL_CMD"; then
        print_success "Database imported successfully from $import_file"
    else
        print_error "Database import failed"
        exit 1
    fi
}

# Parse command line arguments
PROJECT_DIR="$DEFAULT_PROJECT_DIR"
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
COMMAND=""
IMPORT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        -b|--backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        export)
            COMMAND="export"
            shift
            ;;
        import)
            COMMAND="import"
            IMPORT_FILE="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate command
if [[ -z "$COMMAND" ]]; then
    print_error "No command specified"
    show_usage
    exit 1
fi

# Execute command
case "$COMMAND" in
    export)
        export_database "$BACKUP_DIR" "$PROJECT_DIR"
        ;;
    import)
        if [[ -z "$IMPORT_FILE" ]]; then
            print_error "Import file not specified"
            show_usage
            exit 1
        fi
        import_database "$IMPORT_FILE" "$PROJECT_DIR"
        ;;
    *)
        print_error "Invalid command: $COMMAND"
        show_usage
        exit 1
        ;;
esac