#!/usr/bin/env bash
# Starts and stops the fake Microsoft Foundry used by the tests (scripts/fake-foundry/server.py).
#
#   ./scripts/fake-foundry.sh start    run it on the Karavan network as `fake-foundry` (port 8098, also on localhost)
#   ./scripts/fake-foundry.sh stop
#   ./scripts/fake-foundry.sh status
#
# A project reaches it at http://fake-foundry:8098/api/projects/fake (APP_FOUNDRY_ENDPOINT); the tests reach it at
# http://localhost:8098/api/projects/fake and drive its faults with POST /__fail and /__reset.

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
NAME="fake-foundry"

case "${1:-}" in
  start)
    require_docker; require_cluster_network
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    docker run -d --name "${NAME}" --network yape-local -p 127.0.0.1:8098:8098 \
      -v "${REPO_DIR}/scripts/fake-foundry/server.py:/app/server.py:ro" python:3.13-alpine python -u /app/server.py >/dev/null
    for _ in $(seq 1 20); do curl -s -o /dev/null -m 2 http://localhost:8098/__state && break; sleep 1; done
    echo "🚀  ${NAME} on http://localhost:8098 (in Docker: http://${NAME}:8098/api/projects/fake)" ;;
  stop)   docker rm -f "${NAME}" >/dev/null 2>&1 && echo "Stopped ${NAME}" || echo "${NAME} is not running" ;;
  status) curl -s -m 3 http://localhost:8098/__state || echo "${NAME} is not running" ;;
  *)      echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
