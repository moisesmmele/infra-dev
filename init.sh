#!/bin/sh

# Load environment variables
if [ -f /.env ]; then
    . /.env
fi

# Configuration
DNS_API_BASE="http://${TECHNITIUM_CONTAINER_NAME}:${DNS_WEB_PORT:-5380}/api"
NPM_API_BASE="http://${NPM_CONTAINER_NAME}:${NPM_ADMIN_PORT:-81}/api"
DNS_ZONE="${DNS_ZONE:-dev.local}"

# Credentials (default)
DNS_USER="admin"
DNS_PASS="admin"
NPM_USER="admin@example.com"
NPM_PASS="changeme"

echo "Waiting for services to be ready..."
# Simple sleep not strictly necessary due to healthchecks, but good practice
sleep 5

# --- Technitium DNS Configuration ---

echo "Configuring Technitium DNS..."
# Login
DNS_TOKEN=$(curl -s -X POST "${DNS_API_BASE}/user/login?user=${DNS_USER}&pass=${DNS_PASS}" | jq -r '.token')

if [ -z "$DNS_TOKEN" ] || [ "$DNS_TOKEN" = "null" ]; then
    echo "Failed to login to Technitium DNS. Check credentials or connectivity."
else
    echo "Logged into Technitium DNS."
    
    # Check if Zone exists
    ZONE_EXISTS=$(curl -s -X GET "${DNS_API_BASE}/zones/list?token=${DNS_TOKEN}&pageNumber=1&recordsPerPage=100" | jq -r ".response.zones[] | select(.name == \"${DNS_ZONE}\") | .name")
    
    if [ "$ZONE_EXISTS" = "$DNS_ZONE" ]; then
         echo "DNS Zone '$DNS_ZONE' already exists."
    else
         echo "Creating DNS Zone '$DNS_ZONE'..."
         curl -s -X POST "${DNS_API_BASE}/zones/create?token=${DNS_TOKEN}&zone=${DNS_ZONE}&type=Primary" > /dev/null
         echo "DNS Zone created."
    fi
fi

# --- Nginx Proxy Manager Configuration ---

echo "Configuring Nginx Proxy Manager..."
# Login
NPM_TOKEN=$(curl -s -X POST "${NPM_API_BASE}/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\": \"${NPM_USER}\", \"secret\": \"${NPM_PASS}\"}" | jq -r '.token')

if [ -z "$NPM_TOKEN" ] || [ "$NPM_TOKEN" = "null" ]; then
    echo "Failed to login to NPM. Check credentials or connectivity."
else 
    echo "Logged into NPM."
    
    # Helper to create host
    create_proxy_host() {
        CONTAINER=$1
        PORT=$2
        
        DOMAIN="${CONTAINER}.${DNS_ZONE}"
        
        echo "Processing $DOMAIN -> $CONTAINER:$PORT"
        
        # Check if already exists (simplistic check by domain name in list)
        # Note: NPM API pagination might hide it if many hosts, but assuming fresh/small setup.
        EXISTS=$(curl -s -X GET "${NPM_API_BASE}/nginx/proxy-hosts" \
            -H "Authorization: Bearer ${NPM_TOKEN}" | jq -r ".[] | select(.domain_names[] == \"${DOMAIN}\") | .id")
            
        if [ -n "$EXISTS" ]; then
            echo "Proxy host for $DOMAIN already exists (ID: $EXISTS)."
        else
            echo "Creating proxy host for $DOMAIN..."
            curl -s -X POST "${NPM_API_BASE}/nginx/proxy-hosts" \
              -H "Authorization: Bearer ${NPM_TOKEN}" \
              -H "Content-Type: application/json" \
              -d "{
                \"domain_names\": [\"${DOMAIN}\"],
                \"forward_scheme\": \"http\",
                \"forward_host\": \"${CONTAINER}\",
                \"forward_port\": ${PORT},
                \"access_list_id\": 0,
                \"certificate_id\": 0,
                \"meta\": {
                  \"letsencrypt_agree\": false,
                  \"dns_challenge\": false
                },
                \"advanced_config\": \"\",
                \"locations\": [],
                \"block_exploits\": true,
                \"caching_enabled\": false,
                \"allow_websocket_upgrade\": true,
                \"http2_support\": false,
                \"hsts_enabled\": false,
                \"hsts_subdomains\": false,
                \"ssl_forced\": false
              }" > /dev/null
             echo "Created."
        fi
    }

    # Define Services
    # Format: "ContainerName Port"
    # Using env vars from .env
    
    # Portainer
    create_proxy_host "${PORTAINER_CONTAINER_NAME}" "${PORTAINER_PORT}"
    
    # CloudBeaver
    create_proxy_host "${CLOUDBEAVER_CONTAINER_NAME}" "${CLOUDBEAVER_PORT}"
    
    # Redis Insight
    create_proxy_host "${REDIS_INSIGHT_CONTAINER_NAME}" "${REDIS_INSIGHT_PORT}"
    
    # Mailpit (Web UI)
    create_proxy_host "${MAILPIT_CONTAINER_NAME}" "${MAILPIT_WEB_PORT}"
    
    # NPM (Nginx Proxy Manager Admin)
    create_proxy_host "${NPM_CONTAINER_NAME}" "${NPM_ADMIN_PORT}"
    
    # Technitium DNS
    create_proxy_host "${TECHNITIUM_CONTAINER_NAME}" "${DNS_WEB_PORT}"

    # Homepage
    create_proxy_host "${HOMEPAGE_CONTAINER_NAME}" "${HOMEPAGE_PORT}"
fi

echo "Init script completed."
