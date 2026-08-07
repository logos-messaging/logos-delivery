#!/bin/sh
set -e

if [ -z "$DOMAIN" ]; then
  echo "DOMAIN not set, skipping certbot"
  exit 0
fi

# -------------------------------
# Configuration
# -------------------------------
EMAIL="${EMAIL:-admin@${DOMAIN}}"      # Certbot email
WEBROOT="${WEBROOT:-/var/www/certbot}" # Path served by HTTP for ACME
SLEEP_INTERVAL="${SLEEP_INTERVAL:-12h}" # Renewal check interval

# Ensure webroot directory exists
mkdir -p "${WEBROOT}/.well-known/acme-challenge"

# Path to cert folder
LETSENCRYPT_PATH="/etc/letsencrypt/live/${DOMAIN}"

# -------------------------------
# Initial certificate issuance
# -------------------------------
if [ ! -d "${LETSENCRYPT_PATH}" ]; then
    echo "[INFO] No certificate found for ${DOMAIN}, issuing a new one..."

    # Install certbot if needed (Alpine example)
    if ! command -v certbot >/dev/null 2>&1; then
        echo "[INFO] Installing certbot..."
        apk add --no-cache certbot
    fi

    certbot certonly\
        --non-interactive\
        --agree-tos\
        --no-eff-email\
        --no-redirect\
        --email admin@${DOMAIN}\
        -d ${DOMAIN}\
        --standalone

    echo "[INFO] Certificate issued successfully."
else
    echo "[INFO] Certificate already exists for ${DOMAIN}."
fi

# -------------------------------
# Renewal loop
# -------------------------------
echo "[INFO] Starting renewal loop every ${SLEEP_INTERVAL}..."
while true; do
    echo "[INFO] Checking certificate renewal..."
    certbot renew --standalone --quiet
    # certbot renew --standalone ## Use this line instead to debug the output
    echo "[INFO] Renewal check complete. Sleeping..."
    sleep "${SLEEP_INTERVAL}"
done


