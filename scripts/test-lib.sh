#!/usr/bin/env bash
# Helpers shared by the test-*.sh scripts of the Foundry work. Sourced, not executed.
#   pass/fail/check/check_contains/summary   a tiny assertion kit; summary exits non-zero if anything failed
#   sql "<statement>"                        run SQL in the cluster Postgres, one value per line
#   env_value NAME                           read one variable from .env (never the whole file)
#   foundry METHOD PATH [json]               call Foundry as the service principal; sets STATUS and BODY
#   track_foundry_conversation ID            delete that conversation when the script exits (also on failure)

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

FAILS=0
STATUS=""; BODY=""
FOUNDRY_TRACKED=()
FOUNDRY_TOKEN_CACHE=""
DEVMODE_IMAGE="${DEVMODE_IMAGE:-ghcr.io/apache/camel-karavan-devmode:4.22.2}"

pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$2] got [$3]"; fi
}
check_contains() { # description, needle, haystack
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1: [$2] not found in [${3:0:200}]"; fi
}
summary() {
  echo
  if [ "${FAILS}" -eq 0 ]; then echo "✅  all checks passed"; else echo "❌  ${FAILS} check(s) failed"; fi
  [ "${FAILS}" -eq 0 ]
}

sql() { docker exec yape-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA -c "$1"; }   # no -i: it would swallow the caller's stdin

env_value() { grep -E "^$1=" "${REPO_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2-; }

FOUNDRY_ENDPOINT="$(env_value FOUNDRY_PROJECT_ENDPOINT)"
FOUNDRY_ENDPOINT="${FOUNDRY_ENDPOINT%/}"

foundry_token() { # the token is kept in a variable and only ever sent, never printed
  if [ -z "${FOUNDRY_TOKEN_CACHE}" ]; then
    FOUNDRY_TOKEN_CACHE="$(curl -s -m 20 -X POST "https://login.microsoftonline.com/$(env_value FOUNDRY_TENANT_ID)/oauth2/v2.0/token" \
      --data-urlencode "client_id=$(env_value FOUNDRY_CLIENT_ID)" --data-urlencode "client_secret=$(env_value FOUNDRY_CLIENT_SECRET)" \
      --data-urlencode "scope=https://ai.azure.com/.default" --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')"
  fi
  [ -n "${FOUNDRY_TOKEN_CACHE}" ] || { echo "❌  could not get a Foundry token: check the FOUNDRY_* variables in .env" >&2; exit 1; }
}

foundry() { # METHOD PATH [JSON body]
  local method="$1" path="$2" data="${3:-}" out
  foundry_token
  out="$(mktemp)"
  if [ -n "${data}" ]; then
    STATUS="$(curl -s -m 30 -o "${out}" -w '%{http_code}' -X "${method}" "${FOUNDRY_ENDPOINT}${path}" \
      -H "Authorization: Bearer ${FOUNDRY_TOKEN_CACHE}" -H 'Content-Type: application/json' --data "${data}")" || STATUS="000"
  else
    STATUS="$(curl -s -m 30 -o "${out}" -w '%{http_code}' -X "${method}" "${FOUNDRY_ENDPOINT}${path}" \
      -H "Authorization: Bearer ${FOUNDRY_TOKEN_CACHE}")" || STATUS="000"
  fi
  BODY="$(cat "${out}")"; rm -f "${out}"
}

FOUNDRY_MODE="${FOUNDRY_MODE:-fake}"   # fake: the fake Foundry (scripts/fake-foundry.sh) | real: the project of .env
FAKE_URL="http://localhost:8098/api/projects/fake"

fx() { # GET path of the Foundry API under test (the fake or the real one); sets STATUS and BODY
  if [ "${FOUNDRY_MODE}" = fake ]; then
    local out; out="$(mktemp)"
    STATUS="$(curl -s -m 20 -o "${out}" -w '%{http_code}' "${FAKE_URL}$1" -H 'Authorization: Bearer test')"; BODY="$(cat "${out}")"; rm -f "${out}"
  else
    foundry GET "$1"
  fi
}
fxw() { # METHOD PATH [json]: a write to the Foundry API under test (the fake or the real one); sets STATUS and BODY
  if [ "${FOUNDRY_MODE}" = fake ]; then
    local out; out="$(mktemp)"
    STATUS="$(curl -s -m 20 -o "${out}" -w '%{http_code}' -X "$1" "${FAKE_URL}$2" -H 'Authorization: Bearer test' -H 'Content-Type: application/json' ${3:+--data "$3"})"; BODY="$(cat "${out}")"; rm -f "${out}"
  else
    foundry "$1" "$2" "${3:-}"
  fi
}

fake_fail() { curl -s -o /dev/null -X POST http://localhost:8098/__fail -H 'Content-Type: application/json' --data "$1"; }

track_foundry_conversation() { FOUNDRY_TRACKED+=("$1"); }

foundry_cleanup() {
  local id n=0
  for id in ${FOUNDRY_TRACKED[@]+"${FOUNDRY_TRACKED[@]}"}; do
    foundry DELETE "/openai/v1/conversations/${id}"
    { [ "${STATUS}" = 200 ] || [ "${STATUS}" = 404 ]; } && n=$((n + 1))
  done
  [ "${#FOUNDRY_TRACKED[@]}" -gt 0 ] && echo "🧹  Foundry: ${n} of ${#FOUNDRY_TRACKED[@]} test conversations removed"
  return 0
}
