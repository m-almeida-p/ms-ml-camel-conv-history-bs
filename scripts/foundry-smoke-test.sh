#!/usr/bin/env bash
# Smoke test of the Microsoft Foundry Conversations API against YOUR project. It answers, with real calls, what the
# documentation leaves open before anything is designed on top of it:
#   - how a conversation and its items are created, and what comes back (ids, timestamps, shapes);
#   - which text-message item shapes the API accepts, and whether an item takes metadata or a caller-set time;
#   - how items are listed and paged (envelope, cursors, order);
#   - whether conversations can be listed, and by what.
#
#   ./scripts/foundry-smoke-test.sh
#
# Needs: `az login` done (the token is requested from the Azure CLI at run time and is never printed or stored),
# FOUNDRY_PROJECT_ENDPOINT in .env (https://<resource>.services.ai.azure.com/api/projects/<project>), curl, jq.
# It creates ONE conversation with fake data, and deletes it when it finishes (also on failure).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENDPOINT="${FOUNDRY_PROJECT_ENDPOINT:-}"
if [ -z "${ENDPOINT}" ] && [ -f "${REPO_DIR}/.env" ]; then
  # Read only this variable: .env also holds the GitHub token, which this script has no use for.
  ENDPOINT="$(grep -E '^FOUNDRY_PROJECT_ENDPOINT=' "${REPO_DIR}/.env" | head -1 | cut -d= -f2-)"
fi
[ -n "${ENDPOINT}" ] || { echo "❌  Set FOUNDRY_PROJECT_ENDPOINT in .env (see .env.example)" >&2; exit 1; }
ENDPOINT="${ENDPOINT%/}"
command -v az >/dev/null && command -v jq >/dev/null || { echo "❌  az and jq are required" >&2; exit 1; }

TOKEN="$(az account get-access-token --resource https://ai.azure.com/ --query accessToken -o tsv 2>/dev/null)" \
  || { echo "❌  No token: run 'az login' first" >&2; exit 1; }

STATUS=""; BODY=""; CONV=""
api() { # METHOD PATH [JSON body]; sets STATUS and BODY. The token is only ever sent, never printed.
  local method="$1" path="$2" data="${3:-}" out
  out="$(mktemp)"
  if [ -n "${data}" ]; then
    STATUS="$(curl -sS -o "${out}" -w '%{http_code}' -X "${method}" "${ENDPOINT}${path}" \
      -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' --data "${data}" 2>&1)" || true
  else
    STATUS="$(curl -sS -o "${out}" -w '%{http_code}' -X "${method}" "${ENDPOINT}${path}" \
      -H "Authorization: Bearer ${TOKEN}" 2>&1)" || true
  fi
  BODY="$(cat "${out}")"; rm -f "${out}"
}
show() { echo "    HTTP ${STATUS}"; echo "${BODY}" | jq -c "${1:-.}" 2>/dev/null | cut -c1-600 || echo "${BODY}" | cut -c1-300; }

cleanup() {
  if [ -n "${CONV}" ]; then
    api DELETE "/openai/v1/conversations/${CONV}"
    echo "🧹  deleted the test conversation: HTTP ${STATUS}"
  fi
}
trap cleanup EXIT

echo "🔌  endpoint: ${ENDPOINT}"

echo; echo "1. create a conversation, with metadata"
api POST /openai/v1/conversations '{"metadata":{"conversation_id":"smoke-test-0001","source":"ms-ml-camel-conv-history-bs"}}'
show '{id, object, created_at, metadata}'
CONV="$(echo "${BODY}" | jq -r '.id // empty')"
[ -n "${CONV}" ] || { echo "❌  the conversation was not created; the rest cannot run"; exit 1; }

echo; echo "2. add a user message (content as a plain string, the documented shape)"
api POST "/openai/v1/conversations/${CONV}/items" '{"items":[{"type":"message","role":"user","content":"Hola, quiero yapear (smoke test)"}]}'
show '{keys: keys, count: (.data|length?), items: [.data[]? | {id, type, role, status, created_at, content: (.content|if type=="array" then map(.type) else . end)}]}'

echo; echo "3. add an assistant message (content as output_text parts)"
api POST "/openai/v1/conversations/${CONV}/items" '{"items":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Claro, te ayudo (smoke test)"}]}]}'
show '{count: (.data|length?), items: [.data[]? | {id, type, role, created_at, content: (.content|if type=="array" then map(.type) else . end)}]}'

echo; echo "4. does an item take its own metadata, or a caller-set created_at?"
api POST "/openai/v1/conversations/${CONV}/items" '{"items":[{"type":"message","role":"user","content":"with metadata (smoke test)","metadata":{"sequence":"3","occurred_at":"2026-01-01T00:00:00Z"}}]}'
echo "  4a. metadata on an item:"; show '{error: .error, items: [.data[]? | {id, metadata}]}'
api POST "/openai/v1/conversations/${CONV}/items" '{"items":[{"type":"message","role":"user","content":"with created_at (smoke test)","created_at":1767225600}]}'
echo "  4b. created_at on an item (2026-01-01):"; show '{error: .error, items: [.data[]? | {id, created_at}]}'

echo; echo "5. list the items, oldest first"
api GET "/openai/v1/conversations/${CONV}/items?order=asc&limit=100"
show '{keys: keys, object, has_more, first_id, last_id, count: (.data|length?), items: [.data[]? | {id, role, created_at}]}'
FIRST="$(echo "${BODY}" | jq -r '.data[0].id // empty')"

echo; echo "6. page through them: limit=1, then after=<first item>"
api GET "/openai/v1/conversations/${CONV}/items?order=asc&limit=1"
echo "  6a. limit=1:"; show '{has_more, first_id, last_id, ids: [.data[]?.id]}'
if [ -n "${FIRST}" ]; then
  api GET "/openai/v1/conversations/${CONV}/items?order=asc&limit=1&after=${FIRST}"
  echo "  6b. after the first item:"; show '{has_more, first_id, last_id, ids: [.data[]?.id]}'
fi

echo; echo "7. get the conversation back"
api GET "/openai/v1/conversations/${CONV}"
show '{id, created_at, metadata}'

echo; echo "8. list conversations: can it find ours, and by what?"
api GET "/openai/v1/conversations?limit=5&order=desc"
show '{keys: keys, count: (.data|length?), has_more, mine: ([.data[]? | select(.id=="'"${CONV}"'")] | length)}'

echo; echo "done"
