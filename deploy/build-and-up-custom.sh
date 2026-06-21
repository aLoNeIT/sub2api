#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Sub2API custom Docker build/start helper for Linux.
#
# This script builds the application with Docker build containers, then starts
# deploy/docker-compose-custom.yml, which mounts backend/bin/server into the
# runtime container instead of packaging application code into an image.
#
# Usage:
#   ./build-and-up-custom.sh             # build frontend/backend and start
#   ./build-and-up-custom.sh build       # build only
#   ./build-and-up-custom.sh up          # start only
#   ./build-and-up-custom.sh restart     # build and restart sub2api only
#   ./build-and-up-custom.sh down       # stop services
#   ./build-and-up-custom.sh logs       # follow sub2api logs
#
# Optional env:
#   NODE_IMAGE=node:24-alpine
#   PNPM_VERSION=9
#   GOLANG_IMAGE=golang:1.26.4-alpine
#   GOOS=linux
#   GOARCH=amd64
#   GOPROXY=https://goproxy.cn,direct
#   GOSUMDB=sum.golang.google.cn
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose-custom.yml"
ACTION="${1:-all}"

NODE_IMAGE="${NODE_IMAGE:-node:24-alpine}"
PNPM_VERSION="${PNPM_VERSION:-9}"
GOLANG_IMAGE="${GOLANG_IMAGE:-golang:1.26.4-alpine}"
GOOS="${GOOS:-linux}"
GOARCH="${GOARCH:-amd64}"
GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Required command not found: $1" >&2
    exit 1
  }
}

build_frontend() {
  echo "[INFO] Building frontend with ${NODE_IMAGE}..."
  docker run --rm \
    -e HOST_UID="${HOST_UID}" \
    -e HOST_GID="${HOST_GID}" \
    -e PNPM_VERSION="${PNPM_VERSION}" \
    -v "${REPO_ROOT}:/workspace" \
    -w /workspace/frontend \
    "${NODE_IMAGE}" \
    sh -lc 'corepack enable && corepack prepare "pnpm@${PNPM_VERSION}" --activate && pnpm install --frozen-lockfile && pnpm run build && chown -R "$HOST_UID:$HOST_GID" /workspace/frontend/node_modules /workspace/backend/internal/web/dist'
}

build_backend() {
  echo "[INFO] Building backend Linux binary with ${GOLANG_IMAGE}..."
  docker run --rm \
    -e GOOS="${GOOS}" \
    -e GOARCH="${GOARCH}" \
    -e CGO_ENABLED=0 \
    -e GOPROXY="${GOPROXY}" \
    -e GOSUMDB="${GOSUMDB}" \
    -e HOST_UID="${HOST_UID}" \
    -e HOST_GID="${HOST_GID}" \
    -v "${REPO_ROOT}:/workspace" \
    -w /workspace/backend \
    "${GOLANG_IMAGE}" \
    sh -lc "go build -tags embed -trimpath -ldflags='-s -w' -o bin/server ./cmd/server && chmod +x bin/server && chown -R \"\$HOST_UID:\$HOST_GID\" bin"
}

build_all() {
  echo "[INFO] Ensuring output/data directories exist..."
  mkdir -p "${REPO_ROOT}/backend/bin" \
           "${SCRIPT_DIR}/data" \
           "${SCRIPT_DIR}/postgres_data" \
           "${SCRIPT_DIR}/redis_data"
  build_frontend
  build_backend
  echo "[SUCCESS] Build finished: backend/bin/server"
}

compose_up() {
  echo "[INFO] Starting custom compose deployment..."
  docker compose -f "${COMPOSE_FILE}" up -d
  echo "[SUCCESS] Started. View logs with: $0 logs"
}

compose_restart_app() {
  echo "[INFO] Restarting sub2api service with the new mounted binary..."
  docker compose -f "${COMPOSE_FILE}" up -d postgres redis
  docker compose -f "${COMPOSE_FILE}" up -d --force-recreate sub2api
  echo "[SUCCESS] Restarted sub2api. View logs with: $0 logs"
}

require docker

case "${ACTION}" in
  all)
    build_all
    compose_up
    ;;
  build)
    build_all
    ;;
  up)
    compose_up
    ;;
  restart)
    build_all
    compose_restart_app
    ;;
  down)
    docker compose -f "${COMPOSE_FILE}" down
    ;;
  logs)
    docker compose -f "${COMPOSE_FILE}" logs -f sub2api
    ;;
  *)
    echo "Usage: $0 [all|build|up|restart|down|logs]" >&2
    exit 1
    ;;
esac
