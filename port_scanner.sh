#!/bin/bash

# Port Scanner Script
# Usage: ./port_scanner.sh <server_ip_or_hostname>

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if server address is provided
if [ $# -eq 0 ]; then
    print_error "Usage: $0 <server_ip_or_hostname>"
    print_info "Example: $0 192.168.1.100"
    print_info "Example: $0 myserver.com"
    exit 1
fi

SERVER=$1

# Check if nmap is installed
if ! command -v nmap &> /dev/null; then
    print_error "nmap is not installed. Please install it first:"
    echo "  Ubuntu/Debian: sudo apt update && sudo apt install nmap"
    echo "  CentOS/RHEL: sudo yum install nmap"
    echo "  macOS: brew install nmap"
    exit 1
fi

print_info "Scanning server: $SERVER"
echo "=================================="

# First, check if the server is reachable
print_info "Checking if server is reachable..."
if ping -c 1 -W 3 "$SERVER" &> /dev/null; then
    print_success "Server is reachable"
else
    print_warning "Server might not respond to ping (could be normal if ICMP is blocked)"
fi

echo ""

# Quick scan for common SSH ports first
print_info "Quick scan for common SSH ports (22, 222, 2222, 2200, 22222)..."
nmap -p 22,222,2222,2200,22222 "$SERVER" 2>/dev/null | grep -E "(open|filtered|closed)"

echo ""

# Scan top 1000 most common ports
print_info "Scanning top 1000 most common ports..."
print_warning "This may take a few minutes..."

NMAP_OUTPUT=$(nmap -T4 --top-ports 1000 "$SERVER" 2>/dev/null)

# Extract and display open ports
OPEN_PORTS=$(echo "$NMAP_OUTPUT" | grep "open" | awk '{print $1 " " $3}')

if [ -n "$OPEN_PORTS" ]; then
    print_success "Open ports found:"
    echo "$OPEN_PORTS" | while read -r port service; do
        if [[ $service == *"ssh"* ]]; then
            echo -e "  ${GREEN}$port${NC} - $service ${YELLOW}(Likely SSH!)${NC}"
        else
            echo "  $port - $service"
        fi
    done
else
    print_warning "No open ports found in the top 1000 common ports"
fi

echo ""

# Option for full port scan
read -p "Do you want to perform a full port scan (1-65535)? This will take much longer. (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Performing full port scan (1-65535)..."
    print_warning "This will take a significant amount of time..."
    
    FULL_SCAN_OUTPUT=$(nmap -p- -T4 "$SERVER" 2>/dev/null)
    FULL_OPEN_PORTS=$(echo "$FULL_SCAN_OUTPUT" | grep "open" | awk '{print $1 " " $3}')
    
    if [ -n "$FULL_OPEN_PORTS" ]; then
        print_success "All open ports found:"
        echo "$FULL_OPEN_PORTS" | while read -r port service; do
            if [[ $service == *"ssh"* ]]; then
                echo -e "  ${GREEN}$port${NC} - $service ${YELLOW}(SSH!)${NC}"
            else
                echo "  $port - $service"
            fi
        done
    else
        print_warning "No open ports found in full scan"
    fi
fi

echo ""
print_info "Scan completed!"

# Additional helpful information
echo ""
print_info "To test SSH connection on a specific port:"
echo "  ssh -p <port_number> username@$SERVER"
echo ""
print_info "To test if a specific port is open:"
echo "  nc -zv $SERVER <port_number>"
