#!/bin/sh

echo "I am a service node"
IP=$(ip a | grep "inet " | grep -Fv 127.0.0.1 | sed 's/.*inet \([^/]*\).*/\1/')

echo "Service node IP: ${IP}"

if [ -n "${SHARD}" ]; then
    SHARD=--shard="${SHARD}"
else
    SHARD=--shard="0"
fi

if [ -n "${CLUSTER_ID}" ]; then
    CLUSTER_ID=--cluster-id="${CLUSTER_ID}"
fi

echo "STANDALONE: ${STANDALONE}"

if [ -z "${STANDALONE}" ]; then

  RETRIES=${RETRIES:=20}

  while [ -z "${BOOTSTRAP_ENR}" ] && [ ${RETRIES} -ge 0 ]; do
    BOOTSTRAP_ENR=$(wget -qO- http://bootstrap:8645/debug/v1/info --header='Content-Type:application/json' 2> /dev/null | sed 's/.*"enrUri":"\([^"]*\)".*/\1/');
    echo "Bootstrap node not ready, retrying (retries left: ${RETRIES})"
    sleep 3
    RETRIES=$(( $RETRIES - 1 ))
  done

  if [ -z "${BOOTSTRAP_ENR}" ]; then
    echo "Could not get BOOTSTRAP_ENR and none provided. Failing"
    exit 1
  fi

  echo "Using bootstrap node: ${BOOTSTRAP_ENR}"

fi


exec /usr/bin/logosdeliverynode\
      --relay=true\
      --filter=true\
      --lightpush=true\
      --store=false\
      --rest=true\
      --rest-admin=true\
      --rest-private=true\
      --rest-address=0.0.0.0\
      --rest-allow-origin="*"\
      --keep-alive=true\
      --max-connections=300\
      --dns-discovery=true\
      --discv5-discovery=true\
      --discv5-enr-auto-update=True\
      --discv5-bootstrap-node=${BOOTSTRAP_ENR}\
      --log-level=INFO\
      --metrics-server=True\
      --metrics-server-port=8003\
      --metrics-server-address=0.0.0.0\
      --nat=extip:${IP}\
      ${SHARD}\
      ${CLUSTER_ID}
