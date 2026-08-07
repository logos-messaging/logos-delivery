#!/bin/sh

echo "I am a Logos Messaging (logosdeliverynode) node"

MY_EXT_IP=$(wget -qO- https://api4.ipify.org)
DNS_WSS_CMD=

# WebSocket-Secure is enabled only when the operator explicitly sets DOMAIN in
# .env -- the same condition under which the certbot service issues a
# certificate. We deliberately do NOT auto-guess DOMAIN from reverse DNS: on a
# host whose PTR forward-resolves back to the same IP, that would set DOMAIN and
# deadlock the node in the cert-wait loop below, waiting for a certificate that
# certbot (DOMAIN unset) never issues.
if [ -n "${DOMAIN}" ]; then
    ## A domain has been set. Let's try to use it for websocket secure support.

    apk add --no-cache openssl

    LETSENCRYPT_PATH="/etc/letsencrypt/live/${DOMAIN}"
    CERT="${LETSENCRYPT_PATH}/fullchain.pem"
    KEY="${LETSENCRYPT_PATH}/privkey.pem"

    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Waiting for a valid TLS certificate for ${DOMAIN}..."

    while true; do
        if [ ! -f "${CERT}" ] || [ ! -f "${KEY}" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Certificate files not found yet. Waiting..."
        elif ! openssl x509 -checkend 0 -noout -in "${CERT}" >/dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Certificate exists but is expired. Waiting for renewal..."
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] If that takes more than 15 minutes, please remove --quiet attr in run_certbot.sh so that you can see the reason why renewal is not working."
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Valid TLS certificate detected."
            break
        fi

        sleep 60
    done

    WS_SUPPORT="--websocket-support=true"
    WSS_SUPPORT="--websocket-secure-support=true"
    WSS_KEY="--websocket-secure-key-path=${KEY}"
    WSS_CERT="--websocket-secure-cert-path=${CERT}"
    DNS4_DOMAIN="--dns4-domain-name=${DOMAIN}"

    DNS_WSS_CMD="${WS_SUPPORT} ${WSS_SUPPORT} ${WSS_CERT} ${WSS_KEY} ${DNS4_DOMAIN}"
fi


if [ -n "${NODEKEY}" ]; then
    NODEKEY=--nodekey=${NODEKEY}
fi

STORE_RETENTION_POLICY=--store-message-retention-policy=size:1GB

if [ -n "${STORAGE_SIZE}" ]; then
    STORE_RETENTION_POLICY=--store-message-retention-policy=size:"${STORAGE_SIZE}"
fi

# Network preset and top API layer are configurable via env (see .env.example).
# Defaults:
#   PRESET=logos.dev   -> cluster-id=2, auto-sharding (8 shards), bootstrap nodes, RLN off
#   ENTRY_LAYER=kernel -> transport only (no messaging/channels layer); also skips
#                         mode application, so the explicit protocol flags below are honored
# Set PRESET empty to run without a network preset (then define cluster/shards via EXTRA_ARGS).
# `--entry-layer` is always passed because the binary's own default is `channels`, not kernel.
PRESET="${PRESET-logos.dev}"
ENTRY_LAYER="${ENTRY_LAYER:-kernel}"

PRESET_ARG=
if [ -n "${PRESET}" ]; then
    PRESET_ARG=--preset="${PRESET}"
fi

exec /usr/local/bin/logosdeliverynode\
    ${PRESET_ARG}\
    --entry-layer="${ENTRY_LAYER}"\
    --relay=true\
    --filter=true\
    --lightpush=true\
    --peer-exchange=true\
    --mix=true\
    --keep-alive=true\
    --max-connections=150\
    --discv5-discovery=true\
    --discv5-udp-port=9005\
    --discv5-enr-auto-update=True\
    --log-level=DEBUG\
    --tcp-port=30304\
    --metrics-server=True\
    --metrics-server-port=8003\
    --metrics-server-address=0.0.0.0\
    --rest=true\
    --rest-admin=true\
    --rest-address=0.0.0.0\
    --rest-port=8645\
    --rest-allow-origin="logos-messaging.github.io"\
    --rest-allow-origin="localhost:*"\
    --nat=extip:"${MY_EXT_IP}"\
    --store=true\
    --store-message-db-url="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/postgres"\
    ${DNS_WSS_CMD}\
    ${NODEKEY}\
    ${STORE_RETENTION_POLICY}\
    ${EXTRA_ARGS}
