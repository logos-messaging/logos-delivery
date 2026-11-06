#!/usr/bin/env bash
# Read-only access to the logos.dev delivery fleet: one ssh per host that
#  - forwards the node metrics port (8008) to localhost:1800N
#  - streams the container log into $LOG_DIR/<host>.log
# ssh -f backgrounds only after auth, so each host prompts once and no
# credentials or control sockets are left behind.
set -euo pipefail

HOSTS=(
  delivery-01.do-ams3.logos.dev.status.im
  delivery-02.do-ams3.logos.dev.status.im
  delivery-01.gc-us-central1-a.logos.dev.status.im
  delivery-02.gc-us-central1-a.logos.dev.status.im
  delivery-01.ac-cn-hongkong-c.logos.dev.status.im
  delivery-02.ac-cn-hongkong-c.logos.dev.status.im
)
BASE_PORT=18001
REMOTE_METRICS_PORT=8008
LOG_DIR="${LOG_DIR:-$(cd "$(dirname "$0")" && pwd)/fleet-logs}"
SSH_USER_PREFIX="${SSH_USER:+${SSH_USER}@}"

REMOTE_TAIL='f=/var/log/docker/logos-node/docker.log;
if [ -r "$f" ]; then exec tail -n 5000 -F "$f";
else exec docker logs -f --tail 5000 logos-node 2>&1; fi'

up() {
  mkdir -p "$LOG_DIR"
  for i in "${!HOSTS[@]}"; do
    local host="${HOSTS[$i]}" port=$((BASE_PORT + i))
    echo ">> ${host}  metrics -> localhost:${port}  log -> ${LOG_DIR}/${host}.log"
    # shellcheck disable=SC2086
    ssh -f -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 ${SSH_OPTS:-} \
      -L "${port}:127.0.0.1:${REMOTE_METRICS_PORT}" \
      "${SSH_USER_PREFIX}${host}" "$REMOTE_TAIL" >>"${LOG_DIR}/${host}.log" ||
      echo "!! ${host}: ssh failed" >&2
  done
  status
}

down() {
  pkill -f "ssh .*-L 180[0-9][0-9]:127.0.0.1:${REMOTE_METRICS_PORT}" || true
}

status() {
  for i in "${!HOSTS[@]}"; do
    local host="${HOSTS[$i]}" port=$((BASE_PORT + i))
    local code
    code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/metrics" || true)
    local lines
    lines=$(cat "${LOG_DIR}/${host}.log" 2>/dev/null | wc -l)
    printf '%-52s :%s metrics=%s log_lines=%s\n' "$host" "$port" "$code" "${lines// /}"
  done
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "usage: $0 [up|down|status]" >&2; exit 1 ;;
esac
