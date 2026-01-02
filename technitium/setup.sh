#!/bin/bash
# Technitium DNS setup
# This script configures the host to use a static IP and sets the DNS configuration.
# It reads configuration from a ../.env file.

# Determine script directory for robust path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Load environment variables
if [ -f "$ENV_FILE" ]; then
    # Export variables from .env, filtering out comments
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

# Check for required variables
if [ -z "$BASE_DNS" ] || [ -z "$STATIC_IP" ] || [ -z "$GATEWAY_IP" ]; then
    echo "Error: BASE_DNS, STATIC_IP, and GATEWAY_IP must be defined in ../.env"
    exit 1
fi

REVERT_MODE=0

# Parse arguments for revert flag only
for arg in "$@"; do
    case $arg in
        --revert)
            REVERT_MODE=1
            ;;
        --help)
            echo "Usage: ./setup.sh [OPTIONS]"
            echo "Options:"
            echo "  --revert     Revert host changes (restore networking and systemd-resolved)"
            echo "  --help       Show this help message"
            exit 0
            ;;
    esac
done

if [ "$REVERT_MODE" -eq 1 ]; then
    echo "Reverting system configurations..."
    
    # 1. Escalate for revert
    sudo -v

    # Restore resolv.conf
    if [ -f "/etc/resolv.conf.bak" ]; then
        echo "Restoring /etc/resolv.conf from backup..."
        sudo mv /etc/resolv.conf.bak /etc/resolv.conf
    else
        echo "Warning: /etc/resolv.conf.bak not found. Leaving /etc/resolv.conf as is."
    fi

    # Restore Netplan configuration
    if [ -f "config/netplan-backup.tar.gz" ]; then
        echo "Restoring Netplan configuration..."
        # Remove current netplan configs to avoid conflicts before restoring
        sudo rm -rf /etc/netplan/*
        sudo tar -xzf config/netplan-backup.tar.gz -C /
        sudo netplan apply
        echo "Netplan configuration restored."
    else
        echo "Warning: Netplan backup not found (config/netplan-backup.tar.gz). Skipping Netplan restore."
    fi

    # Enable and start systemd-resolved
    echo "Enabling and starting systemd-resolved..."
    sudo systemctl enable systemd-resolved
    sudo systemctl start systemd-resolved
    
    echo "Revert complete. System configuration restored."
    exit 0
fi

# Normal Setup
mkdir -p config
mkdir -p data

echo "Starting System Configuration..."

# 1. Escalate
sudo -v

# 2. Network Configuration (Static IP via Netplan)
# Detect Interface
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo "Error: Could not detect active network interface."
    exit 1
fi
echo "Detected interface: $INTERFACE"

# Backup existing Netplan config
if [ ! -f "config/netplan-backup.tar.gz" ]; then
    echo "Backing up existing Netplan configuration..."
    if [ -d "/etc/netplan" ]; then
        sudo tar -czf config/netplan-backup.tar.gz -C / etc/netplan
    else
        echo "Warning: /etc/netplan not found. Is this an Ubuntu/Debian system?"
    fi
fi

# Create new Netplan config
# Note: We assume standard 01-netcfg.yaml or similar. We will overwrite/create a specific file 99-static.yaml to override
# BUT Netplan merges files. To enforce static cleanly, we might need to move others aside.
# For safety, we'll try to generate a comprehensive config for the detected interface.

NETPLAN_FILE="/etc/netplan/99-static-config.yaml"

echo "Configuring Static IP ($STATIC_IP) and Gateway ($GATEWAY_IP) for $INTERFACE..."

# Generate Netplan YAML
# Indentation strictness in YAML requires printf or careful echo
sudo bash -c "cat > $NETPLAN_FILE" <<EOF
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

echo "Applying Netplan configuration..."
sudo netplan apply
if [ $? -ne 0 ]; then
    echo "Error: Netplan apply failed. Reverting..."
    # Attempt to restore immediately if apply fails?
    # For now, just exit. User can use --revert.
    exit 1
fi

# 3. Disable systemd-resolved (to free port 53 for Technitium)
echo "Checking for systemd-resolved..."
if systemctl is-active --quiet systemd-resolved; then
    echo "systemd-resolved is active (blocking port 53). Disabling..."
    
    sudo systemctl stop systemd-resolved
    sudo systemctl disable systemd-resolved
    
    echo "Backing up and replacing /etc/resolv.conf..."
    if [ ! -f "/etc/resolv.conf.bak" ]; then
        sudo cp /etc/resolv.conf /etc/resolv.conf.bak
    fi
    sudo rm -f /etc/resolv.conf
    
    # Point host DNS to the BASE_DNS as well (since we set it in netplan, systemd-resolved is gone, 
    # so we need a static resolv.conf or let netplan manage it? 
    # If networkd manages it, it might update resolv.conf if it's a symlink to /run/systemd/resolve/resolv.conf 
    # BUT we stopped systemd-resolved.
    # So we manually set it to BASE_DNS.
    echo "nameserver $BASE_DNS" | sudo tee /etc/resolv.conf > /dev/null
    
    echo "Port 53 liberated."
else
    echo "systemd-resolved not running."
    # still ensure resolv.conf is correct
    echo "nameserver $BASE_DNS" | sudo tee /etc/resolv.conf > /dev/null
fi

echo "Setup Complete."
