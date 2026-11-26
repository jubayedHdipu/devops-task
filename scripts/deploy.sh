#!/usr/bin/env bash
set -euo pipefail

# Canary container deploy script with health check verification and rollback
# Usage: ./scripts/deploy.sh <image_uri> [container_name] [host_port] [container_port]

IMAGE_URI="${1:?Usage: $0 <image_uri> [container_name] [host_port] [container_port]}"
CONTAINER_NAME="${2:-devops-task-app}"
HOST_PORT="${3:-8080}"
CONTAINER_PORT="${4:-8080}"
CANARY_PORT="${CANARY_PORT:-8081}"
BACKUP_CONTAINER="${CONTAINER_NAME}-backup"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

wait_for_health() {
  local port="$1"
  local retries="${2:-15}"
  local attempt=1

  while [ "$attempt" -le "$retries" ]; do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    log "Waiting for health check on port ${port} (attempt ${attempt}/${retries})..."
    sleep 2
    attempt=$((attempt + 1))
  done

  return 1
}

log "Pulling target container image: ${IMAGE_URI}"
docker pull "${IMAGE_URI}"

# Clean up any leftover canary/backup containers
docker rm -f "${CONTAINER_NAME}-canary" >/dev/null 2>&1 || true
docker rm -f "${BACKUP_CONTAINER}" >/dev/null 2>&1 || true

log "Starting canary container on port ${CANARY_PORT} for pre-cutover verification..."
docker run -d \
  --name "${CONTAINER_NAME}-canary" \
  --restart unless-stopped \
  -p "127.0.0.1:${CANARY_PORT}:${CONTAINER_PORT}" \
  -e PORT="${CONTAINER_PORT}" \
  -e APP_ENV="production" \
  -e LOG_LEVEL="info" \
  "${IMAGE_URI}" >/dev/null

if ! wait_for_health "${CANARY_PORT}" 15; then
  log "ERROR: Canary container failed health check! Aborting deployment without touching live traffic."
  docker logs "${CONTAINER_NAME}-canary" || true
  docker rm -f "${CONTAINER_NAME}-canary" >/dev/null 2>&1 || true
  exit 1
fi

log "Canary verified healthy. Performing cutover to port ${HOST_PORT}..."
docker rm -f "${CONTAINER_NAME}-canary" >/dev/null 2>&1 || true

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker rename "${CONTAINER_NAME}" "${BACKUP_CONTAINER}"
fi

if docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  -e PORT="${CONTAINER_PORT}" \
  -e APP_ENV="production" \
  -e LOG_LEVEL="info" \
  "${IMAGE_URI}" >/dev/null && wait_for_health "${HOST_PORT}" 15; then

  log "Deployment successful! Removing previous container backup and pruning dangling images."
  docker rm -f "${BACKUP_CONTAINER}" >/dev/null 2>&1 || true
  docker image prune -f >/dev/null 2>&1 || true
  exit 0
else
  log "CRITICAL: Cutover failed health check! Rolling back to previous container..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  if docker ps -a --format '{{.Names}}' | grep -qx "${BACKUP_CONTAINER}"; then
    docker rename "${BACKUP_CONTAINER}" "${CONTAINER_NAME}"
    docker start "${CONTAINER_NAME}" >/dev/null
    log "Rollback complete. Previous version restored."
  fi
  exit 1
fi