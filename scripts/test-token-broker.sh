#!/usr/bin/env bash
# Test of the Foundry token broker (docker-compose.yml, service foundry-token).
#
#   ./scripts/test-token-broker.sh
#
# Starts the broker, calls it from a container on the same network the Karavan projects use (the DevMode image),
# and checks: health, a token that Foundry accepts, the cache, that the token and the secret appear in no log and in
# no tracked file, and the clear 503 of a broker started without credentials.
# Needs: the cluster up, FOUNDRY_* variables in .env, curl, jq.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"

UNCONFIGURED="foundry-token-unconfigured"
cleanup() { docker rm -f "${UNCONFIGURED}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

require_docker
require_cluster_network
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }
[ -n "$(env_value FOUNDRY_CLIENT_SECRET)" ] || { echo "❌  FOUNDRY_CLIENT_SECRET is not set in .env" >&2; exit 1; }

echo "== start the broker"
compose up -d foundry-token >/dev/null
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' foundry-token 2>/dev/null)" = healthy ] && break
  sleep 2
done
check "the broker is healthy" healthy "$(docker inspect -f '{{.State.Health.Status}}' foundry-token)"

# Same image and network as a Karavan-run project; only curl is used.
from_project() { docker run --rm --network yape-local --entrypoint curl "${DEVMODE_IMAGE}" -s -m 20 "$@"; }

echo "== health and the token"
check "health says configured" true "$(from_project http://foundry-token:8099/health | jq -r .configured)"
R1="$(from_project http://foundry-token:8099/token)"
T1="$(echo "${R1}" | jq -r .accessToken)"
check "a token is returned" true "$([ "${#T1}" -gt 1000 ] && echo true || echo false)"
EXP="$(echo "${R1}" | jq -r .expiresIn)"
check "it lives about an hour" true "$([ "${EXP}" -gt 3000 ] && [ "${EXP}" -le 3600 ] && echo true || echo false)"
check_contains "it carries an expiry time" "T" "$(echo "${R1}" | jq -r .expiresOn)"
check "it carries the project endpoint of .env" "${FOUNDRY_ENDPOINT}" "$(echo "${R1}" | jq -r .endpoint)"
T2="$(from_project http://foundry-token:8099/token | jq -r .accessToken)"
check "the second call is served from the cache (same token)" "$(printf %s "${T1}" | shasum | cut -c1-40)" "$(printf %s "${T2}" | shasum | cut -c1-40)"
check "an unknown path is 404" 404 "$(from_project -o /dev/null -w '%{http_code}' http://foundry-token:8099/nothing)"

echo "== Foundry accepts that token"
CODE="$(curl -s -o /dev/null -m 20 -w '%{http_code}' "${FOUNDRY_ENDPOINT}/openai/v1/conversations?limit=1" -H "Authorization: Bearer ${T1}")"
check "Foundry answers 200 to the broker's token" 200 "${CODE}"

echo "== the token and the secret stay out of logs and files"
LOGS="$(docker logs foundry-token 2>&1)"
check "the broker log has no token" 0 "$(printf %s "${LOGS}" | grep -cF -- "${T1}" || true)"
check "the broker log has no secret" 0 "$(printf %s "${LOGS}" | grep -cF -- "$(env_value FOUNDRY_CLIENT_SECRET)" || true)"
check_contains "the log shows the requests (method and path)" "GET /token -> 200" "${LOGS}"
check "no tracked file holds the secret" 0 "$(git -C "${REPO_DIR}" grep -cF -- "$(env_value FOUNDRY_CLIENT_SECRET)" 2>/dev/null | wc -l | tr -d ' ')"

echo "== a broker without credentials says so"
docker run -d --rm --name "${UNCONFIGURED}" --network yape-local -v "${REPO_DIR}/scripts/foundry-token-broker/server.py:/app/server.py:ro" \
  python:3.13-alpine python -u /app/server.py >/dev/null
sleep 2
check "503 without credentials" 503 "$(from_project -o /dev/null -w '%{http_code}' http://${UNCONFIGURED}:8099/token)"
check_contains "and it names the missing variables" FOUNDRY_CLIENT_SECRET "$(from_project http://${UNCONFIGURED}:8099/token)"
check "health still answers and says not configured" false "$(from_project http://${UNCONFIGURED}:8099/health | jq -r .configured)"

summary
