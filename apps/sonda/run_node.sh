#!/bin/sh

echo "I am a nwaku node"

if test -n "${ETH_CLIENT_ADDRESS}" -o ; then
  echo "ETH_CLIENT_ADDRESS variable was renamed to RLN_RELAY_ETH_CLIENT_ADDRESS"
  echo "Please update your .env file"
  exit 1
fi

if [ -z "${RLN_RELAY_ETH_CLIENT_ADDRESS}" ] && [ "${CLUSTER_ID}" -eq 1 ]; then
    echo "Missing Eth client address, please refer to README.md for detailed instructions"
    exit 1
fi

if [ "${CLUSTER_ID}" -ne 1 ]; then
    echo "CLUSTER_ID is not equal to 1, clearing RLN configurations"
    RLN_RELAY_CRED_PATH=""
    RLN_RELAY_ETH_CLIENT_ADDRESS=""
    RLN_RELAY_CRED_PASSWORD=""
fi

MY_EXT_IP=$(wget -qO- https://api4.ipify.org)
DNS_WSS_CMD=

if [ -n "${DOMAIN}" ]; then

    LETSENCRYPT_PATH=/etc/letsencrypt/live/${DOMAIN}

    if ! [ -d "${LETSENCRYPT_PATH}" ]; then
        apk add --no-cache certbot

        certbot certonly\
            --non-interactive\
            --agree-tos\
            --no-eff-email\
            --no-redirect\
            --email admin@${DOMAIN}\
            -d ${DOMAIN}\
            --standalone
    fi

    if ! [ -e "${LETSENCRYPT_PATH}/privkey.pem" ]; then
        echo "The certificate does not exist"
        sleep 60
        exit 1
    fi

    WS_SUPPORT="--websocket-support=true"
    WSS_SUPPORT="--websocket-secure-support=true"
    WSS_KEY="--websocket-secure-key-path=${LETSENCRYPT_PATH}/privkey.pem"
    WSS_CERT="--websocket-secure-cert-path=${LETSENCRYPT_PATH}/cert.pem"
    DNS4_DOMAIN="--dns4-domain-name=${DOMAIN}"

    DNS_WSS_CMD="${WS_SUPPORT} ${WSS_SUPPORT} ${WSS_CERT} ${WSS_KEY} ${DNS4_DOMAIN}"
fi

if [ -n "${NODEKEY}" ]; then
    NODEKEY=--nodekey=${NODEKEY}
fi

if [ "${CLUSTER_ID}" -eq 1 ]; then
    RLN_RELAY_CRED_PATH=--rln-relay-cred-path=${RLN_RELAY_CRED_PATH:-/keystore/keystore.json}
fi

if [ -n "${RLN_RELAY_CRED_PASSWORD}" ]; then
    RLN_RELAY_CRED_PASSWORD=--rln-relay-cred-password="${RLN_RELAY_CRED_PASSWORD}"
fi

if [ -n "${RLN_RELAY_ETH_CLIENT_ADDRESS}" ]; then
    RLN_RELAY_ETH_CLIENT_ADDRESS=--rln-relay-eth-client-address="${RLN_RELAY_ETH_CLIENT_ADDRESS}"
fi

# TO DO: configure bootstrap nodes in env

exec /usr/bin/logosdeliverynode\
  --relay=true\
  --filter=false\
  --lightpush=false\
  --keep-alive=true\
  --max-connections=150\
  --cluster-id="${CLUSTER_ID}"\
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
  --rest-allow-origin="waku-org.github.io"\
  --rest-allow-origin="localhost:*"\
  --nat=extip:"${MY_EXT_IP}"\
  --store=false\
  --pubsub-topic="/waku/2/rs/${CLUSTER_ID}/${SHARD}"\
  --discv5-bootstrap-node="enr:-QEKuECA0zhRJej2eaOoOPddNcYr7-5NdRwuoLCe2EE4wfEYkAZhFotg6Kkr8K15pMAGyUyt0smHkZCjLeld0BUzogNtAYJpZIJ2NIJpcISnYxMvim11bHRpYWRkcnO4WgAqNiVib290LTAxLmRvLWFtczMuc2hhcmRzLnRlc3Quc3RhdHVzLmltBnZfACw2JWJvb3QtMDEuZG8tYW1zMy5zaGFyZHMudGVzdC5zdGF0dXMuaW0GAbveA4Jyc40AEAUAAQAgAEAAgAEAiXNlY3AyNTZrMaEC3rRtFQSgc24uWewzXaxTY8hDAHB8sgnxr9k8Rjb5GeSDdGNwgnZfg3VkcIIjKIV3YWt1Mg0"\
  --discv5-bootstrap-node="enr:-QEcuEAgXDqrYd_TrpUWtn3zmxZ9XPm7O3GS6lV7aMJJOTsbOAAeQwSd_eoHcCXqVzTUtwTyB4855qtbd8DARnExyqHPAYJpZIJ2NIJpcIQihw1Xim11bHRpYWRkcnO4bAAzNi5ib290LTAxLmdjLXVzLWNlbnRyYWwxLWEuc2hhcmRzLnRlc3Quc3RhdHVzLmltBnZfADU2LmJvb3QtMDEuZ2MtdXMtY2VudHJhbDEtYS5zaGFyZHMudGVzdC5zdGF0dXMuaW0GAbveA4Jyc40AEAUAAQAgAEAAgAEAiXNlY3AyNTZrMaECxjqgDQ0WyRSOilYU32DA5k_XNlDis3m1VdXkK9xM6kODdGNwgnZfg3VkcIIjKIV3YWt1Mg0"\
  --discv5-bootstrap-node="enr:-QEcuEAX6Qk-vVAoJLxR4A_4UVogGhvQrqKW4DFKlf8MA1PmCjgowL-LBtSC9BLjXbb8gf42FdDHGtSjEvvWKD10erxqAYJpZIJ2NIJpcIQI2hdMim11bHRpYWRkcnO4bAAzNi5ib290LTAxLmFjLWNuLWhvbmdrb25nLWMuc2hhcmRzLnRlc3Quc3RhdHVzLmltBnZfADU2LmJvb3QtMDEuYWMtY24taG9uZ2tvbmctYy5zaGFyZHMudGVzdC5zdGF0dXMuaW0GAbveA4Jyc40AEAUAAQAgAEAAgAEAiXNlY3AyNTZrMaEDP7CbRk-YKJwOFFM4Z9ney0GPc7WPJaCwGkpNRyla7mCDdGNwgnZfg3VkcIIjKIV3YWt1Mg0"\
  ${RLN_RELAY_CRED_PATH}\
  ${RLN_RELAY_CRED_PASSWORD}\
  ${RLN_RELAY_TREE_PATH}\
  ${RLN_RELAY_ETH_CLIENT_ADDRESS}\
  ${DNS_WSS_CMD}\
  ${NODEKEY}\
  ${EXTRA_ARGS}

