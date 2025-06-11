#!/bin/bash

# MySQL Database Export/Import Script
# Uses ~/.my.cnf for secure authentication, creates it from .env if needed

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
    echo "  -p, --project-dir DIR    Project directory containing .env file (required only if ~/.my.cnf doesn't exist)"
    echo "  -b, --backup-dir DIR     Backup directory (default: $DEFAULT_BACKUP_DIR)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  # First time setup (creates ~/.my.cnf from .env):"
    echo "  $0 -p /opt/www/vetpn9 export"
    echo ""
    echo "  # After ~/.my.cnf exists (no project path needed):"
    echo "  $0 export"
    echo "  $0 import /home/vetpn9/vetpn9_staging_20250609_1022GMT+8.sql.gz"
    echo ""
    echo "Note: This script uses ~/.my.cnf for MySQL authentication and database name."
    echo "      If ~/.my.cnf doesn't exist, you must specify -p to create it from your .env file."
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
        print_error "DB_PASSWORD is empty in .env file"
        print_error "Cannot create ~/.my.cnf without a password"
        exit 1
    fi
    
    print_info "Database configuration loaded:"
    print_info "  Host: $DB_HOST"
    print_info "  Port: $DB_PORT"
    print_info "  Database: $DB_DATABASE"
    print_info "  Username: $DB_USERNAME"
}

# Function to create ~/.my.cnf from .env configuration
create_mysql_config() {
    local project_dir="$1"
    local mycnf_file="$HOME/.my.cnf"
    
    print_info "~/.my.cnf not found. Let's create it for secure MySQL authentication."
    print_info ""
    
    # Read .env configuration
    read_env_config "$project_dir"
    
    print_warning "This will create ~/.my.cnf with your database credentials and database name."
    print_info "The file will be secured with 600 permissions (readable only by you)."
    print_info ""
    print_info "Configuration to be written:"
    print_info "  Host: $DB_HOST"
    print_info "  Port: $DB_PORT"
    print_info "  Username: $DB_USERNAME"
    print_info "  Database: $DB_DATABASE"
    print_info "  Password: [hidden]"
    print_info ""
    
    # Ask for confirmation
    read -p "Create ~/.my.cnf with these settings? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Cancelled. You can run this script again to create ~/.my.cnf later."
        exit 0
    fi
    
    # Create backup if file exists
    if [[ -f "$mycnf_file" ]]; then
        cp "$mycnf_file" "$mycnf_file.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Existing ~/.my.cnf backed up"
    fi
    
    # Create the configuration file
    cat > "$mycnf_file" << EOF
[client]
host=$DB_HOST
port=$DB_PORT
user=$DB_USERNAME
password=$DB_PASSWORD

[mysql]
host=$DB_HOST
port=$DB_PORT
user=$DB_USERNAME
password=$DB_PASSWORD

[mysqldump]
host=$DB_HOST
port=$DB_PORT
user=$DB_USERNAME
password=$DB_PASSWORD

# Custom section for this script
[backup_script]
database=$DB_DATABASE
EOF
    
    # Secure the file
    chmod 600 "$mycnf_file"
    
    print_success "~/.my.cnf created successfully and secured"
    print_info "MySQL commands will now use these credentials and database automatically"
    print_info "You can now run this script without specifying -p (project directory)"
}

# Function to check MySQL configuration
check_mysql_config() {
    local project_dir="$1"
    local mycnf_file="$HOME/.my.cnf"
    
    if [[ -f "$mycnf_file" ]]; then
        print_info "Using existing ~/.my.cnf for MySQL authentication"
        return 0
    else
        print_warning "~/.my.cnf not found"
        
        if [[ -z "$project_dir" ]]; then
            print_error "~/.my.cnf not found and no project directory specified"
            print_error "To create ~/.my.cnf from .env file, use: $0 -p /path/to/project COMMAND"
            exit 1
        fi
        
        create_mysql_config "$project_dir"
    fi
}

# Function to get database name from ~/.my.cnf or .env
get_database_name() {
    local project_dir="$1"
    
    # First try to get database name from ~/.my.cnf
    if [[ -f "$HOME/.my.cnf" ]]; then
        DB_DATABASE=$(grep "^database=" "$HOME/.my.cnf" | cut -d'=' -f2)
        if [[ -n "$DB_DATABASE" ]]; then
            echo "$DB_DATABASE"
            return 0
        fi
    fi
    
    # Fallback to reading from .env file
    if [[ -n "$project_dir" && -f "$project_dir/.env" ]]; then
        DB_DATABASE=$(grep "^DB_DATABASE=" "$project_dir/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        if [[ -n "$DB_DATABASE" ]]; then
            echo "$DB_DATABASE"
            return 0
        fi
    fi
    
    # If we can't get database name from either source
    print_error "Cannot determine database name"
    if [[ ! -f "$HOME/.my.cnf" ]]; then
        print_error "~/.my.cnf not found and no project directory specified"
        print_error "Use: $0 -p /path/to/project COMMAND"
    else
        print_error "Database name not found in ~/.my.cnf"
        print_error "You may need to recreate ~/.my.cnf with: $0 -p /path/to/project COMMAND"
    fi
    exit 1
}

# Function to export database
export_database() {
    local backup_dir="$1"
    local project_dir="$2"
    
    # Check and setup MySQL configuration
    check_mysql_config "$project_dir"
    
    # Get database name
    DB_DATABASE=$(get_database_name "$project_dir")
    if [[ -z "$DB_DATABASE" ]]; then
        print_error "Could not determine database name"
        exit 1
    fi
    
    # Create backup directory if it doesn't exist
    mkdir -p "$backup_dir"
    
    # Generate timestamp
    DATETIME=$(date +'%Y%m%d_%H%M')
    BACKUP_FILE="${backup_dir}/${DB_DATABASE}_${DATETIME}.sql.gz"
    
    print_info "Starting database export..."
    print_info "Database: $DB_DATABASE"
    print_info "Backup file: $BACKUP_FILE"
    
    # Execute export (credentials come from ~/.my.cnf)
    if mysqldump --single-transaction --quick --no-tablespaces "$DB_DATABASE" | gzip > "$BACKUP_FILE"; then
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
    
    # Check and setup MySQL configuration
    check_mysql_config "$project_dir"
    
    # Get database name
    DB_DATABASE=$(get_database_name "$project_dir")
    if [[ -z "$DB_DATABASE" ]]; then
        print_error "Could not determine database name"
        exit 1
    fi
    
    print_info "Starting database import..."
    print_info "Database: $DB_DATABASE"
    print_info "Import file: $import_file"
    print_warning "This will overwrite the existing database: $DB_DATABASE"
    
    # Ask for confirmation
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Import cancelled"
        exit 0
    fi
    
    # Execute import (credentials come from ~/.my.cnf)
    if zcat "$import_file" | mysql "$DB_DATABASE"; then
        print_success "Database imported successfully from $import_file"
    else
        print_error "Database import failed"
        exit 1
    fi
}

# Parse command line arguments
PROJECT_DIR=""
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

# Set default project dir only if ~/.my.cnf doesn't exist
if [[ -z "$PROJECT_DIR" && ! -f "$HOME/.my.cnf" ]]; then
    PROJECT_DIR="$DEFAULT_PROJECT_DIR"
fi

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