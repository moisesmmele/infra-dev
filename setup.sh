#!/bin/bash

# Setup Script
# This script prepares the environment for the development infrastructure.
# It sets up directories, networks, and host configurations.

# WARNING: DO NOT RUN THIS SCRIPT ON A PERSONAL SYSTEM!
# THIS IS DESIGNED TO RUN ON A VIRTUAL MACHINE SPECIFICALLY DESIGNED FOR DEVELOPMENT PURPOSES.
# IF YOU RUN THIS SCRIPT ON A PERSONAL SYSTEM, YOU WILL (PROBABLY) BREAK YOUR SYSTEM!

# Improvement ideas:
# - Better state management: Create a state file to track the state of the system.
# - Better network action isolation: instead of a single configure_host_network function, split it into multiple functions.

# VARIABLES 

ENV_FILE=".env"
SCRIPT_DIR="$HOME/.infra-dev-setup"
NETPLAN_BACKUP_DIR="$SCRIPT_DIR/backups/netplan"
NETPLAN_BACKUP_FILE="netplan-backup.tar.gz"
NETPLAN_CONFIG_FILE="/etc/netplan/99-static-config.yaml"
RESOLV_BACKUP_DIR="$SCRIPT_DIR/backups/resolv"
RESOLV_BACKUP_FILE="resolv.conf.bak"
RESOLV_CONFIG_FILE="/etc/resolv.conf"

REQUIRED_ENVS=(
    "BASE_DNS" 
    "STATIC_IP" 
    "GATEWAY_IP"
    "DOCKER_NETWORK_NAME"
    "DOCKER_SUBNET"
)

# FLAGS 

SKIP_HOST_NETWORK=0
IGNORE_WARNING=0
NETWORK_REVERT_MODE=0
SKIP_DOCKER=0

# PREFLIGHT CHECKS

# create script dirs
echo "Creating script directory..."
if [ ! -d "$SCRIPT_DIR" ]; then
    mkdir -p "$SCRIPT_DIR"
else
    echo "Script directory already exists."
fi

# create backup dirs
if [ ! -d "$NETPLAN_BACKUP_DIR" ]; then
    mkdir -p "$NETPLAN_BACKUP_DIR"
else
    echo "Netplan backup directory already exists."
fi

if [ ! -d "$RESOLV_BACKUP_DIR" ]; then
    mkdir -p "$RESOLV_BACKUP_DIR"
else
    echo "Resolv backup directory already exists."
fi

# FUNCTIONS

show_warning_message() {
    if [ "$IGNORE_WARNING" -eq 1 ]; then
        return
    fi
    echo -e "\n\nThis script WILL break network connectivity even if it works."
    echo -e "(Because it will change your IP.)\n"
    echo -e "Do not run over SSH unless you know what you are doing.\n"
    sleep 2
    echo -e "Do NOT run this script on a personal system!\n"
    sleep 2
    echo -e "This is designed to run on a virtual machine specifically designed for development purposes.\n\n"
    sleep 5
    echo -e "\n\n\nYou have been warned! :D\n\n\n"
    sleep 2
}

setup_service_data_dirs() {
    echo "Setting up directories with proper permissions..."

    # CloudBeaver
    mkdir -p "$PWD/cloudbeaver/mounts/data"

    # Homepage
    mkdir -p "$PWD/homepage/mounts/config"

    # Mailpit
    mkdir -p "$PWD/mailpit/mounts/data"

    # Nginx Proxy Manager
    mkdir -p "$PWD/npm/mounts/data" "$PWD/npm/mounts/letsencrypt"
    chmod -R 777 "$PWD/npm/mounts/data" "$PWD/npm/mounts/letsencrypt"

    # Portainer
    mkdir -p "$PWD/portainer/mounts/data"

    # Redis Insight
    mkdir -p "$PWD/redis-insight/mounts/data"

    # NATS NUI
    mkdir -p "$PWD/nats-nui/mounts/db"

    # Technitium data dirs
    mkdir -p "$PWD/technitium/mounts/config"
    mkdir -p "$PWD/technitium/mounts/data"
}

detect_docker() {
    if [ "$SKIP_DOCKER" -eq 1 ]; then
        echo "Skipping Docker detection."
        return
    fi
	echo "Checking for an existing Docker installation..."
	if command -v docker > /dev/null; then
		echo "Docker is already installed."
		echo "Current version: $(docker --version)"
	else
		echo "Docker is not installed. Please install before running this script."
		exit 1;
    fi
}

load_and_verify_envs() {

    echo "Loading environment variables..."
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    else
        echo "Error: .env file not found."
        exit 1
    fi

    echo "Verifying environment variables..."
    for env in "${REQUIRED_ENVS[@]}"; do
        if [ -z "${!env}" ]; then
            echo "Error: $env not defined."
            exit 1
        fi
    done
}

configure_docker_network() {
    if [ "$SKIP_DOCKER" -eq 1 ]; then
        echo "Skipping Docker network configuration."
        return
    fi
    echo "Configuring Docker network..."
    if ! docker network inspect "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
        echo "Creating network '$DOCKER_NETWORK_NAME' with subnet '$DOCKER_SUBNET'..."
        docker network create --subnet="$DOCKER_SUBNET" "$DOCKER_NETWORK_NAME"
    else
        echo "Network '$DOCKER_NETWORK_NAME' already exists."
    fi
}

detect_compatible_networking() {
    local compatible=0
    echo "Checking for compatible networking..."
    echo "Checking for Netplan availability..."
    if command -v netplan > /dev/null; then
        echo "Netplan is available."
    else
        echo "Netplan is not installed."
        compatible=1
    fi
    echo "checking for systemctl availability..."
    if command -v systemctl > /dev/null; then
        echo "systemctl is available."
        echo "checking for systemd-resolved availability..."
        if systemctl cat systemd-resolved.service &> /dev/null; then
            echo "systemd-resolved is available."
        else
            echo "systemd-resolved is not available."
            compatible=1
        fi
    else
        echo "systemctl is not available (not using systemd?)"
        compatible=1
    fi
    return $compatible
}

revert_netplan_configuration() {
    echo "Reverting Netplan configuration..."

    revert_failed() {
        echo "FATAL: $1"
        echo "Network configuration might be broken!"
        echo "Please revert the changes manually."
        echo "Backup file is located at: $NETPLAN_BACKUP_DIR/$NETPLAN_BACKUP_FILE"
        echo "Please extract the backup file to /etc/netplan directory, or generate a new one."
        echo "Don't forget to restart the netplan service after making changes."
        exit 1
    }

    # Check for available backup file
    if [ ! -f "$NETPLAN_BACKUP_DIR/$NETPLAN_BACKUP_FILE" ]; then
        revert_failed "No backup file found."
    fi

    # Remove current Netplan configuration
    if ! sudo rm -rf /etc/netplan/*; then
        revert_failed "Failed to remove current Netplan configuration."
    fi

    # extract backup file inside /etc/netplan directory
    if ! sudo tar -xzf "$NETPLAN_BACKUP_DIR/$NETPLAN_BACKUP_FILE" -C /etc/netplan; then
        revert_failed "Could not extract backup file to /etc/netplan directory."
    fi

    # apply netplan configuration
    if ! sudo netplan apply; then
        revert_failed "Failed to apply netplan configuration."
    fi

    echo "removing backup file..."
    if ! sudo rm -rf "$NETPLAN_BACKUP_DIR/$NETPLAN_BACKUP_FILE"; then
        echo "Warning: Failed to remove backup file."
        echo "Backup file is located at: $NETPLAN_BACKUP_DIR/$NETPLAN_BACKUP_FILE"
        echo "Please remove it manually. Script will not run again if you do not remove it."
    fi

    echo "Netplan revert successful."
    
}

configure_host_network() {

    if [ "$SKIP_HOST_NETWORK" -eq 1 ]; then
        echo "Skipping host network configuration."
        return
    fi

    echo "Configuring host network..."

    if ! detect_compatible_networking; then
        echo "Incompatible networking detected."
        echo "This script requires Netplan and systemd-resolved to configure the host network."
        echo "Please configure the host network manually to ensure DNS and reverse proxy resolution."
        SKIP_HOST_NETWORK=1
        return
    fi

    # 1. Escalate
    echo "Escalating privileges..."
    sudo -v
    
    # Backup existing Netplan config
    echo "Backing up Netplan configuration..."

    # first check for a backup file
    # if a backup file exists, already exists, skip network configuration entirely
    # done to ensure network configuration is not backed up from a bad state
    # since reverts should delete the backup file
    if [ -f "$NETPLAN_BACKUP_DIR/$NETPLAN_BACKUP_FILE" ]; then
        echo "Warning: Backup file already exists."
        echo "To prevent misconfiguration, host network configuration will be skipped."
        echo "please ensure that your current network configuration is in a desired state."
        echo "Then, remove the backup file and run the script again."
        SKIP_HOST_NETWORK=1
        return
    fi

    # if /etc/netplan does not exist, skip network configuration entirely
    # again, this is to prevent misconfiguration, since we don't know why
    # it is absent, and we don't want to risk it
    if [ ! -d "/etc/netplan" ]; then   
        echo "Warning: /etc/netplan not found."
        echo "To prevent misconfiguration, host network configuration will be skipped."
        SKIP_HOST_NETWORK=1
        return
    fi

    # backup the ENTIRE netplan directory
    if ! sudo tar -czf "$NETPLAN_BACKUP_DIR/$NETPLAN_BACKUP_FILE" -C /etc/netplan .; then
        echo "Error: Netplan backup failed."
        SKIP_HOST_NETWORK=1
        return
    fi

    echo "Netplan backup successful."

    # 2. Network Configuration (Static IP via Netplan)
    echo "Configuring static IP via Netplan..."
    
    # Detect Interface
    echo "Detecting active network interface..."
    local INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    if [ -z "$INTERFACE" ]; then
        echo "Error: Could not detect active network interface."
        SKIP_HOST_NETWORK=1
        return
    fi
    
    echo "Detected interface: $INTERFACE"

    # Generate Netplan YAML
    echo "Generating Netplan YAML..."
    echo "Configuring Static IP ($STATIC_IP) and Gateway ($GATEWAY_IP) for $INTERFACE."
    
    local TEMP_NETPLAN_FILE=$(mktemp)

    cat > "$TEMP_NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - $STATIC_IP
      routes:
        - to: default
          via: $GATEWAY_IP
      nameservers:
        addresses: [$BASE_DNS]
EOF
    
    echo "Netplan YAML generated successfully."

    # Remove existing Netplan configuration
    echo "removing existing Netplan configuration..."
    if ! sudo rm -f "$NETPLAN_CONFIG_FILE"; then
        echo "Error: Failed to remove existing Netplan configuration."
        SKIP_HOST_NETWORK=1
        return
    fi

    echo "Moving Netplan configuration file..."
    if ! sudo mv "$TEMP_NETPLAN_FILE" "$NETPLAN_CONFIG_FILE"; then
        echo "CRITICAL: Failed to move Netplan configuration file."
        echo "Reverting to previous configuration..."
        revert_netplan_configuration
        SKIP_HOST_NETWORK=1
        return
    fi

    echo "Applying correct permissions for Netplan configuration..."

    if ! sudo chmod 600 "$NETPLAN_CONFIG_FILE"; then
        echo "Warning: Failed to apply correct permissions for Netplan configuration."
        echo "This is not a critical error, but you should manually apply the correct permissions."
    fi

    # WARNING: This will break connectivity because it WILL change IP addresses
    # and consequently reset ssh connection
    echo "Applying Netplan configuration..."
    if ! sudo netplan apply; then
        echo "CRITICAL: Netplan apply failed."
        revert_netplan_configuration
        SKIP_HOST_NETWORK=1
        return
    fi
    echo "Waiting for Netplan to apply..."
    sleep 5
    echo "Verifying static IP..."
    if ! ip addr show "$INTERFACE" | grep -q "$STATIC_IP"; then
        echo "CRITICAL: Static IP not applied!"
        revert_netplan_configuration
    fi

    # Disable systemd-resolved
    echo "Disabling systemd-resolved..."
    if systemctl is-active --quiet systemd-resolved; then
        echo "systemd-resolved is active and blocking port 53. Disabling..."
        
        if ! sudo systemctl stop systemd-resolved; then
            echo "Error: Failed to stop systemd-resolved."
            echo "Please stop systemd-resolved manually."
            SKIP_HOST_NETWORK=1
            return
        fi
        
        if ! sudo systemctl disable systemd-resolved; then
            echo "Error: Failed to disable systemd-resolved."
            echo "Please disable systemd-resolved manually."
            SKIP_HOST_NETWORK=1
            return
        fi

        echo "systemd-resolved disabled successfully."
    fi

    echo "Configuring manual Host DNS resolution..."
    # verify if it is a symlink
    # If its not, then its user configured, needs backup
    # if it is, we can safely skip backup
    if [ ! -L /etc/resolv.conf ]; then
        # verify if backup already exists
        if [ -f "$RESOLV_BACKUP_DIR/$RESOLV_BACKUP_FILE" ]; then
            echo "Warning: /etc/resolv.conf backup already exists."
            echo "To prevent misconfiguration, host resolv configuration will be skipped."
            echo "please ensure that your current resolv configuration is in a desired state."
            echo "Then, remove the backup file and run the script again."
            SKIP_HOST_NETWORK=1
            return
        fi
        
        # backup resolv.conf
        if ! sudo cp /etc/resolv.conf "$RESOLV_BACKUP_DIR/$RESOLV_BACKUP_FILE"; then
            echo "Error: Failed to backup /etc/resolv.conf."
            SKIP_HOST_NETWORK=1
            return
        fi    
    else
        echo "resolv.conf is a symlink. Skipping backup."    
    fi

    # remove existing resolv.conf
    echo "Removing existing resolv.conf..."
    if ! sudo rm -f /etc/resolv.conf; then
        echo "Error: Failed to remove /etc/resolv.conf."
        SKIP_HOST_NETWORK=1
        return
    fi
    
    echo "Creating new /etc/resolv.conf..."
    local TEMP_RESOLV_FILE=$(mktemp)
    cat > "$TEMP_RESOLV_FILE" <<EOF
nameserver $BASE_DNS
EOF
    
    echo "Moving new resolv.conf..."
    if ! sudo mv "$TEMP_RESOLV_FILE" /etc/resolv.conf; then
        echo "Error: Failed to move resolv.conf."
        SKIP_HOST_NETWORK=1
        return
    fi
    
    echo "Applying correct permissions for /etc/resolv.conf..."
    if ! sudo chmod 644 /etc/resolv.conf; then
        echo "Warning: Failed to apply correct permissions for /etc/resolv.conf."
        echo "This is not a critical error, but you should manually apply the correct permissions."
    fi
}

revert_host_network() {
    echo "Reverting system configurations..."
    
    # 1. Escalate for revert
    sudo -v

    # Restore manually configured resolv.conf
    if [ -f "$RESOLV_BACKUP_DIR/$RESOLV_BACKUP_FILE" ]; then
        echo "Restoring /etc/resolv.conf from backup..."
        sudo mv "$RESOLV_BACKUP_DIR/$RESOLV_BACKUP_FILE" /etc/resolv.conf
    else
        echo "No backup found for /etc/resolv.conf. Creating a symlink to systemd-resolved stub..."
        sudo ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi

    revert_netplan_configuration

    # Enable and start systemd-resolved
    echo "Enabling and starting systemd-resolved..."
    sudo systemctl enable systemd-resolved
    sudo systemctl start systemd-resolved
    
    echo "Revert complete. System configuration restored."
    exit 0
}

# parse arguments
for arg in "$@"; do
    case $arg in
        --skip-host-network)
            SKIP_HOST_NETWORK=1
            ;;
        --ignore-warning)
            IGNORE_WARNING=1
            ;;
        --revert)
            NETWORK_REVERT_MODE=1
            ;;
        --skip-docker)
            SKIP_DOCKER=1
            ;;
        --help)
            echo "Usage: ./setup.sh [OPTIONS]"
            echo "Options:"
            echo "  --skip-host-network  Skip host network configuration"
            echo "  --skip-docker        Skip docker related configuration"
            echo "  --ignore-warning     Ignore warning message"
            echo "  --revert     Revert host changes (restore networking and systemd-resolved)"
            echo "  --help       Show this help message"
            exit 0
            ;;
    esac
done    

echo "Starting infrastructure setup..."

if [ $NETWORK_REVERT_MODE -eq 1 ]; then
    echo "Revert flag detected."
    revert_host_network
    exit 0
fi

show_warning_message

load_and_verify_envs
detect_docker
setup_service_data_dirs
configure_docker_network

configure_host_network
if [ $SKIP_HOST_NETWORK -eq 1 ]; then
    echo "Host network configuration was skipped."
    echo "Something might have went wrong with host network configuration."
    echo "If your network is broken, you can revert the changes by running:"
    echo "./setup.sh --revert"
    echo "If it still doesn't work... Well good luck fren :D"
fi
