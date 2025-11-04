#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
OPEN_BALENA_DIR="${PROJECT_ROOT}/open-balena"
CONFIG_DIR="${PROJECT_ROOT}/config"

# Check Docker access
if ! docker ps &>/dev/null; then
    echo "Error: Cannot access Docker daemon"
    echo ""
    echo "This script requires Docker access. Please do one of the following:"
    echo ""
    echo "Option 1 - Add your user to the docker group (recommended):"
    echo "  sudo usermod -aG docker \$USER"
    echo "  newgrp docker"
    echo "  # Or logout and login again"
    echo ""
    echo "Option 2 - Run this script with sudo:"
    echo "  sudo ./scripts/install-openbalena.sh generate-config ..."
    echo ""
    echo "Current user: $(whoami)"
    echo "Docker socket: /var/run/docker.sock"
    exit 1
fi

# Verify kubernetes cluster is accessible
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: Cannot connect to kubernetes cluster"
    echo "Please ensure:"
    echo "  - kubectl is configured with a valid context"
    echo "  - Your kubernetes cluster is running and accessible"
    echo ""
    echo "Current context: $(kubectl config current-context 2>/dev/null || echo 'none')"
    exit 1
fi

echo "Using kubernetes context: $(kubectl config current-context)"

# Create namespaces
kubectl create namespace openbalena 2>/dev/null || true

# Install / update helm chart dependencies
helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts
helm repo update haproxy-ingress
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update stakater

# Optionally generate open-balena config
if [ "$1" == "generate-config" ]; then
    echo "Generating openbalena config..."
    if [[ ( -z "$2" || -z "$3" || -z "$4" || -z "$5" ) ]]; then
      echo "Usage: $0 generate-config <hostname> <cert-email> <superuser-password> <database-password>"
      echo ""
      echo "Parameters:"
      echo "  hostname             - Domain name for openBalena (e.g., openbalena.local)"
      echo "  cert-email          - Email address for certificate notifications"
      echo "  superuser-password  - Password for the admin user"
      echo "  database-password   - Password for PostgreSQL database"
      exit 1
    fi

    HOSTNAME="$2"
    CERT_EMAIL="$3"
    SUPERUSER_PASSWORD="$4"
    DB_PASSWORD="$5"

    echo "==> Cleaning up old configuration..."
    rm -rf "${PROJECT_ROOT}/open-balena/config"
    mkdir -p "${PROJECT_ROOT}/open-balena/config"

    echo "==> Generating configuration using docker-compose..."

    # Generate config using Makefile (must be run in open-balena directory)
    (cd "${OPEN_BALENA_DIR}" && make config DNS_TLD="${HOSTNAME}" \
                                            SUPERUSER_EMAIL="admin@${HOSTNAME}" \
                                            ORG_UNIT="openBalena")

    # Start only essential services to generate certificates and secrets
    # We don't need test services like 'dut', 'sut', etc.
    echo "==> Starting essential docker-compose services to generate certificates and secrets..."

    # Start core services: db, redis, s3, cert-manager, haproxy, haproxy-sidecar, api, vpn, registry
    docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" up -d \
        db redis s3 cert-manager haproxy haproxy-sidecar api vpn registry

    # Wait for cert-manager to generate certificates
    echo "==> Waiting for certificate generation (this may take a minute)..."
    sleep 10

    # Wait for api service to be healthy and generate all secrets
    echo "==> Waiting for API service to initialize..."
    until [ "$(docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" ps api --format json | jq -r '.Health' 2>/dev/null)" = "healthy" ]; do
        printf '.'
        sleep 3
    done
    printf '\n'

    # Extract environment variables from the running API container
    echo "==> Extracting configuration from running containers..."
    mkdir -p "${PROJECT_ROOT}/open-balena/config"

    # Create activate script with all necessary environment variables
    cat > "${PROJECT_ROOT}/open-balena/config/activate" <<EOF
# OpenBalena Configuration
export OPENBALENA_HOST_NAME="${HOSTNAME}"
export OPENBALENA_SUPERUSER_EMAIL="admin@${HOSTNAME}"
export OPENBALENA_SUPERUSER_PASSWORD="${SUPERUSER_PASSWORD}"
export OPENBALENA_DB_USERNAME="docker"
export OPENBALENA_DB_PASSWORD="${DB_PASSWORD}"
export OPENBALENA_CERT_EMAIL="${CERT_EMAIL}"
export OPENBALENA_SSH_AUTHORIZED_KEYS=""

# Extract secrets from running API container
EOF

    # Extract all the secrets from the API container's environment
    docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" exec -T api cat config/env | grep -E "^(COOKIE_SESSION_SECRET|JSON_WEB_TOKEN_SECRET|VPN_SERVICE_API_KEY|API_SERVICE_API_KEY|REGISTRY_SECRET_KEY|TOKEN_AUTH_BUILDER_TOKEN)=" | while read line; do
        VAR_NAME=$(echo "$line" | cut -d= -f1)
        VAR_VALUE=$(echo "$line" | cut -d= -f2-)
        echo "export OPENBALENA_${VAR_NAME}=\"${VAR_VALUE}\"" >> "${PROJECT_ROOT}/open-balena/config/activate"
    done

    # Extract S3 credentials
    docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" exec -T s3 cat config/env | grep -E "^(S3_MINIO_ACCESS_KEY|S3_MINIO_SECRET_KEY)=" | while read line; do
        VAR_NAME=$(echo "$line" | cut -d= -f1)
        VAR_VALUE=$(echo "$line" | cut -d= -f2-)
        if [ "$VAR_NAME" = "S3_MINIO_ACCESS_KEY" ]; then
            echo "export OPENBALENA_S3_ACCESS_KEY=\"${VAR_VALUE}\"" >> "${PROJECT_ROOT}/open-balena/config/activate"
        elif [ "$VAR_NAME" = "S3_MINIO_SECRET_KEY" ]; then
            echo "export OPENBALENA_S3_SECRET_KEY=\"${VAR_VALUE}\"" >> "${PROJECT_ROOT}/open-balena/config/activate"
        fi
    done

    # Extract VPN DH params (this needs to be extracted from the VPN service)
    VPN_DH=$(docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" exec -T vpn cat /etc/openvpn/dh.pem 2>/dev/null | base64 -w 0 2>/dev/null || docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" exec -T vpn cat /etc/openvpn/dh.pem 2>/dev/null | base64)
    echo "export OPENBALENA_VPN_SERVER_DH=\"${VPN_DH}\"" >> "${PROJECT_ROOT}/open-balena/config/activate"

    # Copy certificates to a temporary location
    echo "==> Copying certificates..."
    mkdir -p "${PROJECT_ROOT}/open-balena/config/certs"
    docker cp $(docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" ps -q cert-manager):/certs/export/ "${PROJECT_ROOT}/open-balena/config/certs/" || {
        echo "Warning: Could not copy certificates from cert-manager. They may not be ready yet."
        echo "Attempting to extract from volumes..."

        # Alternative: extract from haproxy container which also has access to certs
        docker cp $(docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" ps -q haproxy):/certs/ "${PROJECT_ROOT}/open-balena/config/certs/" 2>/dev/null || true
    }

    # Stop the docker-compose stack
    echo "==> Stopping docker-compose stack..."
    docker compose -f "${OPEN_BALENA_DIR}/docker-compose.yml" down

    echo "==> Configuration generated successfully!"
    echo "Configuration saved to: ${PROJECT_ROOT}/open-balena/config/activate"

else
    if [ ! -f "${PROJECT_ROOT}/open-balena/config/activate" ]; then
        echo "Error: No existing config found!"
        echo "Please run: $0 generate-config <hostname> <cert-email> <superuser-password> <database-password>"
        exit 1
    fi
fi

# Configure helm values
source "$(dirname "$0")/../open-balena/config/activate";
envsubst < "$(dirname "$0")/../config/values.template.yaml" > "$(dirname "$0")/../config/values.yaml"

# Prepare certs for helm deployment
echo "==> Preparing certificates for Helm deployment..."
CERTS_DIR="${SCRIPT_DIR}/../open-balena/config/certs"
HELM_CERTS_DIR="${SCRIPT_DIR}/../helm/certs"
mkdir -p "${HELM_CERTS_DIR}"

# New cert-manager structure uses /certs/export directory
# The certs are organized differently - need to adapt to the new structure
if [ -d "${CERTS_DIR}/export" ]; then
    EXPORT_DIR="${CERTS_DIR}/export"

    # Root CA
    if [ -f "${EXPORT_DIR}/ca.crt" ]; then
        cp "${EXPORT_DIR}/ca.crt" "${HELM_CERTS_DIR}/root-ca.crt"
    fi

    # Root certificate and key (wildcard cert)
    if [ -f "${EXPORT_DIR}/chain.pem" ]; then
        cp "${EXPORT_DIR}/chain.pem" "${HELM_CERTS_DIR}/root-cert.crt"
    fi
    if [ -f "${EXPORT_DIR}/privkey.pem" ]; then
        cp "${EXPORT_DIR}/privkey.pem" "${HELM_CERTS_DIR}/root-cert.key"
    fi

    # API certs (same as root in new structure with wildcard)
    if [ -f "${EXPORT_DIR}/chain.pem" ]; then
        cp "${EXPORT_DIR}/chain.pem" "${HELM_CERTS_DIR}/api-cert.crt"
    fi
    if [ -f "${EXPORT_DIR}/privkey.pem" ]; then
        cp "${EXPORT_DIR}/privkey.pem" "${HELM_CERTS_DIR}/api-cert.key"
    fi

    # VPN certs
    if [ -f "${EXPORT_DIR}/ca.crt" ]; then
        cp "${EXPORT_DIR}/ca.crt" "${HELM_CERTS_DIR}/vpn-ca.crt"
    fi
    if [ -f "${EXPORT_DIR}/vpn.crt" ]; then
        cp "${EXPORT_DIR}/vpn.crt" "${HELM_CERTS_DIR}/vpn-cert.crt"
    elif [ -f "${EXPORT_DIR}/chain.pem" ]; then
        cp "${EXPORT_DIR}/chain.pem" "${HELM_CERTS_DIR}/vpn-cert.crt"
    fi
    if [ -f "${EXPORT_DIR}/vpn.key" ]; then
        cp "${EXPORT_DIR}/vpn.key" "${HELM_CERTS_DIR}/vpn-cert.key"
    elif [ -f "${EXPORT_DIR}/privkey.pem" ]; then
        cp "${EXPORT_DIR}/privkey.pem" "${HELM_CERTS_DIR}/vpn-cert.key"
    fi
    if [ -f "${EXPORT_DIR}/dh.pem" ]; then
        cp "${EXPORT_DIR}/dh.pem" "${HELM_CERTS_DIR}/vpn-dh.pem"
    fi
else
    echo "Warning: Certificate export directory not found at ${CERTS_DIR}/export"
    echo "Checking alternative certificate locations..."

    # Fallback to direct copy from docker volumes if export failed
    if [ -d "${CERTS_DIR}" ]; then
        find "${CERTS_DIR}" -type f -name "*.crt" -o -name "*.pem" -o -name "*.key" | head -10
    fi
fi

# Verify required certificates exist
REQUIRED_CERTS=("root-ca.crt" "root-cert.crt" "root-cert.key" "api-cert.crt" "api-cert.key" "vpn-ca.crt" "vpn-cert.crt" "vpn-cert.key" "vpn-dh.pem")
MISSING_CERTS=()

for cert in "${REQUIRED_CERTS[@]}"; do
    if [ ! -f "${HELM_CERTS_DIR}/${cert}" ]; then
        MISSING_CERTS+=("${cert}")
    fi
done

if [ ${#MISSING_CERTS[@]} -gt 0 ]; then
    echo "Warning: The following certificates are missing:"
    printf '  - %s\n' "${MISSING_CERTS[@]}"
    echo ""
    echo "This may cause issues with the Helm deployment."
    echo "Please check the certificate generation process."
fi

# Install openbalena
helm install openbalena $(dirname "$0")/../helm -f $(dirname "$0")/../config/values.yaml -n openbalena --dependency-update --wait \
    --set issuers.acme.email=$OPENBALENA_CERT_EMAIL