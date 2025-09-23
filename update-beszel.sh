#!/bin/bash

# Beszel Hub Update Script
# This script automatically updates Beszel Hub, fixes permissions, and restarts the service
# Author: AI Assistant
# Version: 1.0

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to find Beszel binary location
find_beszel_binary() {
    log_info "Searching for Beszel binary..."
    
    # Common installation paths
    local common_paths=(
        "/opt/beszel/beszel"
        "/opt/beszel-hub/beszel"
        "/usr/local/bin/beszel"
        "/usr/bin/beszel"
        "$(which beszel 2>/dev/null || echo '')"
    )
    
    # Check systemd service for exact path
    if systemctl is-enabled beszel.service &>/dev/null; then
        local service_exec=$(systemctl cat beszel.service 2>/dev/null | grep -E "^ExecStart=" | head -1 | cut -d'=' -f2- | awk '{print $1}')
        if [[ -n "$service_exec" ]]; then
            common_paths=("$service_exec" "${common_paths[@]}")
        fi
    fi
    
    # Find binary using find command as backup
    local find_results
    mapfile -t find_results < <(sudo find /opt /usr -name "beszel" -type f -executable 2>/dev/null || true)
    common_paths+=("${find_results[@]}")
    
    # Test each path
    for path in "${common_paths[@]}"; do
        if [[ -n "$path" && -f "$path" ]]; then
            log_success "Found Beszel binary at: $path"
            echo "$path"
            return 0
        fi
    done
    
    log_error "Beszel binary not found!"
    return 1
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Function to backup current binary
backup_binary() {
    local binary_path="$1"
    local backup_path="${binary_path}.backup.$(date +%Y%m%d_%H%M%S)"
    
    log_info "Creating backup of current binary..."
    if cp "$binary_path" "$backup_path"; then
        log_success "Backup created: $backup_path"
    else
        log_warning "Failed to create backup, continuing anyway..."
    fi
}

# Function to update Beszel
update_beszel() {
    local binary_path="$1"
    
    log_info "Starting Beszel update..."
    
    # Run the update command
    if "$binary_path" update; then
        log_success "Beszel update completed successfully"
        return 0
    else
        log_error "Beszel update failed"
        return 1
    fi
}

# Function to fix permissions
fix_permissions() {
    local binary_path="$1"
    
    log_info "Fixing file permissions..."
    
    # Set executable permissions
    if chmod +x "$binary_path"; then
        log_success "Permissions fixed for $binary_path"
    else
        log_error "Failed to set permissions"
        return 1
    fi
    
    # Verify permissions
    if [[ -x "$binary_path" ]]; then
        log_success "Binary is now executable"
        ls -la "$binary_path"
    else
        log_error "Binary is still not executable"
        return 1
    fi
}

# Function to manage systemd service
manage_service() {
    local action="$1"
    local service_name="beszel.service"
    
    log_info "Attempting to $action $service_name..."
    
    # Check if service exists
    if ! systemctl list-unit-files | grep -q "^$service_name"; then
        log_warning "Service $service_name not found"
        return 1
    fi
    
    # Perform action
    case "$action" in
        "stop")
            systemctl stop "$service_name"
            ;;
        "start")
            systemctl start "$service_name"
            ;;
        "restart")
            systemctl restart "$service_name"
            ;;
        "reload")
            systemctl daemon-reload
            ;;
    esac
    
    if [[ $? -eq 0 ]]; then
        log_success "Service $action successful"
        return 0
    else
        log_error "Service $action failed"
        return 1
    fi
}

# Function to check service status
check_service_status() {
    local service_name="beszel.service"
    
    log_info "Checking service status..."
    
    if systemctl is-active --quiet "$service_name"; then
        log_success "Service is running"
        systemctl status "$service_name" --no-pager -l
    else
        log_error "Service is not running"
        log_info "Recent service logs:"
        journalctl -u "$service_name" --no-pager -l -n 10
        return 1
    fi
}

# Function to test binary functionality
test_binary() {
    local binary_path="$1"
    
    log_info "Testing binary functionality..."
    
    if "$binary_path" --version &>/dev/null; then
        log_success "Binary is functional"
        "$binary_path" --version
    else
        log_warning "Binary version check failed, but this might be normal"
    fi
}

# Main function
main() {
    log_info "Starting Beszel Hub update process..."
    echo "=================================================="
    
    # Check if running as root
    check_root
    
    # Find Beszel binary
    local binary_path
    binary_path=$(find_beszel_binary) || exit 1
    
    # Create backup
    backup_binary "$binary_path"
    
    # Stop service before update
    manage_service "stop" || log_warning "Could not stop service, continuing..."
    
    # Update Beszel
    if update_beszel "$binary_path"; then
        log_success "Update completed successfully"
    else
        log_error "Update failed, exiting..."
        exit 1
    fi
    
    # Fix permissions
    fix_permissions "$binary_path" || exit 1
    
    # Test binary
    test_binary "$binary_path"
    
    # Reload systemd and restart service
    manage_service "reload"
    manage_service "restart" || exit 1
    
    # Wait a moment for service to start
    sleep 2
    
    # Check final status
    if check_service_status; then
        echo "=================================================="
        log_success "Beszel Hub update completed successfully!"
        log_info "Web UI should be accessible again"
        echo "=================================================="
    else
        echo "=================================================="
        log_error "Update completed but service is not running properly"
        log_info "Check the logs above for troubleshooting"
        echo "=================================================="
        exit 1
    fi
}

# Help function
show_help() {
    echo "Beszel Hub Update Script"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help     Show this help message"
    echo "  -v, --verbose  Enable verbose output (set -x)"
    echo ""
    echo "This script will:"
    echo "  1. Find the Beszel binary location"
    echo "  2. Create a backup of the current binary"
    echo "  3. Update Beszel using the built-in update command"
    echo "  4. Fix file permissions (chmod +x)"
    echo "  5. Restart the systemd service"
    echo "  6. Verify the service is running"
    echo ""
    echo "Requirements:"
    echo "  - Must be run as root or with sudo"
    echo "  - Beszel must be installed as native binary (not Docker)"
    echo "  - systemd service 'beszel.service' should exist"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--verbose)
            set -x
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Run main function
main
