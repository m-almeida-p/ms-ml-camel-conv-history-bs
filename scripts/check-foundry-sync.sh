#!/usr/bin/env bash
# Compares what is in Microsoft Foundry with what camel_history says should be there. Read-only.
#
#   ./scripts/check-foundry-sync.sh
#
# For every conversation in camel_history.foundry_conversation_map it reads the Foundry conversation and checks:
#   - its metadata carries our conversation id,
#   - it holds exactly the chat messages of conversation_messages that are in foundry_item_map, in sequence order,
#   - each item has the same role (user/assistant) and the same text as the stored message,
#   - each item id is the one the map records.
# It also counts the conversations of the Foundry project that the map does not know (orphans): those of our source and of the
# instance FOUNDRY_INSTANCE (default "default", the sync's app.foundry.instance), over every page of the listing. Prints OK or MISMATCH.
# Limit: it reads at most 100 items of a conversation (one page).
# Needs the FOUNDRY_* variables in .env, curl, jq.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }
[ -n "${FOUNDRY_ENDPOINT}" ] || { echo "❌  FOUNDRY_PROJECT_ENDPOINT is not set in .env" >&2; exit 1; }

bad=0; convs=0; items=0
printf '%-48s %-6s %-6s %s\n' "conversation" "map" "foundry" "result"
for cid in $(sql "SELECT conversation_id FROM camel_history.foundry_conversation_map ORDER BY created_at, conversation_id"); do
  convs=$((convs + 1))
  fid="$(sql "SELECT foundry_conversation_id FROM camel_history.foundry_conversation_map WHERE conversation_id='${cid}'")"
  foundry GET "/openai/v1/conversations/${fid}"
  if [ "${STATUS}" != 200 ]; then printf '%-48s %-6s %-6s %s\n' "${cid}" "-" "-" "MISSING in Foundry (HTTP ${STATUS})"; bad=$((bad + 1)); continue; fi
  meta="$(echo "${BODY}" | jq -r '.metadata.conversation_id // ""')"
  foundry GET "/openai/v1/conversations/${fid}/items?order=asc&limit=100"
  actual="$(echo "${BODY}" | jq -c '[.data[] | {id, role, text: (.content | if type=="array" then .[0].text else . end)}]')"
  expected="$(sql "SELECT coalesce(json_agg(json_build_object('id', i.foundry_item_id, 'role', CASE m.role WHEN 'appUser' THEN 'user' ELSE 'assistant' END, 'text', m.text) ORDER BY i.sequence), '[]')
                   FROM camel_history.foundry_item_map i JOIN camel_history.conversation_messages m USING (conversation_id, sequence)
                   WHERE i.conversation_id='${cid}'" | jq -c .)"
  n="$(echo "${actual}" | jq 'length')"; items=$((items + n))
  result=OK
  [ "${meta}" = "${cid}" ] || result="metadata says [${meta}]"
  [ "${actual}" = "${expected}" ] || result="items differ from the stored messages"
  [ "$(sql "SELECT count(*) FROM camel_history.conversation_messages WHERE conversation_id='${cid}'")" = "${n}" ] || result="${result}; Foundry has ${n} items, the table has $(sql "SELECT count(*) FROM camel_history.conversation_messages WHERE conversation_id='${cid}'") messages"
  [ "${result}" = OK ] || bad=$((bad + 1))
  printf '%-48s %-6s %-6s %s\n' "${cid:0:48}" "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='${cid}'")" "${n}" "${result}"
done

known="$(sql "SELECT foundry_conversation_id FROM camel_history.foundry_conversation_map" | sort)"
INSTANCE="${FOUNDRY_INSTANCE:-default}"
ours=""; after=""
while :; do
  foundry GET "/openai/v1/conversations?limit=100&order=desc${after:+&after=${after}}"
  [ "${STATUS}" = 200 ] || { echo "❌  Foundry answered ${STATUS} when listing the conversations" >&2; exit 1; }
  ours+="$(echo "${BODY}" | jq -r --arg instance "${INSTANCE}" '.data[] | select(.metadata.source=="ms-ml-camel-conv-history-bs" and ((.metadata.instance // "default") == $instance)) | .id')"$'\n'
  [ "$(echo "${BODY}" | jq -r .has_more)" = true ] || break
  after="$(echo "${BODY}" | jq -r .last_id)"
done
orphans="$( { printf '%s' "${ours}" | grep . || true; } | sort | comm -23 - <(echo "${known}") | wc -l | tr -d ' ')"
echo
echo "conversations checked: ${convs}, items checked: ${items}, orphans (ours in Foundry, not in the map): ${orphans}"
if [ "${bad}" -eq 0 ] && [ "${orphans}" -eq 0 ]; then echo "✅  OK: Foundry holds exactly what camel_history says"; else echo "❌  MISMATCH: ${bad} conversation(s) differ, ${orphans} orphan(s)"; exit 1; fi
