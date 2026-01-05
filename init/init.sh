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
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"
NPM_ADMIN_PASSWORD="${NPM_ADMIN_PASSWORD:-changeme}"

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

# Helper to get token
get_npm_token() {
    user="$1"
    pass="$2"
    echo "Debug: Authenticating as user: $user" >&2
    
    # Capture http code and body
    # Using a temporary file for body to handle multiline safely if needed, or just variable.
    # Simple variable capture with separate status line:
    response=$(curl -s -w "\n%{http_code}" -X POST "${NPM_API_BASE}/tokens" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg u "$user" --arg p "$pass" '{identity: $u, secret: $p}')")
    
    # Extract body and status
    # Note: This assumes the body does not end with a newline that we care about preserving strictly vs the appended status
    body=$(echo "$response" | sed '$d')
    status=$(echo "$response" | tail -n 1)

    echo "Debug: API Response Status: $status" >&2
    echo "Debug: API Response Body: $body" >&2

    if [ "$status" = "200" ]; then
        token=$(echo "$body" | jq -r '.token')
        if [ "$token" = "null" ]; then
             echo "Debug: Token is null in response" >&2
        fi
        echo "$token"
    else
        echo "null"
    fi
}

# 1. Try to login with Target Credentials first (in case already set)
echo "Attempting login with TARGET credentials..."
NPM_TOKEN=$(get_npm_token "$NPM_ADMIN_EMAIL" "$NPM_ADMIN_PASSWORD")

# 2. If failed, try Default Credentials
if [ -z "$NPM_TOKEN" ] || [ "$NPM_TOKEN" = "null" ]; then
    echo "Target login failed. Attempting login with DEFAULT credentials..."
    NPM_TOKEN=$(get_npm_token "$NPM_USER" "$NPM_PASS")
    
    if [ -z "$NPM_TOKEN" ] || [ "$NPM_TOKEN" = "null" ]; then
        echo "FATAL: Failed to login to NPM with both partial and default credentials."
        exit 1
    fi

    echo "Logged in with DEFAULT credentials. Updating admin account to TARGET credentials..."
    
    # Update Email/Name for User 1 (Admin)
    # Note: NPM User ID 1 is the default admin.
    # Update Admin Email/Name
    echo "Updating Admin Email/Name..."
    UPDATE_USER_RAW=$(curl -s -w "\n%{http_code}" -X PUT "${NPM_API_BASE}/users/1" \
        -H "Authorization: Bearer ${NPM_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg email "$NPM_ADMIN_EMAIL" --arg name "Administrator" '{name: $name, email: $email}')")
    
    UPDATE_USER_RESP=$(echo "$UPDATE_USER_RAW" | sed '$d')
    UPDATE_USER_STATUS=$(echo "$UPDATE_USER_RAW" | tail -n 1)

    echo "Debug: Update User Response Status: $UPDATE_USER_STATUS" >&2
    echo "Debug: Update User Response Body: $UPDATE_USER_RESP" >&2
    
    # Check if update was successful (basic check if email is in response)
    if echo "$UPDATE_USER_RESP" | grep -q "$NPM_ADMIN_EMAIL"; then
        echo "Admin email updated successfully."
    else
        echo "Error updating email: $UPDATE_USER_RESP"
        # Continue anyway, might just be password update needed if email was same
    fi

    # Update Password for User 1
    echo "Updating Admin Password..."
    UPDATE_PASS_RAW=$(curl -s -w "\n%{http_code}" -X PUT "${NPM_API_BASE}/users/1/auth" \
        -H "Authorization: Bearer ${NPM_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg secret "$NPM_ADMIN_PASSWORD" --arg current "$NPM_PASS" '{type: "password", secret: $secret, current: $current}')")

    UPDATE_PASS_RESP=$(echo "$UPDATE_PASS_RAW" | sed '$d')
    UPDATE_PASS_STATUS=$(echo "$UPDATE_PASS_RAW" | tail -n 1)

    echo "Debug: Update Password Response Status: $UPDATE_PASS_STATUS" >&2
    echo "Debug: Update Password Response Body: $UPDATE_PASS_RESP" >&2
        
    # Refresh Token with NEW credentials
    echo "Refreshing token with NEW credentials..."
    NPM_TOKEN=$(get_npm_token "$NPM_ADMIN_EMAIL" "$NPM_ADMIN_PASSWORD")
    
    if [ -z "$NPM_TOKEN" ] || [ "$NPM_TOKEN" = "null" ]; then
        echo "FATAL: Failed to login with NEW credentials after update."
        exit 1
    fi
    echo "Successfully updated default admin account and logged in."
else
    echo "Logged in successfully with TARGET credentials."
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
