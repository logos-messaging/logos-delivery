#!/bin/sh

# check if POSTGRES_SHM is already specified
if [ -f "./.env" ]; then
    . ./.env
fi

if [ -n "$POSTGRES_SHM" ]; then
    >&2 echo "POSTGRES_SHM is specified in .env file, doing nothing"
    exit 0
fi

# Set PostgreSQL container Shared Memory value
TOTAL_MEM_MB=$(free -m|grep Mem| awk '{ print $2 }')
if [ "${TOTAL_MEM_MB}" -ge 4096 ]; then
    # Allocate 2GB of Shared Memory for Postgres if machine has more than 4GB RAM
    POSTGRES_SHM='2g'
else
    # Allocate 1GB of Shared Memory for Postgres
    POSTGRES_SHM='1g'
fi

>&2 echo "Setting PostgreSQL container SHM to ${POSTGRES_SHM}"
if [ "$1" = "echo-value" ]; then
  echo ${POSTGRES_SHM}
else
  echo "POSTGRES_SHM=${POSTGRES_SHM}" >> .env
fi
