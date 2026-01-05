#!/bin/sh

# --- 1. Dependencies & Env Setup ---

# Check for required tools
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is not installed. Please install it."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: 'curl' is not installed. Please install it."
    exit 1
fi

# Load environment variables
if [ -f /.env ]; then
    . /.env
fi

# Configuration
DNS_API_BASE="http://${TECHNITIUM_CONTAINER_NAME}:${DNS_WEB_PORT:-5380}/api"
NPM_API_BASE="http://${NPM_CONTAINER_NAME}:${NPM_ADMIN_PORT:-81}/api"
DNS_ZONE="${DNS_ZONE:-dev.local}"

# Credentials
DNS_USER="admin"
DNS_PASS="admin"
NPM_USER="admin@example.com"
NPM_PASS="changeme"

# Helper: Wait for HTTP 200 OK
# Validate required variables
if [ -z "$TECHNITIUM_CONTAINER_NAME" ]; then
    echo "Error: TECHNITIUM_CONTAINER_NAME is not set."
    exit 1
fi
if [ -z "$NPM_CONTAINER_NAME" ]; then
    echo "Error: NPM_CONTAINER_NAME is not set."
    exit 1
fi

# Helper: Wait for HTTP 200 OK
wait_for_url() {
    url="$1"
    echo "Waiting for $url to be ready..."
    max_retries=60
    count=0
    while [ $count -lt $max_retries ]; do
        # Use curl to get HTTP code only, silent output
        status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
        
        if [ "$status_code" = "200" ]; then
            echo "Success: $url is ready (HTTP 200)."
            return 0
        fi
        
        if [ $((count % 5)) -eq 0 ]; then
            echo "Wait attempt $((count+1))/$max_retries. Status: $status_code"
        fi
        
        sleep 2
        count=$((count + 1))
    done
    
    echo "Timeout waiting for $url. Last status: $status_code"
    # Try one verbose curl to show error detail to logs before failing
    curl -v "$url"
    return 1
}

# --- 2. Technitium DNS Configuration ---

# Technitium's API might return 200 even if not fully loaded, but let's try basic connection
wait_for_url "${DNS_API_BASE}/user/login?user=${DNS_USER}&pass=${DNS_PASS}" || exit 1

echo "Configuring Technitium DNS..."
DNS_TOKEN=$(curl -s -X POST "${DNS_API_BASE}/user/login?user=${DNS_USER}&pass=${DNS_PASS}" | jq -r '.token')

if [ -z "$DNS_TOKEN" ] || [ "$DNS_TOKEN" = "null" ]; then
    echo "FATAL: Failed to login to Technitium DNS."
    exit 1
fi

# Check Zone
ZONE_EXISTS=$(curl -s -X GET "${DNS_API_BASE}/zones/list?token=${DNS_TOKEN}&pageNumber=1&recordsPerPage=100" | jq -r ".response.zones[] | select(.name == \"${DNS_ZONE}\") | .name")

if [ "$ZONE_EXISTS" = "$DNS_ZONE" ]; then
     echo "DNS Zone '$DNS_ZONE' already exists."
else
     echo "Creating DNS Zone '$DNS_ZONE'..."
     curl -s -X POST "${DNS_API_BASE}/zones/create?token=${DNS_TOKEN}&zone=${DNS_ZONE}&type=Primary" > /dev/null
fi

# --- 3. Nginx Proxy Manager Configuration ---

# Wait for NPM (It has a specific /api/schema endpoint usually available, or just check root)
# Note: NPM takes a while to boot DB.
wait_for_url "${NPM_API_BASE}/" || exit 1

echo "Configuring Nginx Proxy Manager..."
NPM_TOKEN=$(curl -s -X POST "${NPM_API_BASE}/tokens" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$NPM_USER" --arg p "$NPM_PASS" '{identity: $u, secret: $p}')" | jq -r '.token')

if [ -z "$NPM_TOKEN" ] || [ "$NPM_TOKEN" = "null" ]; then
    echo "FATAL: Failed to login to NPM."
    exit 1
fi

# Upload SSL
CERT_ID=0
CERT_FILE="/certs/${DNS_ZONE}.pem"
KEY_FILE="/certs/${DNS_ZONE}-key.pem"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    EXISTING_CERT_ID=$(curl -s -X GET "${NPM_API_BASE}/nginx/certificates" \
        -H "Authorization: Bearer ${NPM_TOKEN}" | jq -r ".[] | select(.domain_names[] == \"*.${DNS_ZONE}\") | .id" | head -n 1)

    if [ -n "$EXISTING_CERT_ID" ]; then
        echo "Certificate exists (ID: ${EXISTING_CERT_ID})."
        CERT_ID=$EXISTING_CERT_ID
    else
        echo "Uploading certificate..."
        UPLOAD_RESP=$(curl -s -X POST "${NPM_API_BASE}/nginx/certificates" \
            -H "Authorization: Bearer ${NPM_TOKEN}" \
            -F "certificate=@${CERT_FILE}" \
            -F "certificate_key=@${KEY_FILE}")
        
        CERT_ID=$(echo "$UPLOAD_RESP" | jq -r '.id')
        if [ "$CERT_ID" = "null" ] || [ -z "$CERT_ID" ]; then
            echo "Error uploading cert: $UPLOAD_RESP"
            CERT_ID=0
        fi
    fi
fi

# Function to Create OR Update Host
create_proxy_host() {
    CONTAINER=$1
    PORT=$2
    CID=$3
    SCHEME=${4:-http}

    DOMAIN="${CONTAINER}.${DNS_ZONE}"
    
    # Determine SSL Booleans
    if [ "$CID" -ne 0 ]; then
        SSL_FORCED="true"; HTTP2="true"; HSTS="true"
    else
        SSL_FORCED="false"; HTTP2="false"; HSTS="false"
    fi

    # Construct JSON safely using jq
    PAYLOAD=$(jq -n \
        --arg domain "$DOMAIN" \
        --arg scheme "$SCHEME" \
        --arg host "$CONTAINER" \
        --arg port "$PORT" \
        --argjson cid "$CID" \
        --argjson ssl "$SSL_FORCED" \
        --argjson http2 "$HTTP2" \
        --argjson hsts "$HSTS" \
        '{
            domain_names: [$domain],
            forward_scheme: $scheme,
            forward_host: $host,
            forward_port: ($port | tonumber),
            certificate_id: $cid,
            access_list_id: 0,
            meta: {letsencrypt_agree: false, dns_challenge: false},
            advanced_config: "",
            locations: [],
            block_exploits: true,
            caching_enabled: false,
            allow_websocket_upgrade: true,
            http2_support: $http2,
            hsts_enabled: $hsts,
            hsts_subdomains: false,
            ssl_forced: $ssl
        }')

    # Check existence
    EXISTING_ID=$(curl -s -X GET "${NPM_API_BASE}/nginx/proxy-hosts" \
        -H "Authorization: Bearer ${NPM_TOKEN}" | jq -r ".[] | select(.domain_names[] == \"${DOMAIN}\") | .id")

    if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
        echo "Proxy host for $DOMAIN already exists. Skipping."
    else
        echo "Creating new host: $DOMAIN..."
        curl -s -X POST "${NPM_API_BASE}/nginx/proxy-hosts" \
            -H "Authorization: Bearer ${NPM_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" > /dev/null
    fi
}

# --- 4. Service Definitions ---

# Only run if vars exist to prevent errors
[ -n "$PORTAINER_CONTAINER_NAME" ] && create_proxy_host "${PORTAINER_CONTAINER_NAME}" "${PORTAINER_WEB_PORT_HTTPS}" "$CERT_ID" "https"
[ -n "$PORTAINER_CONTAINER_NAME" ] && create_proxy_host "${PORTAINER_CONTAINER_NAME}" "${PORTAINER_WEB_PORT_HTTP}" "$CERT_ID" "http"
[ -n "$CLOUDBEAVER_CONTAINER_NAME" ] && create_proxy_host "${CLOUDBEAVER_CONTAINER_NAME}" "${CLOUDBEAVER_PORT}" "$CERT_ID"
[ -n "$REDIS_INSIGHT_CONTAINER_NAME" ] && create_proxy_host "${REDIS_INSIGHT_CONTAINER_NAME}" "${REDIS_INSIGHT_PORT}" "$CERT_ID"
[ -n "$MAILPIT_CONTAINER_NAME" ] && create_proxy_host "${MAILPIT_CONTAINER_NAME}" "${MAILPIT_WEB_PORT}" "$CERT_ID"
[ -n "$NPM_CONTAINER_NAME" ] && create_proxy_host "${NPM_CONTAINER_NAME}" "${NPM_WEB_PORT}" "$CERT_ID"
[ -n "$TECHNITIUM_CONTAINER_NAME" ] && create_proxy_host "${TECHNITIUM_CONTAINER_NAME}" "${TECHNITIUM_WEB_PORT}" "$CERT_ID"
[ -n "$HOMEPAGE_CONTAINER_NAME" ] && create_proxy_host "${HOMEPAGE_CONTAINER_NAME}" "${HOMEPAGE_PORT}" "$CERT_ID"

echo "Initialization complete."
