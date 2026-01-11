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


if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: 'openssl' is not installed. Please install it."
    exit 1
fi

# Load environment variables
if [ -f /.env ]; then
    . /.env
fi

# Technitium Configuration
TECHNITIUM_API_BASE="http://${TECHNITIUM_CONTAINER_NAME}:${TECHNITIUM_WEB_PORT:-5380}/api"
DNS_ZONE="${DNS_ZONE:-dev.local}"
TECHNITIUM_USER=admin
TECHNITIUM_PASS=admin

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

    if [ -z "$TECHNITIUM_USER" ]; then
        echo "Error: TECHNITIUM_USER is not set."
        exit 1
    fi

    if [ -z "$TECHNITIUM_PASS" ]; then
        echo "Error: TECHNITIUM_PASS is not set."
        exit 1
    fi

    if [ -z "$TECHNITIUM_WEB_PORT" ]; then
        echo "Error: TECHNITIUM_WEB_PORT is not set."
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
    pretty_name="$2"
    max_retries=60
    count=0
    while [ $count -lt $max_retries ]; do
        # Use curl to get HTTP code only, silent output
        status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
        
        if [ "$status_code" = "200" ]; then
            return 0
        fi
        
        if [ $((count % 5)) -eq 0 ]; then
            echo "Wait attempt $((count+1))/$max_retries. Status: $status_code"
        fi
        
        sleep 2
        count=$((count + 1))
    done
    
    echo "Timeout waiting for $pretty_name. Last status: $status_code"
    # Try one verbose curl to show error detail to logs before failing
    curl -v "$url"
    return 1
}

# SSL Certificate Generation
generate_certs() {

    local CA_EXISTS=0
    local LEAF_EXISTS=0

    # Certificate Configuration
    CERTS_DIR="/certs"
    ROOT_CA_DIR="${CERTS_DIR}/ca"
    ROOT_CA_CERT_DIR="${ROOT_CA_DIR}/public"
    ROOT_CA_KEY_DIR="${ROOT_CA_DIR}/private"
    ROOT_CA_CERT="root-ca.crt"
    ROOT_CA_KEY="root-ca.key"

    # Domain Certs
    LEAF_DIR="${CERTS_DIR}/${DNS_ZONE}"
    LEAF_CSR="${DNS_ZONE}.csr"
    LEAF_CERT="${DNS_ZONE}.crt"
    LEAF_KEY="${DNS_ZONE}.key"


    echo "Generating SSL certificates..."

    # early return if certs dir is not mounted
    if [ ! -d "$CERTS_DIR" ]; then
        echo "Error: CERTS_DIR is not mounted. Skipping SSL certificate generation entirely."
        return
    fi

    # early return if openssl is not installed
    if ! command -v openssl >/dev/null 2>&1; then
        echo "Error: openssl is not installed. Skipping SSL certificate generation entirely."
        return
    fi

    # generate sub dirs if they don't exist
    mkdir -p "$ROOT_CA_CERT_DIR" "$ROOT_CA_KEY_DIR" "$LEAF_DIR"

    # Check for existing Root CA crt and key
    if [ -f "${ROOT_CA_CERT_DIR}/${ROOT_CA_CERT}" ] && [ -f "${ROOT_CA_KEY_DIR}/${ROOT_CA_KEY}" ]; then
        echo "Info: Root CA already exists. Skipping Root CA generation."
        CA_EXISTS=1
    fi

    # Verify if leaf cert exists for $DNS_ZONE
    if (( $CA_EXISTS )) && [ -f "${LEAF_DIR}/${LEAF_CERT}" ]; then
        # Verify if leaf cert matches current RootCA
        if openssl verify -CAfile "${ROOT_CA_CERT_DIR}/${ROOT_CA_CERT}" "${LEAF_DIR}/${LEAF_CERT}" >/dev/null 2>&1; then
            echo "Info: Leaf certificate already exists and matches RootCA. Skipping Leaf certificate generation."
            LEAF_EXISTS=1
        else
            echo "WARNING: Leaf certificate for $DNS_ZONE already exists but does not match RootCA."
            echo "Skipping generation to avoid state mismatch."
            return
        fi
    fi

    # Generate Root CA using openssl
    if (( ! $CA_EXISTS )); then
        echo "Generating Root CA..."
        openssl req -x509 -new -nodes -newkey rsa:2048 -sha256 -days 3650 \
            -keyout "${ROOT_CA_KEY_DIR}/${ROOT_CA_KEY}" \
            -out "${ROOT_CA_CERT_DIR}/${ROOT_CA_CERT}" \
            -subj "/C=BR/CN=Development Infrastructure Root CA" > /dev/null 2>&1

        # Set permissions
        chmod 600 "${ROOT_CA_KEY_DIR}/${ROOT_CA_KEY}"
        chmod 644 "${ROOT_CA_CERT_DIR}/${ROOT_CA_CERT}"
    fi

    # Generate CRT, CSR and Key for $DNS_ZONE using openSSL
    if (( ! $LEAF_EXISTS )); then
        echo "Generating Leaf Certificate for $DNS_ZONE..."
        openssl req -new -nodes -newkey rsa:2048 \
            -keyout "${LEAF_DIR}/${LEAF_KEY}" \
            -out "${LEAF_DIR}/${LEAF_CSR}" \
            -subj "/CN=${DNS_ZONE}" \
            -addext "subjectAltName = DNS:${DNS_ZONE},DNS:*.${DNS_ZONE}" > /dev/null 2>&1

        # Sign CSR with Root CA and create Leaf Certificate
        openssl x509 -req -in "${LEAF_DIR}/${LEAF_CSR}" \
            -CA "${ROOT_CA_CERT_DIR}/${ROOT_CA_CERT}" \
            -CAkey "${ROOT_CA_KEY_DIR}/${ROOT_CA_KEY}" \
            -CAcreateserial \
            -out "${LEAF_DIR}/${LEAF_CERT}" \
            -days 365 \
            -sha256 \
            -copy_extensions copy > /dev/null 2>&1

        # Set permissions
        chmod 600 "${LEAF_DIR}/${LEAF_KEY}"
        chmod 644 "${LEAF_DIR}/${LEAF_CERT}"
    fi
}

# Technitium DNS

dns_authenticate() {
    # Get Token
    DNS_TOKEN=$(curl -s -X POST "${TECHNITIUM_API_BASE}/user/login?user=${TECHNITIUM_USER}&pass=${TECHNITIUM_PASS}" | jq -r '.token')

    # Validate Token; exit if null
    if [ -z "$DNS_TOKEN" ] || [ "$DNS_TOKEN" = "null" ]; then
        echo "FATAL: Failed to login to Technitium DNS."
        exit 1
    fi
}

dns_create_zone() {
    # Check DNS Zone
    ZONE_EXISTS=$(curl -s -X GET "${TECHNITIUM_API_BASE}/zones/list?token=${DNS_TOKEN}&pageNumber=1&recordsPerPage=100" | jq -r ".response.zones[] | select(.name == \"${DNS_ZONE}\") | .name")

    if [ "$ZONE_EXISTS" = "$DNS_ZONE" ]; then
         echo "DNS Zone '$DNS_ZONE' already exists."
    else
         echo "Creating DNS Zone '$DNS_ZONE'..."
         curl -s -X POST "${TECHNITIUM_API_BASE}/zones/create?token=${DNS_TOKEN}&zone=${DNS_ZONE}&type=Primary" > /dev/null
    fi

}

dns_create_record() {
    
    TARGET_IP=${STATIC_IP%/*}
    WILDCARD_DOMAIN="*.${DNS_ZONE}"

    local url="${TECHNITIUM_API_BASE}/zones/records/get?token=${DNS_TOKEN}&domain=${WILDCARD_DOMAIN}&zone=${DNS_ZONE}&pageNumber=1&recordsPerPage=1000"
    RESPONSE=$(curl -s -X GET "${url}")
    RECORD_EXISTS=$(echo "$RESPONSE" | jq -r ".response.records[] | select(.name == \"${WILDCARD_DOMAIN}\") | .name")

    if [ "$RECORD_EXISTS" = "$WILDCARD_DOMAIN" ]; then
         echo "Wildcard record '$WILDCARD_DOMAIN' already exists."
         return
    fi

    echo "Creating Wildcard record '$WILDCARD_DOMAIN' pointing to $TARGET_IP..."

    curl -s -X POST "${TECHNITIUM_API_BASE}/zones/records/add?\
        token=${DNS_TOKEN}&\
        domain=${WILDCARD_DOMAIN}&\
        type=A&\
        value=${TARGET_IP}&\
        zone=${DNS_ZONE}" > /dev/null    
}

# Nginx Proxy Manager

npm_create_user() {    
    # Create Initial User (only works if DB is empty)
    echo "Attempting to create NPM initial user..."
    CREATE_PAYLOAD=$(jq -n \
        --arg name "$NPM_ADMIN_NAME" \
        --arg email "$NPM_ADMIN_EMAIL" \
        --arg nick "$NPM_ADMIN_NICKNAME" \
        --arg pass "$NPM_ADMIN_PASSWORD" \
        '{name: $name, email: $email, nickname: $nick, auth: {type: "password", secret: $pass}}')

    # Perform Request with curl
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${NPM_API_BASE}/users" \
        -H "Content-Type: application/json" \
        -d "$CREATE_PAYLOAD")

    # These fuckers don't use proper HTTP status codes
    # 200 and 201 are successful
    # 404 means unauthorized
    HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; then
        echo "Initial user created using environment variables."
    fi

    if [ "$HTTP_STATUS" = "404" ]; then
        echo "NPM already has registered users."
    fi

}

npm_authenticate() {
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

npm_upload_ssl() {
    CERT_ID=0

    # Early return if files are not found
    if [ ! -f "$LEAF_DIR/$LEAF_CERT" ] || [ ! -f "$LEAF_DIR/$LEAF_KEY" ]; then
        echo "WARNING: LEAF_CERT or LEAF_KEY not found. Skipping certificate upload."
        return
    fi

    # Read local cert content for validation
    local LOCAL_CERT=$(cat "$LEAF_DIR/$LEAF_CERT")

    # This is bloated:
    # It does a request to NPM's internal API, piping the result to jq as text
    # jq parses the text into valid json and filters it by matching the domain and cert content
    # sort -nr sorts the result in reverse (newest, highest id first)
    # head -n 1 gets the first result (last cert uploaded)
    # if no match returns null
    #
    # Terrible code, because we are doing way too much in a single unit of code.
    # we cannot separate it because it would require a lot of serializing and deserializing
    # since we are manipulating strings and relying on piping blackmagic
    # but hey, thats the bash lifestyle I guess.
    # Also we are assuming that the last cert uploaded is the one we want...

    CERT_ID=$(
        curl -s -X GET "${NPM_API_BASE}/nginx/certificates" \
            -H "Authorization: Bearer ${NPM_TOKEN}" |
          jq -r \
            --arg target_domain "$DNS_ZONE" \
            --arg target_cert "$LOCAL_CERT" ' .[] | select((.domain_names // [] | any(. == $target_domain)) and ((.meta.certificate // "" | gsub("\\s";"")) == ($target_cert | gsub("\\s";"")))) | .id ' |
        sort -nr |
        head -n1
    )

    # Upload the certificate if no matches
    if [ -z "$CERT_ID" ]; then
            
        # Create the certificate entry (metadata only)
        echo "Creating certificate entry for: $DNS_ZONE"

        # jq for creating the json payload
        local CREATE_PAYLOAD=$(jq -n --arg name "$DNS_ZONE" '{nice_name: $name, provider: "other"}')
            
        # curl for creating the certificate entry
        local CREATE_RESP=$(curl -s -X POST "${NPM_API_BASE}/nginx/certificates" \
                -H "Authorization: Bearer ${NPM_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$CREATE_PAYLOAD")

        # extract the id from the response    
        CERT_ID=$(echo "$CREATE_RESP" | jq -r '.id')

        echo "Certificate entry created with ID: $CERT_ID"

        # check if the certificate entry was created successfully
        if [ "$CERT_ID" = "null" ] || [ -z "$CERT_ID" ]; then
            echo "ERROR: Failed to create certificate entry."
            echo "Skipping certificate upload."
            
            # for debugging purposes
            echo "Response: $CREATE_RESP"
            return
        fi

        # upload certificate files
        echo "Uploading certificate files for: $DNS_ZONE to entry with ID: $CERT_ID"

        # curl for uploading the certificate files
        local url="${NPM_API_BASE}/nginx/certificates/${CERT_ID}/upload"
        local UPLOAD_RESP=$(curl -s -w "\n%{http_code}" -X POST $url \
                -H "Authorization: Bearer ${NPM_TOKEN}" \
                -H "Content-Type: multipart/form-data" \
                -F "certificate=@${LEAF_DIR}/${LEAF_CERT}" \
                -F "certificate_key=@${LEAF_DIR}/${LEAF_KEY}"
                )

        local HTTP_STATUS=$(echo "$UPLOAD_RESP" | tail -n 1)
            
        # check if the upload was successful
        if [ "$HTTP_STATUS" != "200" ] && [ "$HTTP_STATUS" != "201" ]; then
            
            # Cleanup failed entry
            curl -s -X DELETE "${NPM_API_BASE}/nginx/certificates/${CERT_ID}" \
                -H "Authorization: Bearer ${NPM_TOKEN}" > /dev/null
            
            # for debugging purposes
            echo "Response: $UPLOAD_RESP"

            echo "Failed to upload certificate files. Certificate entry deleted."
            
            CERT_ID=0
            return
        fi
        echo "Certificate uploaded successfully (ID: $CERT_ID)."
    else
        echo "Valid certificate already exists (ID: $CERT_ID)."
    fi
}

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

echo "Starting initialization..."
validate_env_vars
generate_certs

# Technitium DNS Setup
wait_for_url "${TECHNITIUM_API_BASE}/" "Technitium DNS" || exit 1
dns_authenticate
dns_create_zone
dns_create_record

# Nginx Proxy Manager Setup
wait_for_url "${NPM_API_BASE}/" "NPM" || exit 1
npm_create_user
npm_authenticate
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
    "$RESTFOX_CONTAINER_NAME;$RESTFOX_PORT;$CERT_ID;http"
    "$MONGOKU_CONTAINER_NAME;$MONGOKU_PORT;$CERT_ID;http"
    "$NATS_NUI_CONTAINER_NAME;$NATS_NUI_PORT;$CERT_ID;http"
)

for service in "${services[@]}"; do
    IFS=';' read -r -a service_array <<< "$service"

    name="${service_array[0]}"
    port="${service_array[1]}"
    cert="${service_array[2]}"
    proto="${service_array[3]}"

    if [ -n "$name" ]; then 
        npm_create_proxy_host "$name" "$port" "$cert" "$proto"
    fi
done

exit 0
