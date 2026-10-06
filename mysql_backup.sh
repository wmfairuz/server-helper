#!/bin/bash

# MySQL Database Export/Import Script
#
# Credentials live in a dedicated option file per database,
# ~/.mysql-backup/<database>.cnf (mode 600), created from a Laravel .env with -p.
# Every mysql/mysqldump call reads ONLY that file (--defaults-file), so a
# ~/.my.cnf belonging to another app can never override it.

set -euo pipefail

# Default paths
DEFAULT_BACKUP_DIR="$HOME/backups/mysql"
CNF_DIR="$HOME/.mysql-backup"
LEGACY_CNF="$HOME/.my.cnf"

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
    echo "  export                   Export database to a compressed file"
    echo "  import FILE              Import database from a compressed file"
    echo ""
    echo "OPTIONS:"
    echo "  -p, --project-dir DIR    Laravel project whose .env holds the credentials."
    echo "                           Writes/refreshes ~/.mysql-backup/<database>.cnf"
    echo "  -d, --database NAME      Use the saved credentials for this database"
    echo "                           (needed only when more than one is saved)"
    echo "  -b, --backup-dir DIR     Backup directory (default: $DEFAULT_BACKUP_DIR)"
    echo "  -y, --yes                Do not ask for confirmation (for cron)"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  # First time (saves credentials from .env):"
    echo "  $0 -p /opt/www/vetpn9 export"
    echo ""
    echo "  # Afterwards (one saved database: no options needed):"
    echo "  $0 export"
    echo "  $0 import ~/backups/mysql/vetpn9_staging_20250609_1022+08.sql.gz"
    echo ""
    echo "  # Several apps on one server:"
    echo "  $0 -d vetpn9_staging export"
}

# Read one key from a .env file the way Laravel (phpdotenv) does: last
# definition wins, surrounding quotes removed (not quotes inside the value),
# \" and \\ unescaped in double-quoted values, inline " #" comments dropped
# from unquoted values, Windows line endings tolerated.
env_get() {
    local key="$1" file="$2" line val
    line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" | tail -n 1 || true)
    [[ -z "$line" ]] && return 0
    val="${line#*=}"
    val="${val%$'\r'}"
    val="${val#"${val%%[![:space:]]*}"}"   # trim leading whitespace
    val="${val%"${val##*[![:space:]]}"}"   # trim trailing whitespace
    if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then
        val="${val:1:${#val}-2}"
        val="${val//\\\\/$'\x01'}"
        val="${val//\\\"/\"}"
        val="${val//$'\x01'/\\}"
    elif [[ ${#val} -ge 2 && "$val" == \'*\' ]]; then
        val="${val:1:${#val}-2}"
    else
        val="${val%%[[:space:]]#*}"
    fi
    printf '%s' "$val"
}

# Quote a value for a MySQL option file. Unquoted, a "#" starts a comment and
# backslashes are escape sequences, so passwords containing either get cut
# short or changed. Inside double quotes only the backslash needs escaping.
cnf_quote() {
    local v="$1"
    v="${v//\\/\\\\}"
    printf '"%s"' "$v"
}

# Database names become file names, so keep them to the usual characters.
valid_db_name() {
    [[ "$1" =~ ^[A-Za-z0-9_\$-]+$ ]]
}

# Read "database=" from the [backup_script] section only.
cnf_database() {
    awk '/^[[:space:]]*\[/ { in_section = ($0 ~ /^[[:space:]]*\[backup_script\]/) }
         in_section && /^[[:space:]]*database[[:space:]]*=/ {
             sub(/^[^=]*=[[:space:]]*/, ""); print; exit
         }' "$1"
}

# Write ~/.mysql-backup/<database>.cnf from the project's .env.
write_cnf_from_env() {
    local project_dir="$1"
    local env_file="$project_dir/.env"

    if [[ ! -f "$env_file" ]]; then
        print_error ".env file not found at $env_file"
        exit 1
    fi

    print_info "Reading database configuration from $env_file"

    local host port database username password
    host=$(env_get DB_HOST "$env_file")
    port=$(env_get DB_PORT "$env_file")
    database=$(env_get DB_DATABASE "$env_file")
    username=$(env_get DB_USERNAME "$env_file")
    password=$(env_get DB_PASSWORD "$env_file")
    port="${port:-3306}"

    if [[ -z "$host" || -z "$database" || -z "$username" ]]; then
        print_error "Missing database configuration in $env_file"
        print_error "Required: DB_HOST, DB_DATABASE, DB_USERNAME (DB_PORT defaults to 3306)"
        exit 1
    fi
    if [[ -z "$password" ]]; then
        print_error "DB_PASSWORD is empty in $env_file"
        exit 1
    fi
    if ! valid_db_name "$database"; then
        print_error "Unsupported characters in database name: $database"
        exit 1
    fi

    local cnf="$CNF_DIR/$database.cnf" tmp
    (
        umask 077
        mkdir -p "$CNF_DIR"
        chmod 700 "$CNF_DIR"
        tmp=$(mktemp "$CNF_DIR/.tmp.XXXXXX")
        {
            echo "[client]"
            echo "host=$host"
            echo "port=$port"
            echo "user=$(cnf_quote "$username")"
            echo "password=$(cnf_quote "$password")"
            echo ""
            echo "# Read by mysql_backup.sh only; MySQL clients ignore this group"
            echo "[backup_script]"
            echo "database=$database"
        } > "$tmp"
        mv "$tmp" "$cnf"
    )

    print_info "Saved credentials to $cnf (readable only by you)"
    print_info "  Host: $host:$port  Database: $database  Username: $username"

    CNF_FILE="$cnf"
    DB_DATABASE="$database"
}

# Decide which option file to use and which database it is for.
# Sets CNF_FILE and DB_DATABASE.
resolve_credentials() {
    local project_dir="$1" db_arg="$2"

    # 1. A project directory always wins: its .env is the source of truth.
    if [[ -n "$project_dir" ]]; then
        write_cnf_from_env "$project_dir"
        return 0
    fi

    # 2. An explicitly named database.
    if [[ -n "$db_arg" ]]; then
        if ! valid_db_name "$db_arg" || [[ ! -f "$CNF_DIR/$db_arg.cnf" ]]; then
            print_error "No saved credentials for database '$db_arg'"
            print_error "Create them with: $0 -p /path/to/project COMMAND"
            exit 1
        fi
        CNF_FILE="$CNF_DIR/$db_arg.cnf"
        DB_DATABASE="$db_arg"
        return 0
    fi

    # 3. Exactly one saved database: use it.
    local saved=()
    if [[ -d "$CNF_DIR" ]]; then
        shopt -s nullglob
        saved=("$CNF_DIR"/*.cnf)
        shopt -u nullglob
    fi
    if [[ ${#saved[@]} -eq 1 ]]; then
        CNF_FILE="${saved[0]}"
        DB_DATABASE=$(cnf_database "$CNF_FILE")
        print_info "Using saved credentials: $CNF_FILE"
        return 0
    fi
    if [[ ${#saved[@]} -gt 1 ]]; then
        print_error "Several databases are saved; choose one with -d:"
        local f
        for f in "${saved[@]}"; do
            print_error "  -d $(basename "$f" .cnf)"
        done
        exit 1
    fi

    # 4. Legacy setup: ~/.my.cnf written by an older version of this script.
    if [[ -f "$LEGACY_CNF" ]] && grep -q '^\[backup_script\]' "$LEGACY_CNF"; then
        CNF_FILE="$LEGACY_CNF"
        DB_DATABASE=$(cnf_database "$CNF_FILE")
        print_warning "Using legacy ~/.my.cnf. Re-run once with -p to move to ~/.mysql-backup/."
        return 0
    fi

    # 5. Run from inside a Laravel project.
    if [[ -f "./.env" ]]; then
        write_cnf_from_env "."
        return 0
    fi

    print_error "No saved credentials found"
    print_error "Create them with: $0 -p /path/to/project COMMAND"
    exit 1
}

confirm() {
    [[ "$ASSUME_YES" == "true" ]] && return 0
    local reply
    read -r -p "$1 (y/N): " -n 1 reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]]
}

# One pass over the file checks both that the gzip stream is intact (pipefail
# surfaces a gzip error) and that it ends with "-- Dump completed", which
# mysqldump/mariadb-dump write only after every table has been dumped.
dump_is_complete() {
    local last
    if ! last=$(gzip -dc "$1" 2>/dev/null | tail -n 1); then
        return 1
    fi
    [[ "$last" == "-- Dump completed"* ]]
}

# Function to export database
export_database() {
    local backup_dir="$1"

    resolve_credentials "$PROJECT_DIR" "$DB_ARG"
    if [[ -z "$DB_DATABASE" ]]; then
        print_error "Could not determine database name from $CNF_FILE"
        exit 1
    fi

    # Options that only some mysqldump builds accept. Help text is captured
    # first: piping it into "grep -q" would trip pipefail via SIGPIPE.
    local help
    help=$(mysqldump --help 2>/dev/null || true)
    local opts=(
        --single-transaction   # consistent snapshot, no table locks (InnoDB)
        --quick                # stream rows instead of buffering tables
        --no-tablespaces       # avoids needing the PROCESS privilege
        --routines --events --triggers
        --hex-blob             # binary columns survive intact
        --default-character-set=utf8mb4
    )
    [[ "$help" == *--set-gtid-purged* ]] && opts+=(--set-gtid-purged=OFF)
    [[ "$help" == *--column-statistics* ]] && opts+=(--column-statistics=0)

    (umask 077; mkdir -p "$backup_dir")

    local datetime backup_file
    datetime=$(date +'%Y%m%d_%H%M%Z')
    backup_file="${backup_dir}/${DB_DATABASE}_${datetime}.sql.gz"
    PART_FILE="${backup_file}.part"   # global: the EXIT trap outlives this function

    print_info "Starting database export..."
    print_info "Database: $DB_DATABASE"
    print_info "Backup file: $backup_file"

    # Write to .part and rename only when complete, so a failed or interrupted
    # export never leaves a file that looks like a good backup.
    trap 'rm -f "$PART_FILE"' EXIT
    if ! (umask 077; mysqldump --defaults-file="$CNF_FILE" "${opts[@]}" "$DB_DATABASE" | gzip > "$PART_FILE"); then
        print_error "Database export failed (see the mysqldump error above)"
        exit 1
    fi
    if ! dump_is_complete "$PART_FILE"; then
        print_error "Export is incomplete: no '-- Dump completed' line at the end"
        exit 1
    fi
    mv "$PART_FILE" "$backup_file"
    trap - EXIT

    print_success "Database exported successfully to $backup_file"
    print_info "Backup file size: $(du -h "$backup_file" | cut -f1)"
}

# Function to import database
import_database() {
    local import_file="$1"

    if [[ ! -f "$import_file" ]]; then
        print_error "Import file not found: $import_file"
        exit 1
    fi

    resolve_credentials "$PROJECT_DIR" "$DB_ARG"
    if [[ -z "$DB_DATABASE" ]]; then
        print_error "Could not determine database name from $CNF_FILE"
        exit 1
    fi

    # Check the file before touching the database: a corrupt or truncated dump
    # would otherwise be half-applied.
    print_info "Checking $import_file..."
    if ! dump_is_complete "$import_file"; then
        print_error "Dump is corrupt or incomplete (bad gzip data, or no '-- Dump completed' line)"
        exit 1
    fi

    print_info "Starting database import..."
    print_info "Database: $DB_DATABASE"
    print_info "Import file: $import_file"
    print_warning "Tables in the dump will replace the same tables in $DB_DATABASE."
    print_warning "Tables that exist only in $DB_DATABASE are left as they are."

    if ! confirm "Are you sure you want to continue?"; then
        print_info "Import cancelled"
        exit 0
    fi

    if gzip -dc "$import_file" | mysql --defaults-file="$CNF_FILE" "$DB_DATABASE"; then
        print_success "Database imported successfully from $import_file"
    else
        print_error "Database import failed (see the mysql error above)"
        exit 1
    fi
}

# Parse command line arguments
PROJECT_DIR=""
DB_ARG=""
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
ASSUME_YES="false"
COMMAND=""
IMPORT_FILE=""
CNF_FILE=""
DB_DATABASE=""
PART_FILE=""

require_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        print_error "Option $1 needs a value"
        show_usage
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project-dir)
            require_value "$@"
            PROJECT_DIR="$2"
            shift 2
            ;;
        -d|--database)
            require_value "$@"
            DB_ARG="$2"
            shift 2
            ;;
        -b|--backup-dir)
            require_value "$@"
            BACKUP_DIR="$2"
            shift 2
            ;;
        -y|--yes)
            ASSUME_YES="true"
            shift
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
            if [[ $# -lt 2 || -z "$2" ]]; then
                print_error "Import file not specified"
                show_usage
                exit 1
            fi
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
        export_database "$BACKUP_DIR"
        ;;
    import)
        import_database "$IMPORT_FILE"
        ;;
esac
