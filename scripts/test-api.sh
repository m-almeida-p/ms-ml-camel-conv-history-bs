#!/usr/bin/env bash
# Test of the conv-history-api project against the local cluster.
#
#   ./scripts/test-api.sh               run every section
#   ./scripts/test-api.sh skeleton      run only the named sections (see the list at the end of the file)
#
# Starts the project with scripts/devmode-local.sh (the image Karavan's Run uses) and calls it from inside its own
# container, so nothing depends on a published port. Foundry is the fake (scripts/fake-foundry.sh) unless a section
# says it needs the real one. Every section deletes what it creates.
# Needs: the cluster up, the broker (docker compose up -d foundry-token), curl, jq.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"

PROJECT="conv-history-api"
CONTAINER="devmode-local-${PROJECT}"
FAKE_ENDPOINT="http://fake-foundry:8098/api/projects/fake"
HEADERS=""

cleanup() {
  foundry_cleanup
  "${REPO_DIR}/scripts/devmode-local.sh" stop "${PROJECT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_docker
require_cluster_network
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }

call() { # METHOD PATH -> STATUS BODY HEADERS, from inside the project container
  STATUS="$(docker exec "${CONTAINER}" sh -c 'curl -s -g -m 30 -X "$0" -o /tmp/b -D /tmp/h -w "%{http_code}" "$1"' "$1" "http://localhost:8080$2")" || STATUS="000"
  BODY="$(docker exec "${CONTAINER}" cat /tmp/b 2>/dev/null)"
  HEADERS="$(docker exec "${CONTAINER}" cat /tmp/h 2>/dev/null | tr -d '\r')"
}
header() { echo "${HEADERS}" | grep -i "^$1:" | head -1 | cut -d: -f2- | sed 's/^ *//'; }
log_text() { docker logs "${CONTAINER}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

start_project() { # extra NAME=value pairs for the container
  "${REPO_DIR}/scripts/fake-foundry.sh" start >/dev/null
  curl -s -o /dev/null -X POST http://localhost:8098/__reset
  compose up -d foundry-token >/dev/null
  "${REPO_DIR}/scripts/devmode-local.sh" "${PROJECT}" "APP_FOUNDRY_ENDPOINT=${FAKE_ENDPOINT}" "$@" >/dev/null
  for _ in $(seq 1 90); do
    log_text | grep -qE 'Apache Camel .* started in|Error starting Camel' && break
    sleep 2
  done
  log_text | grep -q 'Apache Camel .* started in' || { echo "❌  ${PROJECT} did not start:" >&2; log_text | grep -E 'ERROR|Error' | tail -5 >&2; exit 1; }
}

section_skeleton() {
  echo "== skeleton: health, 404 and 405"
  check_contains "Camel started" "started in" "$(log_text | grep 'Apache Camel .* started in')"
  check "no compact-notation warning in the log" 0 "$(log_text | grep -c 'compact notation' || true)"
  call GET /health
  check "GET /health is 200" 200 "${STATUS}"
  check "GET /health is JSON" "application/json" "$(header content-type | cut -d';' -f1)"
  check "GET /health says ok" ok "$(echo "${BODY}" | jq -r .status)"
  call GET /nothing/here
  check "an unknown path is 404" 404 "${STATUS}"
  check "the 404 is problem+json" "application/problem+json" "$(header content-type | cut -d';' -f1)"
  check "the 404 body repeats its status" 404 "$(echo "${BODY}" | jq -r .status)"
  check "the 404 uses about:blank" "about:blank" "$(echo "${BODY}" | jq -r .type)"
  check "the 404 title is the status phrase" "Not Found" "$(echo "${BODY}" | jq -r .title)"
  call POST /health
  check "a wrong method is 405" 405 "${STATUS}"
  check "the 405 is problem+json" "application/problem+json" "$(header content-type | cut -d';' -f1)"
  check "the 405 title is the status phrase" "Method Not Allowed" "$(echo "${BODY}" | jq -r .title)"
  check "the management health the DevMode check uses is UP" UP "$(docker exec "${CONTAINER}" curl -s -m 10 http://localhost:9876/q/observe/health | jq -r .status)"
}

ALL_SECTIONS="skeleton"
WANTED="${*:-${ALL_SECTIONS}}"
start_project
for s in ${WANTED}; do "section_${s}"; done
summary
