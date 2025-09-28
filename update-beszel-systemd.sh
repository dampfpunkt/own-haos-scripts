#!/bin/bash

# Beszel Hub Update Script - ENHANCED VERSION
# This script automatically updates Beszel Hub, fixes permissions, and manages systemd service
# Author: AI Assistant  
# Version: 1.2 - Added automatic systemd service creation

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
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
    )
    
    # Check systemd service for exact path
    if systemctl is-enabled beszel.service &>/dev/null; then
        local service_exec=$(systemctl cat beszel.service 2>/dev/null | grep -E "^ExecStart=" | head -1 | cut -d'=' -f2- | awk '{print $1}' || echo '')
        if [[ -n "$service_exec" && ! " ${common_paths[@]} " =~ " ${service_exec} " ]]; then
            common_paths=("$service_exec" "${common_paths[@]}")
        fi
    fi
    
    # Add which result if available
    local which_result=$(which beszel 2>/dev/null || echo '')
    if [[ -n "$which_result" && ! " ${common_paths[@]} " =~ " ${which_result} " ]]; then
        common_paths+=("$which_result")
    fi
    
    # Find binary using find command as backup
    log_info "Scanning system directories for Beszel binary..."
    local find_results
    mapfile -t find_results < <(find /opt /usr/local /usr /home -name "beszel" -type f -executable 2>/dev/null || true)
    
    # Add find results to paths
    for result in "${find_results[@]}"; do
        if [[ ! " ${common_paths[@]} " =~ " ${result} " ]]; then
            common_paths+=("$result")
        fi
    done
    
    log_info "Testing ${#common_paths[@]} potential paths..."
    
    # Test each path
    for path in "${common_paths[@]}"; do
        if [[ -n "$path" && -f "$path" && -x "$path" ]]; then
            log_success "Found executable Beszel binary at: $path"
            echo "$path"  # This is the return value
            return 0
        elif [[ -n "$path" && -f "$path" ]]; then
            log_warning "Found non-executable Beszel binary at: $path"
            echo "$path"  # Return it anyway, we can fix permissions
            return 0
        fi
    done
    
    log_error "No Beszel binary found in any of the searched locations"
    return 1
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Function to create systemd service
create_systemd_service() {
    local binary_path="$1"
    local service_file="/etc/systemd/system/beszel.service"
    
    log_info "Creating systemd service for Beszel..."
    
    # Detect current running configuration
    local current_args=""
    local working_dir=$(dirname "$binary_path")
    
    # Try to detect current arguments from running process
    local running_proc=$(ps aux | grep -E '[b]eszel.*serve' | head -1 || echo '')
    if [[ -n "$running_proc" ]]; then
        current_args=$(echo "$running_proc" | sed 's/.*beszel//' | xargs)
        log_info "Detected current arguments: $current_args"
    else
        # Default arguments
        current_args="serve --http 0.0.0.0:8090"
        log_info "Using default arguments: $current_args"
    fi
    
    # Create the service file
    cat > "$service_file" << SERVICEEOF
[Unit]
Description=Beszel Hub - Lightweight Server Monitoring
Documentation=https://beszel.dev
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=3
User=root
Group=root
WorkingDirectory=$working_dir
ExecStart=$binary_path $current_args
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
TimeoutStopSec=5
PrivateTmp=false

# Security settings
NoNewPrivileges=false
ProtectSystem=false
ProtectHome=false

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=beszel

[Install]
WantedBy=multi-user.target
SERVICEEOF
    
    if [[ -f "$service_file" ]]; then
        log_success "Systemd service created: $service_file"
        return 0
    else
        log_error "Failed to create systemd service file"
        return 1
    fi
}

# Function to backup current binary
backup_binary() {
    local binary_path="$1"
    local backup_path="${binary_path}.backup.$(date +%Y%m%d_%H%M%S)"
    
    log_info "Creating backup of current binary..."
    if cp "$binary_path" "$backup_path" 2>/dev/null; then
        log_success "Backup created: $backup_path"
    else
        log_warning "Failed to create backup, continuing anyway..."
    fi
}

# Function to update Beszel
update_beszel() {
    local binary_path="$1"
    
    log_info "Starting Beszel update..."
    log_info "Using binary: $binary_path"
    
    # Ensure binary is executable first
    chmod +x "$binary_path" 2>/dev/null || true
    
    # Run the update command
    if "$binary_path" update 2>&1; then
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
    
    # Set proper ownership if needed
    if chown root:root "$binary_path" 2>/dev/null; then
        log_info "Ownership set to root:root"
    fi
    
    # Verify permissions
    if [[ -x "$binary_path" ]]; then
        log_success "Binary is now executable"
        ls -la "$binary_path" >&2
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
    
    # Perform action
    local success=true
    case "$action" in
        "stop")
            systemctl stop "$service_name" || success=false
            ;;
        "start")
            systemctl start "$service_name" || success=false
            ;;
        "restart")
            systemctl restart "$service_name" || success=false
            ;;
        "reload")
            systemctl daemon-reload || success=false
            ;;
        "enable")
            systemctl enable "$service_name" || success=false
            ;;
    esac
    
    if $success; then
        log_success "Service $action successful"
        return 0
    else
        log_error "Service $action failed"
        return 1
    fi
}

# Function to stop running Beszel processes
stop_running_processes() {
    log_info "Stopping running Beszel processes..."
    
    # Find running Beszel hub processes (not agent)
    local beszel_pids=$(pgrep -f "beszel.*serve" || true)
    
    if [[ -n "$beszel_pids" ]]; then
        log_info "Found running Beszel hub processes: $beszel_pids"
        for pid in $beszel_pids; do
            log_info "Stopping process $pid..."
            if kill "$pid" 2>/dev/null; then
                log_success "Process $pid stopped"
            else
                log_warning "Could not stop process $pid"
            fi
        done
        
        # Wait a moment for processes to stop
        sleep 2
        log_success "All Beszel hub processes stopped"
    else
        log_info "No running Beszel hub processes found"
    fi
}

# Function to check service status
check_service_status() {
    local service_name="beszel.service"
    
    log_info "Checking service status..."
    
    if systemctl is-active --quiet "$service_name"; then
        log_success "Service is running"
        systemctl status "$service_name" --no-pager -l >&2
    else
        log_error "Service is not running"
        log_info "Recent service logs:"
        journalctl -u "$service_name" --no-pager -l -n 20 >&2
        return 1
    fi
}

# Function to test binary functionality
test_binary() {
    local binary_path="$1"
    
    log_info "Testing binary functionality..."
    
    # Test if binary runs at all
    if "$binary_path" --help &>/dev/null; then
        log_success "Binary responds to --help"
    elif "$binary_path" version &>/dev/null; then
        log_success "Binary responds to version command"
    else
        log_warning "Binary test inconclusive, but this might be normal"
    fi
    
    # Show what we can about the binary
    log_info "Binary info:"
    ls -la "$binary_path" >&2
}

# Function to detect current installation
detect_installation() {
    log_info "Detecting current Beszel installation..."
    
    # Check if systemd service exists
    if systemctl list-unit-files beszel.service &>/dev/null; then
        log_info "Found systemd service: beszel.service"
        return 0  # Service exists
    else
        log_warning "No systemd service found for beszel.service"
        
        # Check for running processes
        local beszel_processes=$(pgrep -f beszel || true)
        if [[ -n "$beszel_processes" ]]; then
            log_info "Found running Beszel processes:"
            ps aux | grep -E '[b]eszel' >&2 || true
        else
            log_warning "No running Beszel processes found"
        fi
        
        return 1  # No service exists
    fi
}

# Main function
main() {
    log_info "Starting Beszel Hub update process..."
    echo "==================================================" >&2
    
    # Check if running as root
    check_root
    
    # Detect current installation
    local has_systemd_service=false
    if detect_installation; then
        has_systemd_service=true
    fi
    
    # Find Beszel binary
    log_info "Locating Beszel binary..."
    local binary_path
    if ! binary_path=$(find_beszel_binary); then
        log_error "Cannot proceed without finding Beszel binary"
        log_info "Please install Beszel first or check your installation"
        exit 1
    fi
    
    log_info "Using Beszel binary at: $binary_path"
    
    # Verify binary exists and create backup
    if [[ -f "$binary_path" ]]; then
        backup_binary "$binary_path"
    else
        log_error "Binary path does not exist: $binary_path"
        exit 1
    fi
    
    # Stop services/processes before update
    if $has_systemd_service; then
        manage_service "stop" || log_warning "Could not stop service, continuing..."
    else
        stop_running_processes
    fi
    
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
    
    # Create systemd service if it doesn't exist
    if ! $has_systemd_service; then
        log_info "No systemd service detected, creating one..."
        if create_systemd_service "$binary_path"; then
            has_systemd_service=true
            manage_service "reload"
            log_success "Systemd service created and loaded"
        else
            log_error "Failed to create systemd service"
            exit 1
        fi
    fi
    
    # Start/restart service
    if $has_systemd_service; then
        manage_service "reload"
        manage_service "enable" || log_warning "Could not enable service"
        manage_service "restart" || exit 1
        
        # Wait a moment for service to start
        sleep 3
        
        # Check final status
        if check_service_status; then
            echo "==================================================" >&2
            log_success "Beszel Hub update completed successfully!"
            log_info "Web UI should be accessible again"
            log_info "Service will start automatically on boot"
            echo "==================================================" >&2
        else
            echo "==================================================" >&2
            log_error "Update completed but service is not running properly"
            log_info "Check the logs above for troubleshooting"
            echo "==================================================" >&2
            exit 1
        fi
    fi
}

# Help function
show_help() {
    echo "Beszel Hub Update Script v1.2"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help     Show this help message"
    echo "  -v, --verbose  Enable verbose output (set -x)"
    echo ""
    echo "This script will:"
    echo "  1. Detect current Beszel installation"
    echo "  2. Find the Beszel binary location"  
    echo "  3. Create a backup of the current binary"
    echo "  4. Update Beszel using the built-in update command"
    echo "  5. Fix file permissions (chmod +x)"
    echo "  6. Create systemd service if not exists"
    echo "  7. Enable and restart the systemd service"
    echo "  8. Verify the service is running"
    echo ""
    echo "Requirements:"
    echo "  - Must be run as root or with sudo"
    echo "  - Beszel must be installed as native binary (not Docker)"
    echo "  - systemd-based Linux distribution"
    echo ""
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
