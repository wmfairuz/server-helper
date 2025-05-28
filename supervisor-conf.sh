#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 <project_name>"
    echo "Example: $0 myproject"
    echo ""
    echo "This script creates a supervisor configuration file for Laravel queue workers"
    echo "based on the provided project name."
    exit 1
}

# Check if project name is provided
if [ $# -eq 0 ]; then
    echo "Error: Project name is required"
    usage
fi

PROJECT_NAME="$1"
CONF_FILE="${PROJECT_NAME}.conf"

# Validate project name (basic validation)
if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Project name should only contain letters, numbers, underscores, and hyphens"
    exit 1
fi

# Check if conf file already exists
if [ -f "$CONF_FILE" ]; then
    read -p "File $CONF_FILE already exists. Overwrite? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
fi

# Create the supervisor configuration file
cat > "$CONF_FILE" << EOF
[program:${PROJECT_NAME}-worker]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php8.1 /opt/www/${PROJECT_NAME}/artisan queue:work --sleep=3 --tries=3
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=/opt/www/${PROJECT_NAME}/storage/logs/worker.log
stopwaitsecs=3600
EOF

# Check if file was created successfully
if [ -f "$CONF_FILE" ]; then
    echo "Successfully created supervisor configuration file: $CONF_FILE"
    echo ""
    echo "Generated configuration:"
    echo "------------------------"
    cat "$CONF_FILE"
    echo "------------------------"
    echo ""
    
    # Ask if user wants to automatically deploy the configuration
    read -p "Do you want to automatically deploy this configuration to supervisor? (y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deploying configuration to supervisor..."
        
        # Copy configuration file to supervisor directory
        echo "1. Copying $CONF_FILE to /etc/supervisor/conf.d/"
        if sudo cp "$CONF_FILE" /etc/supervisor/conf.d/; then
            echo "   ✓ Configuration file copied successfully"
        else
            echo "   ✗ Failed to copy configuration file"
            exit 1
        fi
        
        # Reread supervisor configuration
        echo "2. Running supervisorctl reread..."
        if sudo supervisorctl reread; then
            echo "   ✓ Configuration reread successfully"
        else
            echo "   ✗ Failed to reread configuration"
            exit 1
        fi
        
        # Update supervisor with new configuration
        echo "3. Running supervisorctl update..."
        if sudo supervisorctl update; then
            echo "   ✓ Configuration updated successfully"
        else
            echo "   ✗ Failed to update configuration"
            exit 1
        fi
        
        # Start the worker processes
        echo "4. Starting ${PROJECT_NAME}-worker processes..."
        if sudo supervisorctl start "${PROJECT_NAME}-worker:*"; then
            echo "   ✓ Worker processes started successfully"
        else
            echo "   ✗ Failed to start worker processes"
            exit 1
        fi
        
        echo ""
        echo "🎉 Supervisor configuration deployed and worker started successfully!"
        echo ""
        echo "You can check the status with:"
        echo "   sudo supervisorctl status ${PROJECT_NAME}-worker:*"
        echo ""
        echo "You can view logs with:"
        echo "   tail -f /opt/www/${PROJECT_NAME}/storage/logs/worker.log"
        
    else
        echo "Configuration file created but not deployed."
        echo "To deploy manually, run:"
        echo "1. sudo cp $CONF_FILE /etc/supervisor/conf.d/"
        echo "2. sudo supervisorctl reread"
        echo "3. sudo supervisorctl update"
        echo "4. sudo supervisorctl start ${PROJECT_NAME}-worker:*"
    fi
    
else
    echo "Error: Failed to create configuration file"
    exit 1
fi
