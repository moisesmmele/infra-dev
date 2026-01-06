#!/bin/bash

# preflight checks

# Check for required tools
if ! command -v bash >/dev/null 2>&1; then
    echo "Error: 'bash' is not installed. Please install it."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is not installed. Please install it."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: 'curl' is not installed. Please install it."
    exit 1
fi


if ! command -v mkcert >/dev/null 2>&1; then
    echo "Error: 'mkcert' is not installed. Please install it."
    exit 1
fi

# Load environment variables
if [ -f /.env ]; then
    . /.env
fi

# Technitium Configuration
TECHNIUM_API_BASE="http://${TECHNITIUM_CONTAINER_NAME}:${TECHNIUM_WEB_PORT:-5380}/api"
DNS_ZONE="${DNS_ZONE:-dev.local}"
TECHNIUM_USER=admin
TECHNIUM_PASS=admin

# NPM Configuration
NPM_API_BASE="http://${NPM_CONTAINER_NAME}:${NPM_ADMIN_PORT:-81}/api"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"
NPM_ADMIN_PASSWORD="${NPM_ADMIN_PASSWORD:-changeme}"
NPM_ADMIN_NAME="${NPM_ADMIN_NAME:-Administrator}"
NPM_ADMIN_NICKNAME="${NPM_ADMIN_NICKNAME:-Admin}"

# Validate required variables
validate_env_vars() {
    if [ -z "$TECHNITIUM_CONTAINER_NAME" ]; then
        echo "Error: TECHNITIUM_CONTAINER_NAME is not set."
        exit 1
    fi

    if [ -z "$TECHNIUM_USER" ]; then
        echo "Error: TECHNIUM_USER is not set."
        exit 1
    fi

    if [ -z "$TECHNIUM_PASS" ]; then
        echo "Error: TECHNIUM_PASS is not set."
        exit 1
    fi

    if [ -z "$TECHNIUM_WEB_PORT" ]; then
        echo "Error: TECHNIUM_WEB_PORT is not set."
        exit 1
    fi

    if [ -z "$DNS_ZONE" ]; then
        echo "Error: DNS_ZONE is not set."
        exit 1
    fi
    
    if [ -z "$NPM_CONTAINER_NAME" ]; then
        echo "Error: NPM_CONTAINER_NAME is not set."
        exit 1
    fi

    if [ -z "$NPM_ADMIN_EMAIL" ]; then
        echo "Error: NPM_ADMIN_EMAIL is not set."
        exit 1
    fi

    if [ -z "$NPM_ADMIN_PASSWORD" ]; then
        echo "Error: NPM_ADMIN_PASSWORD is not set."
        exit 1
    fi

    if [ -z "$NPM_ADMIN_NAME" ]; then
        echo "Error: NPM_ADMIN_NAME is not set."
        exit 1
    fi

    if [ -z "$NPM_ADMIN_NICKNAME" ]; then
        echo "Error: NPM_ADMIN_NICKNAME is not set."
        exit 1
    fi
}

# Helper func: Wait for HTTP 200 OK
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

# SSL Certificate Generation
generate_certs() {
    if [ -n "$DNS_ZONE" ]; then
        echo "Checking for mkcert..."
        if command -v mkcert >/dev/null 2>&1; then
            # Set CAROOT to the mounted volume so the Root CA is persisted
            export CAROOT=/certs
            echo "mkcert found. CAROOT set to $CAROOT"
            
            if [ ! -f "/certs/${DNS_ZONE}.pem" ] || [ ! -f "/certs/${DNS_ZONE}-key.pem" ]; then
                 echo "Generating SSL certificates for $DNS_ZONE..."
                 mkcert -cert-file "/certs/${DNS_ZONE}.pem" -key-file "/certs/${DNS_ZONE}-key.pem" "$DNS_ZONE" "*.$DNS_ZONE"
                 echo "Certificates generated."
            else
                 echo "Certificates already exist for $DNS_ZONE."
            fi
        else
            echo "Warning: mkcert not installed in container. Skipping generation."
        fi

        # Copy Root CA to public folder for serving
        echo "Preparing CA certificate for download..."
        mkdir -p /certs/public
        if [ -f "$CAROOT/rootCA.pem" ]; then
            cp "$CAROOT/rootCA.pem" /certs/public/root-ca.crt
            chmod 644 /certs/public/root-ca.crt
            echo "Copied rootCA.pem to /certs/public/root-ca.crt"
        fi
    else
        echo "DNS_ZONE not set. Skipping SSL generation."
    fi
}

# Technitium DNS
setup_dns() {
    echo "Configuring Technitium DNS..."
    
    # check if Technitium is ready
    wait_for_url "${TECHNIUM_API_BASE}/user/login?user=${DNS_USER}&pass=${DNS_PASS}" || exit 1

    # Get Token
    DNS_TOKEN=$(curl -s -X POST "${TECHNIUM_API_BASE}/user/login?user=${DNS_USER}&pass=${DNS_PASS}" | jq -r '.token')

    # Validate Token; exit if null
    if [ -z "$DNS_TOKEN" ] || [ "$DNS_TOKEN" = "null" ]; then
        echo "FATAL: Failed to login to Technitium DNS."
        exit 1
    fi

    # Check DNS Zone
    ZONE_EXISTS=$(curl -s -X GET "${TECHNIUM_API_BASE}/zones/list?token=${DNS_TOKEN}&pageNumber=1&recordsPerPage=100" | jq -r ".response.zones[] | select(.name == \"${DNS_ZONE}\") | .name")

    if [ "$ZONE_EXISTS" = "$DNS_ZONE" ]; then
         echo "DNS Zone '$DNS_ZONE' already exists."
    else
         echo "Creating DNS Zone '$DNS_ZONE'..."
     curl -s -X POST "${TECHNIUM_API_BASE}/zones/create?token=${DNS_TOKEN}&zone=${DNS_ZONE}&type=Primary" > /dev/null
    fi

    # Check Wildcard Record for DNS Zone
    if [ -n "$STATIC_IP" ]; then
    TARGET_IP=${STATIC_IP%/*}
    WILDCARD_DOMAIN="*.${DNS_ZONE}"
    
    # URL encode the domain for the query might be safer, but usually curl handles verify simple ones. Check if jq handles it.
    # We filter client-side with jq, so we list all records.
    RECORD_EXISTS=$(curl -s -X GET "${TECHNIUM_API_BASE}/zones/records/list?token=${DNS_TOKEN}&zone=${DNS_ZONE}&pageNumber=1&recordsPerPage=1000" | jq -r ".response.records[] | select(.name == \"${WILDCARD_DOMAIN}\") | .name")

    if [ "$RECORD_EXISTS" = "$WILDCARD_DOMAIN" ]; then
         echo "Wildcard record '$WILDCARD_DOMAIN' already exists."
    else
         echo "Creating Wildcard record '$WILDCARD_DOMAIN' pointing to $TARGET_IP..."
         curl -s -X POST "${TECHNIUM_API_BASE}/zones/records/add?token=${DNS_TOKEN}&domain=${WILDCARD_DOMAIN}&type=A&value=${TARGET_IP}&zone=${DNS_ZONE}" > /dev/null
    fi
    else
        echo "Warning: STATIC_IP not set. Skipping wildcard record creation."
    fi
    
    echo "Technitium DNS configured."
}

# Nginx Proxy Manager
npm_create_user() {
    
    echo "Creating NPM user..."
    
    # check if NPM is ready
    wait_for_url "${NPM_API_BASE}/" || exit 1

    # Create User (only works if DB is empty)
    CREATE_PAYLOAD=$(jq -n \
        --arg name "$NPM_ADMIN_NAME" \
        --arg email "$NPM_ADMIN_EMAIL" \
        --arg nick "$NPM_ADMIN_NICKNAME" \
        --arg pass "$NPM_ADMIN_PASSWORD" \
        '{name: $name, email: $email, nickname: $nick, auth: {type: "password", secret: $pass}}')

    curl -s -X POST "${NPM_API_BASE}/users" \
        -H "Content-Type: application/json" \
        -d "$CREATE_PAYLOAD" > /dev/null

    # Login with NPM Credentials
    echo "Logging in with NPM credentials..."
    NPM_TOKEN=$(curl -s -X POST "${NPM_API_BASE}/tokens" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg u "$NPM_ADMIN_EMAIL" --arg p "$NPM_ADMIN_PASSWORD" '{identity: $u, secret: $p}')" \
        | jq -r '.token')

    if [ -z "$NPM_TOKEN" ] || [ "$NPM_TOKEN" = "null" ]; then
        echo "FATAL: Failed to login to NPM."
        exit 1
    fi

    echo "Logged in successfully."
}

# upload certs
npm_upload_ssl() {
    CERT_ID=0
    CERT_FILE="/certs/${DNS_ZONE}.pem"
    KEY_FILE="/certs/${DNS_ZONE}-key.pem"

    echo "DEBUG: Starting npm_upload_ssl"
    echo "DEBUG: Checking for certificate files..."
    ls -l "/certs/"

    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "DEBUG: Certificate files found."
        
        echo "DEBUG: Fetching existing certificates from NPM..."
        ALL_CERTS_RESP=$(curl -s -X GET "${NPM_API_BASE}/nginx/certificates" \
            -H "Authorization: Bearer ${NPM_TOKEN}")
            
        # Check if response is valid JSON
        if ! echo "$ALL_CERTS_RESP" | jq -e . >/dev/null 2>&1; then
            echo "ERROR: Failed to get certificates list. Response was not JSON:"
            echo "$ALL_CERTS_RESP"
            # Proceeding might be dangerous if token is invalid, but we'll try upload if ID check fails naturally
        fi

        EXISTING_CERT_ID=$(echo "$ALL_CERTS_RESP" | jq -r ".[] | select(.domain_names[] == \"*.${DNS_ZONE}\") | .id" | head -n 1)

        if [ -n "$EXISTING_CERT_ID" ] && [ "$EXISTING_CERT_ID" != "null" ]; then
            echo "Certificate exists (ID: ${EXISTING_CERT_ID})."
            CERT_ID=$EXISTING_CERT_ID
        else
            echo "Certificate not found. Uploading..."
            
            # Use -w to capture status code
            UPLOAD_RESP=$(curl -s -w "\n%{http_code}" -X POST "${NPM_API_BASE}/nginx/certificates" \
                -H "Authorization: Bearer ${NPM_TOKEN}" \
                -F "provider=other" \
                -F "nice_name=${DNS_ZONE}" \
                -F "certificate=@${CERT_FILE}" \
                -F "certificate_key=@${KEY_FILE}")
            
            HTTP_BODY=$(echo "$UPLOAD_RESP" | sed '$d')
            HTTP_STATUS=$(echo "$UPLOAD_RESP" | tail -n 1)

            echo "DEBUG: Upload Response Status: $HTTP_STATUS"
            echo "DEBUG: Upload Response Body: $HTTP_BODY"
            
            CERT_ID=$(echo "$HTTP_BODY" | jq -r '.id')
            if [ "$CERT_ID" = "null" ] || [ -z "$CERT_ID" ]; then
                echo "Error uploading cert: $HTTP_BODY"
                CERT_ID=0
            else
                echo "Certificate uploaded successfully (ID: $CERT_ID)."
            fi
        fi
    else
        echo "ERROR: Certificate files not found at $CERT_FILE or $KEY_FILE"
    fi
}

# create proxy hosts
npm_create_proxy_host() {
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
        --argjson enabled true \
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
            ssl_forced: $ssl,
            enabled: $enabled
        }')

    # Check existence
    EXISTING_ID=$(curl -s -X GET "${NPM_API_BASE}/nginx/proxy-hosts" \
        -H "Authorization: Bearer ${NPM_TOKEN}" | jq -r ".[] | select(.domain_names[] == \"${DOMAIN}\") | .id")

    if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
        echo "Proxy host for $DOMAIN already exists. Skipping."
    else
        echo "Creating new host: $DOMAIN..."
        RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${NPM_API_BASE}/nginx/proxy-hosts" \
            -H "Authorization: Bearer ${NPM_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD")

        BODY=$(echo "$RESPONSE" | sed '$d')
        STATUS=$(echo "$RESPONSE" | tail -n 1)

        if [ "$STATUS" = "201" ] || [ "$STATUS" = "200" ]; then
            echo "Success: Created host $DOMAIN (Status: $STATUS)"
            sleep 1
        else
            echo "Error: Failed to create host $DOMAIN. Status: $STATUS"
            echo "Response: $BODY"
        fi
    fi
}

# Service Definitions

validate_env_vars
generate_certs
setup_dns
npm_create_user
npm_upload_ssl

services=(
    "$PORTAINER_CONTAINER_NAME;$PORTAINER_WEB_PORT_HTTPS;$CERT_ID;https"
    "$CLOUDBEAVER_CONTAINER_NAME;$CLOUDBEAVER_PORT;$CERT_ID;http"
    "$REDIS_INSIGHT_CONTAINER_NAME;$REDIS_INSIGHT_PORT;$CERT_ID;http"
    "$MAILPIT_CONTAINER_NAME;$MAILPIT_WEB_PORT;$CERT_ID;http"
    "$NPM_CONTAINER_NAME;$NPM_WEB_PORT;$CERT_ID;http"
    "$TECHNITIUM_CONTAINER_NAME;$TECHNITIUM_WEB_PORT;$CERT_ID;http"
    "$HOMEPAGE_CONTAINER_NAME;$HOMEPAGE_PORT;$CERT_ID;http"
    "cert-server;80;$CERT_ID;http"
)

for service in "${services[@]}"; do
    # Split the string into a temporary array named 'service_array'
    IFS=';' read -r -a service_array <<< "$service"

    # Map to readable names (optional, but makes debugging easier)
    name="${service_array[0]}"
    port="${service_array[1]}"
    cert="${service_array[2]}"
    proto="${service_array[3]}"

    # 2. FIX: Check if the CURRENT name is valid, not the global Portainer variable
    if [ -n "$name" ]; then 
        npm_create_proxy_host "$name" "$port" "$cert" "$proto"
    fi

    echo "Created proxy host for $name"
    echo "Sleeping for 2 seconds... (to ensure NPM has time to process... gimmicky i know)"
    sleep 2
done