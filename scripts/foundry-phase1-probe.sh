#!/usr/bin/env bash
# Phase 1 probe of the Microsoft Foundry Conversations API: the questions scripts/foundry-smoke-test.sh left open.
#   - the order of items sent in one batch, and order=desc with the before/after cursors;
#   - the batch limit (20 / 21) and how long an item text may be;
#   - creating a conversation together with its first items;
#   - whether an Idempotency-Key header de-duplicates a repeated create;
#   - what listing conversations returns (is the metadata there?) and how a deleted conversation answers;
#   - the shape of the 401 and 404 errors, and which rate-limit headers come back.
#
#   ./scripts/foundry-phase1-probe.sh
#
# Same needs as the smoke test: `az login`, FOUNDRY_PROJECT_ENDPOINT in .env, curl, jq. Fake data only. Every
# conversation it creates is deleted when it finishes (also on failure). The token is never printed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENDPOINT="${FOUNDRY_PROJECT_ENDPOINT:-}"
if [ -z "${ENDPOINT}" ] && [ -f "${REPO_DIR}/.env" ]; then
  ENDPOINT="$(grep -E '^FOUNDRY_PROJECT_ENDPOINT=' "${REPO_DIR}/.env" | head -1 | cut -d= -f2-)"
fi
[ -n "${ENDPOINT}" ] || { echo "❌  Set FOUNDRY_PROJECT_ENDPOINT in .env (see .env.example)" >&2; exit 1; }
ENDPOINT="${ENDPOINT%/}"
command -v az >/dev/null && command -v jq >/dev/null || { echo "❌  az and jq are required" >&2; exit 1; }
TOKEN="$(az account get-access-token --resource https://ai.azure.com/ --query accessToken -o tsv 2>/dev/null)" \
  || { echo "❌  No token: run 'az login' first" >&2; exit 1; }

STATUS=""; BODY=""; HEADERS=""; CREATED=()
api() { # METHOD PATH [JSON body] [extra curl args...]; sets STATUS, BODY, HEADERS. The token is only sent.
  local method="$1" path="$2" data="${3:-}" out hdr; shift 2; [ $# -gt 0 ] && shift
  out="$(mktemp)"; hdr="$(mktemp)"
  if [ -n "${data}" ]; then
    STATUS="$(curl -sS -o "${out}" -D "${hdr}" -w '%{http_code}' -X "${method}" "${ENDPOINT}${path}" \
      -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' --data "${data}" "$@" 2>&1)" || true
  else
    STATUS="$(curl -sS -o "${out}" -D "${hdr}" -w '%{http_code}' -X "${method}" "${ENDPOINT}${path}" \
      -H "Authorization: Bearer ${TOKEN}" "$@" 2>&1)" || true
  fi
  BODY="$(cat "${out}")"; HEADERS="$(cat "${hdr}")"; rm -f "${out}" "${hdr}"
}
show() { echo "    HTTP ${STATUS}"; echo "${BODY}" | jq -c "${1:-.}" 2>/dev/null | cut -c1-700 || echo "${BODY}" | cut -c1-300; }
new_conv() { # JSON body; sets CONV and remembers it for cleanup
  api POST /openai/v1/conversations "${1:-{\}}"; CONV="$(echo "${BODY}" | jq -r '.id // empty')"
  [ -n "${CONV}" ] && CREATED+=("${CONV}")
}
msg() { printf '{"type":"message","role":"%s","content":"%s"}' "$1" "$2"; }

cleanup() {
  local c n=0
  for c in ${CREATED[@]+"${CREATED[@]}"}; do api DELETE "/openai/v1/conversations/${c}"; [ "${STATUS}" = 200 ] && n=$((n+1)); done
  echo "🧹  deleted ${n} of ${#CREATED[@]} test conversations"
}
trap cleanup EXIT
echo "🔌  endpoint: ${ENDPOINT}"

echo; echo "A. create a conversation WITH its first two items and metadata, in one call"
new_conv '{"metadata":{"conversation_id":"probe-a","source":"ms-ml-camel-conv-history-bs"},"items":[{"type":"message","role":"user","content":"A1 hola"},{"type":"message","role":"assistant","content":"A2 claro"}]}'
show '{id, metadata}'
api GET "/openai/v1/conversations/${CONV}/items?order=asc"; echo "  items now:"; show '{n:(.data|length?), roles:[.data[]?.role]}'

echo; echo "B. one batch of 6 items in a known order, then list asc and desc"
new_conv '{"metadata":{"conversation_id":"probe-b"}}'; B="${CONV}"
items="$(for i in 1 2 3 4 5 6; do [ $((i%2)) = 1 ] && r=user || r=assistant; msg "$r" "B$i"; echo; done | jq -s -c '.')"
api POST "/openai/v1/conversations/${B}/items" "{\"items\":${items}}"; echo "  create response order:"; show '[.data[]? | (.content|if type=="array" then .[0].text else . end)]'
api GET "/openai/v1/conversations/${B}/items?order=asc&limit=100"; echo "  list asc:"; show '[.data[]? | (.content|if type=="array" then .[0].text else . end)]'
ASC_IDS="$(echo "${BODY}" | jq -r '.data[].id')"
api GET "/openai/v1/conversations/${B}/items?order=desc&limit=100"; echo "  list desc:"; show '[.data[]? | (.content|if type=="array" then .[0].text else . end)]'

echo; echo "C. order=desc paging: limit=2, then after=<last id>, then before=<first id of page 2>"
api GET "/openai/v1/conversations/${B}/items?order=desc&limit=2"; echo "  C1 desc limit=2:"; show '{has_more, first_id, last_id, t:[.data[]? | (.content|if type=="array" then .[0].text else . end)]}'
LAST="$(echo "${BODY}" | jq -r '.last_id // empty')"
api GET "/openai/v1/conversations/${B}/items?order=desc&limit=2&after=${LAST}"; echo "  C2 desc, after=<last id of page 1>:"; show '{has_more, first_id, last_id, t:[.data[]? | (.content|if type=="array" then .[0].text else . end)]}'
FIRST2="$(echo "${BODY}" | jq -r '.first_id // empty')"
api GET "/openai/v1/conversations/${B}/items?order=desc&limit=2&before=${FIRST2}"; echo "  C3 desc, before=<first id of page 2> (back to page 1?):"; show '{has_more, first_id, last_id, t:[.data[]? | (.content|if type=="array" then .[0].text else . end)]}'
MID="$(echo "${ASC_IDS}" | sed -n 3p)"
api GET "/openai/v1/conversations/${B}/items?order=asc&limit=100&before=${MID}"; echo "  C4 asc, before=<3rd id> (items older than it?):"; show '{t:[.data[]? | (.content|if type=="array" then .[0].text else . end)]}'
api GET "/openai/v1/conversations/${B}/items/${MID}"; echo "  C5 get one item by id:"; show '{id, role, t:(.content|if type=="array" then .[0].text else . end)}'

echo; echo "D. batch limit: 20 items, then 21"
new_conv '{}'; D="${CONV}"
api POST "/openai/v1/conversations/${D}/items" "{\"items\":$(for i in $(seq 1 20); do msg user "D$i"; echo; done | jq -s -c '.')}"; echo "  20 items:"; show '{n:(.data|length?), error:.error}'
api POST "/openai/v1/conversations/${D}/items" "{\"items\":$(for i in $(seq 1 21); do msg user "E$i"; echo; done | jq -s -c '.')}"; echo "  21 items:"; show '{n:(.data|length?), error:.error}'

echo; echo "E. long text: 20,000 and 100,000 characters"
new_conv '{}'; E="${CONV}"
for n in 20000 100000; do
  big="$(head -c "${n}" /dev/zero | tr '\0' 'x')"
  api POST "/openai/v1/conversations/${E}/items" "{\"items\":[{\"type\":\"message\",\"role\":\"user\",\"content\":\"${big}\"}]}"
  echo "  ${n} chars:"; show '{n:(.data|length?), stored:(.data[0]?.content|if type=="string" then length else (.[0].text|length) end), error:.error}'
done

echo; echo "F. does an Idempotency-Key header de-duplicate a repeated create-items?"
new_conv '{}'; F="${CONV}"; key="probe-$(date +%s)"
for i in 1 2; do api POST "/openai/v1/conversations/${F}/items" "{\"items\":[$(msg user "F once")]}" -H "Idempotency-Key: ${key}"; echo "  send #${i}: HTTP ${STATUS}"; done
api GET "/openai/v1/conversations/${F}/items?order=asc"; echo "  items stored after two identical sends with one key:"; show '{n:(.data|length?)}'

echo; echo "G. list conversations: does a row carry its metadata? can ours be found by it?"
api GET "/openai/v1/conversations?limit=100&order=desc"; echo "  first row:"; show '{keys:keys, has_more, n:(.data|length?), row:(.data[0]|{id, metadata, created_at})}'
echo "  ours found by metadata.conversation_id=probe-a (client-side filter): $(echo "${BODY}" | jq '[.data[]? | select(.metadata.conversation_id=="probe-a")] | length')"

echo; echo "H. errors: deleted conversation, unknown id, bad token"
api DELETE "/openai/v1/conversations/${F}"; echo "  delete: HTTP ${STATUS}"
api GET "/openai/v1/conversations/${F}"; echo "  get after delete:"; show '{error:.error}'
api GET "/openai/v1/conversations/${F}/items"; echo "  list items after delete:"; show '{error:.error}'
api DELETE "/openai/v1/conversations/${F}"; echo "  delete again: HTTP ${STATUS}"
api GET "/openai/v1/conversations/conv_doesnotexist0000"; echo "  unknown id:"; show '{error:.error}'
out="$(curl -sS -o /dev/null -w '%{http_code}' "${ENDPOINT}/openai/v1/conversations?limit=1" -H 'Authorization: Bearer not-a-token')"; echo "  bad token: HTTP ${out}"

echo; echo "I. response headers worth reading (names only): rate limit, retry, request id"
api GET "/openai/v1/conversations?limit=1"; echo "${HEADERS}" | tr -d '\r' | grep -iE '^(x-ratelimit|retry-after|x-request-id|apim-request-id|x-ms-|azureml|request-id|content-type)' | cut -d: -f1 | sort -u | tr '\n' ' '; echo
echo; echo "done"
