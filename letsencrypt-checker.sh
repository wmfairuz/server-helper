#!/bin/bash

# Let's Encrypt Certificate Script
# Lists all certificates with expiration dates and renewal methods
#
# Email Configuration:
# - Default email: fairuz@nazsoftech.com
# - Override methods:
#   1. Environment variable: export LETSENCRYPT_EMAIL="your@email.com"
#   2. Interactive prompt during renewal
#
# Usage:
#   ./letsencrypt-checker.sh                    # Use default email
#   LETSENCRYPT_EMAIL="me@domain.com" ./letsencrypt-checker.sh  # Override via env var

# Configuration - Email for Let's Encrypt registration
DEFAULT_EMAIL="fairuz@nazsoftech.com"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$DEFAULT_EMAIL}"

# You can override the email by:
# 1. Setting environment variable: export LETSENCRYPT_EMAIL="your@email.com"
# 2. Or it will be prompted during interactive renewal

echo "=== Let's Encrypt Certificates ==="
echo "Using email: $LETSENCRYPT_EMAIL (override with LETSENCRYPT_EMAIL env var)"
echo

# Function to get certificate info
get_cert_info() {
    local cert_file="$1"
    local domain=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p')
    local expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
    local current_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    if [ $days_left -lt 0 ]; then
        local status="EXPIRED"
        local sort_key="0$(printf "%010d" $((0 - days_left)))"
    else
        local status="VALID"
        local sort_key="1$(printf "%010d" $days_left)"
    fi
    
    echo "$sort_key|$domain|$expiry|$days_left|$status"
}

# Function to detect renewal method
get_renewal_method() {
    local domain="$1"
    
    # Check if certbot renewal config exists
    if [ -f "/etc/letsencrypt/renewal/${domain}.conf" ]; then
        local authenticator=$(grep "authenticator" "/etc/letsencrypt/renewal/${domain}.conf" 2>/dev/null | cut -d= -f2 | tr -d ' ')
        case "$authenticator" in
            "webroot") echo "Certbot (Webroot)" ;;
            "nginx") echo "Certbot (Nginx)" ;;
            "apache") echo "Certbot (Apache)" ;;
            "standalone") echo "Certbot (Standalone)" ;;
            "dns-"*) echo "Certbot (DNS)" ;;
            *) echo "Certbot (${authenticator:-Unknown})" ;;
        esac
    elif [ -f "/etc/letsencrypt/live/${domain}/cert.pem" ]; then
        echo "Manual/Other"
    else
        echo "Unknown"
    fi
}

# Temporary file to store results
TEMP_FILE=$(mktemp)

# Method 1: Use certbot if available
if command -v certbot >/dev/null 2>&1; then
    echo "Scanning with certbot..."
    certbot certificates 2>/dev/null | grep -E "Certificate Name:|Domains:|Expiry Date:" | \
    while read line; do
        if [[ $line =~ Certificate\ Name:\ (.+) ]]; then
            cert_name="${BASH_REMATCH[1]}"
        elif [[ $line =~ Domains:\ (.+) ]]; then
            domains="${BASH_REMATCH[1]}"
            primary_domain=$(echo "$domains" | cut -d' ' -f1)
        elif [[ $line =~ Expiry\ Date:\ (.+) ]]; then
            expiry_date="${BASH_REMATCH[1]}"
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
            current_epoch=$(date +%s)
            days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
            
            if [ $days_left -lt 0 ]; then
                status="EXPIRED"
                sort_key="0$(printf "%010d" $((0 - days_left)))"
            else
                status="VALID"
                sort_key="1$(printf "%010d" $days_left)"
            fi
            
            renewal_method=$(get_renewal_method "$cert_name")
            
            echo "$sort_key|$cert_name|$primary_domain|$expiry_date|$days_left|$status|$renewal_method" >> "$TEMP_FILE"
        fi
    done
fi

# Method 2: Scan certificate files directly
if [ -d "/etc/letsencrypt/live" ]; then
    echo "Scanning certificate files..."
    for cert_dir in /etc/letsencrypt/live/*/; do
        if [ -d "$cert_dir" ] && [ -f "${cert_dir}cert.pem" ]; then
            cert_name=$(basename "$cert_dir")
            cert_file="${cert_dir}cert.pem"
            
            # Skip if already processed by certbot
            if ! grep -q "|$cert_name|" "$TEMP_FILE" 2>/dev/null; then
                domain=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p')
                expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
                expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                current_epoch=$(date +%s)
                days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
                
                if [ $days_left -lt 0 ]; then
                    status="EXPIRED"
                    sort_key="0$(printf "%010d" $((0 - days_left)))"
                else
                    status="VALID"
                    sort_key="1$(printf "%010d" $days_left)"
                fi
                
                renewal_method=$(get_renewal_method "$cert_name")
                
                echo "$sort_key|$cert_name|$domain|$expiry|$days_left|$status|$renewal_method" >> "$TEMP_FILE"
            fi
        fi
    done
fi

# Display results in table format
if [ -s "$TEMP_FILE" ]; then
    echo
    printf "%-25s %-30s %-25s %-12s %-8s %-20s\n" "CERTIFICATE" "DOMAIN" "EXPIRES" "DAYS LEFT" "STATUS" "RENEWAL METHOD"
    printf "%-25s %-30s %-25s %-12s %-8s %-20s\n" "=========================" "==============================" "=========================" "============" "========" "===================="
    
    # Sort by expiration (expired first, then by days left)
    sort -t'|' -k1,1 "$TEMP_FILE" | while IFS='|' read -r sort_key cert_name domain expiry days_left status renewal_method; do
        # Color coding
        if [ "$status" = "EXPIRED" ]; then
            printf "\033[31m%-25s %-30s %-25s %-12s %-8s %-20s\033[0m\n" \
                "${cert_name:0:24}" "${domain:0:29}" "${expiry:0:24}" "$days_left" "$status" "${renewal_method:0:19}"
        elif [ "$days_left" -lt 30 ]; then
            printf "\033[33m%-25s %-30s %-25s %-12s %-8s %-20s\033[0m\n" \
                "${cert_name:0:24}" "${domain:0:29}" "${expiry:0:24}" "$days_left" "$status" "${renewal_method:0:19}"
        else
            printf "%-25s %-30s %-25s %-12s %-8s %-20s\n" \
                "${cert_name:0:24}" "${domain:0:29}" "${expiry:0:24}" "$days_left" "$status" "${renewal_method:0:19}"
        fi
    done
    
    echo
    echo "Legend: \033[31mRed = Expired\033[0m, \033[33mYellow = Expires in <30 days\033[0m"
else
    echo "No Let's Encrypt certificates found."
fi

# Interactive renewal option
echo
read -p "Do you want to renew a specific certificate? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    echo "=== Select Certificate to Renew ==="
    
    # Create temporary files for certificate data
    CERT_MENU=$(mktemp)
    CERT_DATA=$(mktemp)
    
    # Generate numbered list and store certificate data
    counter=1
    sort -t'|' -k1,1 "$TEMP_FILE" | while IFS='|' read -r sort_key cert_name domain expiry days_left status renewal_method; do
        printf "%2d. %-25s %-30s %-8s\n" $counter "${cert_name:0:24}" "${domain:0:29}" "$status" >> "$CERT_MENU"
        echo "$counter|$cert_name|$domain" >> "$CERT_DATA"
        counter=$((counter + 1))
    done
    
    # Display menu
    if [ -s "$CERT_MENU" ]; then
        cat "$CERT_MENU"
        echo
        
        total_certs=$(wc -l < "$CERT_DATA")
        read -p "Enter certificate number (1-$total_certs): " cert_choice
        
        if [[ "$cert_choice" =~ ^[0-9]+$ ]] && [ "$cert_choice" -ge 1 ] && [ "$cert_choice" -le $total_certs ]; then
            # Get selected certificate info
            selected_line=$(sed -n "${cert_choice}p" "$CERT_DATA")
            selected_cert=$(echo "$selected_line" | cut -d'|' -f2)
            selected_domain=$(echo "$selected_line" | cut -d'|' -f3)
            
            echo
            echo "Selected: $selected_cert ($selected_domain)"
            echo
            
            # Email configuration
            current_email="$LETSENCRYPT_EMAIL"
            echo "Current email for Let's Encrypt: $current_email"
            read -p "Use different email? (press Enter to keep current, or type new email): " new_email
            
            if [ -n "$new_email" ]; then
                current_email="$new_email"
                echo "Using email: $current_email"
            fi
            echo
            
            # Handle wildcard domains - ask user for preference
            if [[ "$selected_domain" == "*."* ]]; then
                echo "Detected potential wildcard domain: $selected_domain"
                echo "1. Use as-is: $selected_domain"
                echo "2. Use wildcard format: *.${selected_domain#*.}"
                read -p "Choose format (1-2): " domain_choice
                
                if [ "$domain_choice" = "2" ]; then
                    selected_domain="*.${selected_domain#*.}"
                fi
                echo
            fi
            
            # Your custom renewal command with configurable email
            renewal_cmd="certbot certonly --manual --preferred-challenges=dns --server https://acme-v02.api.letsencrypt.org/directory --agree-tos --email $current_email -d $selected_domain"
            
            echo
            echo "=== Renewal Command ==="
            echo "$renewal_cmd"
            echo
            
            read -p "Execute this command now? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Executing renewal command..."
                echo "----------------------------------------"
                
                # Execute the renewal command and capture exit status
                eval "$renewal_cmd"
                renewal_status=$?
                
                echo "----------------------------------------"
                
                if [ $renewal_status -eq 0 ]; then
                    echo "✅ Certificate renewal completed successfully!"
                    
                    # Detect and offer to reload web servers
                    webservers=()
                    
                    # Check for nginx
                    if systemctl is-active --quiet nginx 2>/dev/null; then
                        webservers+=("nginx")
                    elif service nginx status >/dev/null 2>&1; then
                        webservers+=("nginx")
                    fi
                    
                    # Check for apache
                    if systemctl is-active --quiet apache2 2>/dev/null; then
                        webservers+=("apache2")
                    elif systemctl is-active --quiet httpd 2>/dev/null; then
                        webservers+=("httpd")
                    elif service apache2 status >/dev/null 2>&1; then
                        webservers+=("apache2")
                    elif service httpd status >/dev/null 2>&1; then
                        webservers+=("httpd")
                    fi
                    
                    if [ ${#webservers[@]} -gt 0 ]; then
                        echo
                        echo "🔄 Detected running web server(s): ${webservers[*]}"
                        read -p "Reload web server(s) to apply new certificate? (y/n): " -n 1 -r
                        echo
                        
                        if [[ $REPLY =~ ^[Yy]$ ]]; then
                            echo "Reloading web server(s)..."
                            
                            for server in "${webservers[@]}"; do
                                echo "Reloading $server..."
                                
                                # Try systemctl first, then service command
                                if command -v systemctl >/dev/null 2>&1; then
                                    if systemctl reload "$server" 2>/dev/null; then
                                        echo "✅ $server reloaded successfully"
                                    elif systemctl restart "$server" 2>/dev/null; then
                                        echo "✅ $server restarted successfully (reload not supported)"
                                    else
                                        echo "❌ Failed to reload $server with systemctl"
                                    fi
                                else
                                    if service "$server" reload 2>/dev/null; then
                                        echo "✅ $server reloaded successfully"
                                    elif service "$server" restart 2>/dev/null; then
                                        echo "✅ $server restarted successfully (reload not supported)"
                                    else
                                        echo "❌ Failed to reload $server with service command"
                                    fi
                                fi
                            done
                            
                            echo
                            echo "🎉 Certificate renewal and web server reload completed!"
                        else
                            echo "Skipped web server reload. Remember to reload manually:"
                            for server in "${webservers[@]}"; do
                                echo "  sudo systemctl reload $server"
                            done
                        fi
                    else
                        echo "ℹ️  No running web servers detected. Certificate renewed successfully."
                    fi
                else
                    echo "❌ Certificate renewal failed (exit code: $renewal_status)"
                    echo "Please check the error messages above."
                fi
            else
                echo "Command ready to copy/paste when needed."
            fi
        else
            echo "Invalid selection."
        fi
    else
        echo "No certificates found to renew."
    fi
    
    # Cleanup temp files
    rm -f "$CERT_MENU" "$CERT_DATA"
fi

# Cleanup
rm -f "$TEMP_FILE"

echo
echo "=== Manual Renewal Commands ==="
echo "• Your custom command template:"
echo "  certbot certonly --manual --preferred-challenges=dns --server https://acme-v02.api.letsencrypt.org/directory --agree-tos --email $LETSENCRYPT_EMAIL -d DOMAIN"
echo "  (Email can be overridden with: export LETSENCRYPT_EMAIL=\"your@email.com\")"
echo
echo "• Standard renewal commands:"
echo "  - Auto-renewal check: certbot renew --dry-run"
echo "  - Force renewal: certbot renew --force-renewal"
echo "  - Renew specific cert: certbot renew --cert-name CERT_NAME"
echo
echo "• Web server reload commands (after renewal):"
echo "  - Nginx: sudo systemctl reload nginx"
echo "  - Apache: sudo systemctl reload apache2  (or httpd)"
echo "  - Test nginx config: sudo nginx -t"
echo "  - Test apache config: sudo apache2ctl configtest  (or httpd -t)"