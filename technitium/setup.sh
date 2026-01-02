#!/bin/bash
# Technitium DNS setup

# Default values
DNS_SERVER="1.1.1.1"
REVERT_MODE=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dns=*)
            DNS_SERVER="${arg#*=}"
            ;;
        --revert)
            REVERT_MODE=1
            ;;
        --help)
            echo "Usage: ./setup.sh [OPTIONS]"
            echo "Options:"
            echo "  --dns=<IP>   Set custom nameserver for host (default: 1.1.1.1)"
            echo "  --revert     Revert host changes (restore systemd-resolved)"
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

    # Enable and start systemd-resolved
    echo "Enabling and starting systemd-resolved..."
    sudo systemctl enable systemd-resolved
    sudo systemctl start systemd-resolved
    
    echo "Revert complete. Port 53 is likely reclaimed by systemd-resolved."
    exit 0
fi

# Normal Setup
mkdir -p config
mkdir -p data

echo "Checking for systemd-resolved..."
if systemctl is-active --quiet systemd-resolved; then
    echo "systemd-resolved is active (blocking port 53). Initiating fix..."
    
    # 1. Escalate
    sudo -v
    
    # 2. Run (Stop service & Fix resolv.conf)
    echo "Disabling systemd-resolved..."
    sudo systemctl stop systemd-resolved
    sudo systemctl disable systemd-resolved
    
    echo "Backing up and replacing /etc/resolv.conf..."
    if [ ! -f "/etc/resolv.conf.bak" ]; then
        sudo cp /etc/resolv.conf /etc/resolv.conf.bak
    fi
    sudo rm -f /etc/resolv.conf
    echo "nameserver $DNS_SERVER" | sudo tee /etc/resolv.conf > /dev/null
    
    # 3. Deescalate (Implicit, we continue as normal user)
    echo "Port 53 liberated."
else
    echo "systemd-resolved not running. Port 53 likely free."
fi

