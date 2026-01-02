#!/bin/bash

# Root setup script
# Iterates through all subdirectories and runs setup.sh if found.

echo "Starting infrastructure setup..."

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | xargs)
else
    echo "Warning: .env file not found. Using defaults."
fi

NETWORK_NAME=${DEV_NET:-dev-net}
SUBNET=${DEV_NET_SUBNET:-172.16.20.0/24}

# Create network if it doesn't exist
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "Creating network '$NETWORK_NAME' with subnet '$SUBNET'..."
    docker network create --subnet="$SUBNET" "$NETWORK_NAME"
else
    echo "Network '$NETWORK_NAME' already exists."
fi

# SSL Certificate Generation
if [ -n "$DNS_ZONE" ]; then
    echo "Checking for mkcert..."
    if command -v mkcert >/dev/null 2>&1; then
        echo "mkcert found. Generating SSL certificates for $DNS_ZONE..."
        mkdir -p certs
        if [ ! -f "certs/$DNS_ZONE.pem" ] || [ ! -f "certs/$DNS_ZONE-key.pem" ]; then
             mkcert -install
             mkcert -cert-file "certs/$DNS_ZONE.pem" -key-file "certs/$DNS_ZONE-key.pem" "$DNS_ZONE" "*.$DNS_ZONE"
             echo "Certificates generated: certs/$DNS_ZONE.pem, certs/$DNS_ZONE-key.pem"
        else
             echo "Certificates already exist for $DNS_ZONE in certs/ directory."
        fi
    else
        echo "Warning: mkcert not found. Skipping SSL certificate generation."
    fi
else
    echo "DNS_ZONE not set in .env. Skipping SSL certificate generation."
fi

# Find all setup.sh files in immediate subdirectories (max depth 2)
# We exclude the current directory to avoid running itself recursively if logic fails, 
# although 'find' logic below specifically looks in subdirs.
find . -mindepth 2 -maxdepth 2 -name "setup.sh" | while read setup_script; do
    service_dir=$(dirname "$setup_script")
    service_name=$(basename "$service_dir")
    
    echo "------------------------------------------------"
    echo "Setting up service: $service_name"
    
    # Make executable just in case
    chmod +x "$setup_script"
    
    # Run the script from within its directory to ensure relative paths work
    (cd "$service_dir" && ./setup.sh)
    
    if [ $? -eq 0 ]; then
        echo "Setup for $service_name completed."
    else
        echo "Setup for $service_name failed."
    fi
done

echo "------------------------------------------------"
echo "Infrastructure setup finished."
