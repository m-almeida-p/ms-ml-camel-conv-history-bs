#!/usr/bin/env bash
# The whole chain with a REAL producer flow, and the time each hop takes.
#
#   ./scripts/test-e2e.sh [flow]          default flow: card
#
#   agent -> event_store.conversation_events -> Debezium -> topic -> conv-history-consumer -> camel_history
#                                                            -> conv-history-sync -> Microsoft Foundry
#                                                                                       -> conv-history-api (port 8086)
#
# It runs one demo flow of ml-genai-agents-bs-testing (the real chat in headless Chrome, no model in the loop), finds the new
# conversation in the event store, and waits for it to appear, in this order: stored in camel_history, in Foundry, served by
# the API. Then it checks the API's answer against the events themselves, which no Camel project touched: one chat message
# for each UserMessageSent, AgentMessageSent and GuardrailResponseSent, in order, with the text of the event.
#
# Needs: the VPN, the agent on :3000 (ms-ml-genai-agents-bs/scripts/run_api.sh), the AG-UI BFF and mock, the cluster, and the
# three Karavan projects running (consumer, sync, API). It never uses --clean and adds one conversation to the shared event store.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
FLOW="${1:-card}"
API="${API_BASE_URL:-http://localhost:8086}"
EXPLORER="${REPO_DIR}/../ml-genai-agents-bs-testing/cmd/p2p-explore/scripts/run.sh"
LOGS="${REPO_DIR}/../ml-genai-agents-bs-testing/cmd/p2p-explore/logs"

now() { python3 -I -c 'import time; print(f"{time.time():.1f}")'; }
since() { python3 -I -c "print(f'{$(now) - $1:.1f}')"; }

echo "== preconditions"
[ -x "${EXPLORER}" ] || { echo "❌  ${EXPLORER} not found" >&2; exit 1; }
gw="$(curl -s -o /dev/null -m 6 -w '%{http_code}' https://msmlaigatewaybs.qa.yape.tech || true)"
[ "${gw}" != 000 ] && [ -n "${gw}" ] && pass "the VPN: the LLM gateway answers (HTTP ${gw})" || { fail "the VPN is off: the gateway does not answer"; summary; exit 1; }
check "the agent answers on :3000" 200 "$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost:3000/health)"
check "the API answers (${API})" 200 "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${API}/health")"
for c in conv-history-consumer conv-history-sync conv-history-api; do
  check "${c} is healthy" healthy "$(docker inspect -f '{{.State.Health.Status}}' "${c}" 2>/dev/null)"
done
[ "${FAILS}" -eq 0 ] || { summary; exit 1; }

before="$(sql "SELECT conversation_id FROM event_store.conversation_events GROUP BY conversation_id" | sort)"
echo "== running the ${FLOW} flow (about 45 s)"
t0="$(now)"
"${EXPLORER}" --flow "${FLOW}" --headless 2>&1 | tail -2 | cut -c1-160
while [ -f "${LOGS}/p2p-explore.pid" ]; do sleep 2; done
t_flow="$(since "${t0}")"
status="$("${EXPLORER}" --status 2>&1 | grep -E "^ +${FLOW} " | head -1)"
check_contains "the flow completed" "completed" "${status}"

cid="$(comm -13 <(echo "${before}") <(sql "SELECT conversation_id FROM event_store.conversation_events GROUP BY conversation_id" | sort) | head -1)"
[ -n "${cid}" ] || { fail "the flow left no new conversation in the event store"; summary; exit 1; }
echo "   new conversation: ${cid}  (flow took ${t_flow} s)"
events="$(sql "SELECT count(*) FROM event_store.conversation_events WHERE conversation_id='${cid}'")"
chat="$(sql "SELECT count(*) FROM event_store.conversation_events WHERE conversation_id='${cid}' AND event_name IN ('UserMessageSent','AgentMessageSent','GuardrailResponseSent')")"
echo "   ${events} events, ${chat} of them chat messages"
t1="$(now)"

hop() { # label, timeout, shell condition
  local start="$(now)"
  for _ in $(seq 1 "$2"); do eval "$3" && { printf '   %-46s %5s s after the flow ended\n' "$1" "$(since "${t1}")"; return 0; }; sleep 1; done
  fail "$1: not reached in $2 s"; return 1
}
echo "== the hops, in order"
hop "stored in camel_history (consumer)" 120 "[ \"\$(sql \"SELECT count(*) FROM camel_history.conversation_messages WHERE conversation_id='${cid}'\")\" = ${chat} ]" || true
hop "in Foundry, mapped (sync)" 120 "[ \"\$(sql \"SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='${cid}'\")\" = ${chat} ]" || true
account="$(sql "SELECT id_yape_account FROM event_store.conversation_events WHERE conversation_id='${cid}' AND id_yape_account IS NOT NULL LIMIT 1")"
hop "listed by the API" 60 "curl -s -m 10 '${API}/v1/conversations?idYapeAccount=${account}' | jq -e '[.conversations[]._id] | index(\"${cid}\")' >/dev/null" || true

echo "== what the API serves, against the events themselves"
messages="$(curl -s -m 20 "${API}/v1/conversations/${cid}/messages")"
expected="$(sql "SELECT coalesce(json_agg(CASE event_name WHEN 'GuardrailResponseSent' THEN payload::json->>'response_text' ELSE payload::json->>'text' END ORDER BY sequence), '[]')
                 FROM event_store.conversation_events WHERE conversation_id='${cid}' AND event_name IN ('UserMessageSent','AgentMessageSent','GuardrailResponseSent')")"
check "as many messages as chat events" "${chat}" "$(echo "${messages}" | jq '.messages | length')"
check "the same texts, in the same order, as the events" "$(echo "${expected}" | jq -c .)" "$(echo "${messages}" | jq -c '[.messages[].text]')"
check "roles: the user, then the assistant" "$(sql "SELECT coalesce(json_agg(CASE event_name WHEN 'UserMessageSent' THEN 'appUser' ELSE 'appMaker' END ORDER BY sequence), '[]') FROM event_store.conversation_events WHERE conversation_id='${cid}' AND event_name IN ('UserMessageSent','AgentMessageSent','GuardrailResponseSent')" | jq -c .)" "$(echo "${messages}" | jq -c '[.messages[].role]')"
check "_id is the sequence of the event" "$(sql "SELECT coalesce(json_agg(sequence::text ORDER BY sequence), '[]') FROM event_store.conversation_events WHERE conversation_id='${cid}' AND event_name IN ('UserMessageSent','AgentMessageSent','GuardrailResponseSent')" | jq -c .)" "$(echo "${messages}" | jq -c '[.messages[]._id]')"
check "the Foundry conversation carries our id" "${cid}" "$(foundry GET "/openai/v1/conversations/$(sql "SELECT foundry_conversation_id FROM camel_history.foundry_conversation_map WHERE conversation_id='${cid}'")" >/dev/null; echo "${BODY}" | jq -r '.metadata.conversation_id')"
echo "== and the oracle for everything"
"${REPO_DIR}/scripts/oracle-api.sh" "${API}" | tail -2 | sed 's/^/   /'
check "the oracle agrees" 0 "${PIPESTATUS[0]}"
summary
