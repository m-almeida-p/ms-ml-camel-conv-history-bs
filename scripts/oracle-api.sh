#!/usr/bin/env bash
# The oracle: compares what conv-history-api returns with what the data says it should return. Read-only.
#
#   ./scripts/oracle-api.sh [base url]        default http://localhost:8086 (the container Karavan runs)
#
# The expected answer is computed here with plain SQL on camel_history, not through the API's code path, for every account
# that has conversations in Foundry and every conversation of it:
#   - the conversation list, as one page and as pages of 3 followed through the Link header;
#   - the messages of each conversation, as one page, as pages of 2 walked back from the newest, and as pages of 2 walked
#     forward from the first message.
# Times are cut to the millisecond, not rounded: the reference service does UnixMilli()/1000, and so does the API.
# Messages are compared whole: _id, type, role, authorId, text, received, source and metadata. The text comes from Foundry
# in the API and from conversation_messages here, so a match is the proof that Foundry holds what our table holds.
# This replaces the comparison with the Go service, which this phase does not run. Needs curl, jq, the cluster.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
BASE="${1:-${API_BASE_URL:-http://localhost:8086}}"
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }
curl -s -m 5 -o /dev/null "${BASE}/health" || { echo "❌  ${BASE} does not answer" >&2; exit 1; }

HDRS=""
get() { # PATH -> STATUS BODY HDRS
  local out hdr; out="$(mktemp)"; hdr="$(mktemp)"
  STATUS="$(curl -s -g -m 30 -o "${out}" -D "${hdr}" -w '%{http_code}' "${BASE}$1")" || STATUS=000
  BODY="$(cat "${out}")"; HDRS="$(tr -d '\r' < "${hdr}")"; rm -f "${out}" "${hdr}"
}
next_link() { echo "${HDRS}" | sed -n 's/^[Ll]ink: <\(.*\)>; rel=.*/\1/p'; }

walk() { # PATH KEY : follow Link; prints the pages' arrays, one JSON array per line, in the order read
  local path="$1" key="$2" n=0
  while [ -n "${path}" ] && [ "${n}" -lt 500 ]; do
    n=$((n + 1)); get "${path}"
    [ "${STATUS}" = 200 ] || { echo "ERROR status ${STATUS} on ${path}"; return 1; }
    echo "${BODY}" | jq -c ".${key}"
    path="$(next_link)"
  done
}

fail=0
verdict() { # label expected actual
  # numbers are normalised first: jq keeps the written form of an unchanged number, and 262.350 is 262.35
  if [ "$(echo "$2" | jq -cS 'walk(if type == "number" then . + 0 else . end)')" = "$(echo "$3" | jq -cS 'walk(if type == "number" then . + 0 else . end)')" ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); echo "        expected: $(echo "$2" | jq -c . | cut -c1-300)"; echo "        actual:   $(echo "$3" | jq -c . | cut -c1-300)"; fi
}

ACCOUNTS="$(sql "SELECT DISTINCT s.id_yape_account FROM camel_history.conversation_summaries s JOIN camel_history.foundry_conversation_map f USING (conversation_id) ORDER BY 1")"
[ -n "${ACCOUNTS}" ] || { echo "❌  no conversation of camel_history is in Foundry: nothing to compare" >&2; exit 1; }
accounts=0; convs=0; msgs=0

for account in ${ACCOUNTS}; do
  accounts=$((accounts + 1))
  echo "== account ${account}"
  expected_list="$(sql "SELECT coalesce(json_agg(json_build_object(
        '_id', s.conversation_id,
        'cursor', (extract(epoch FROM s.last_occurred_at) * 1000000)::bigint || '~' || s.conversation_id,
        'messageCount', s.message_count,
        'firstReceived', trunc(extract(epoch FROM s.first_occurred_at)::numeric, 3),
        'lastReceived', trunc(extract(epoch FROM s.last_occurred_at)::numeric, 3))
        ORDER BY s.last_occurred_at DESC, s.conversation_id DESC), '[]')
      FROM camel_history.conversation_summaries s JOIN camel_history.foundry_conversation_map f USING (conversation_id)
      WHERE s.id_yape_account = '${account}'")"
  get "/v1/conversations?idYapeAccount=${account}"
  verdict "list, one page" "${expected_list}" "$(echo "${BODY}" | jq -c .conversations)"
  verdict "list, pages of 3 followed through Link" "${expected_list}" "$(walk "/v1/conversations?idYapeAccount=${account}&page[size]=3" conversations | jq -cs 'add // []')"

  for cid in $(echo "${expected_list}" | jq -r '.[]._id'); do
    convs=$((convs + 1))
    expected="$(sql "SELECT coalesce(json_agg(json_build_object(
          '_id', m.sequence::text, 'type', m.type, 'role', m.role, 'authorId', m.author_id, 'text', m.text,
          'received', trunc(extract(epoch FROM m.occurred_at)::numeric, 3),
          'source', json_build_object('type', 'api'),
          'metadata', json_strip_nulls(json_build_object('sequence', m.sequence, 'eventName', m.event_name, 'truncated', m.truncated, 'flow', m.flow)))
          ORDER BY m.sequence), '[]')
        FROM camel_history.conversation_messages m JOIN camel_history.foundry_item_map i USING (conversation_id, sequence)
        WHERE m.conversation_id = '${cid}'")"
    n="$(echo "${expected}" | jq 'length')"; msgs=$((msgs + n))
    echo "-- ${cid} (${n} messages)"
    get "/v1/conversations/${cid}/messages"
    verdict "  messages, one page" "${expected}" "$(echo "${BODY}" | jq -c .messages)"
    verdict "  conversation _id" "\"${cid}\"" "$(echo "${BODY}" | jq -c '.conversation._id')"
    # pages of 2 from the newest, walking back: the pages come newest first, each oldest first inside
    verdict "  pages of 2 walked back" "${expected}" "$(walk "/v1/conversations/${cid}/messages?page[size]=2" messages | jq -cs 'reverse | add // []')"
    # pages of 2 from the first message, walking forward
    first="$(echo "${expected}" | jq -r '.[0]._id')"
    verdict "  pages of 2 walked forward" "${expected}" "$(walk "/v1/conversations/${cid}/messages?page[after]=${first}&page[size]=2" messages | jq -cs --argjson f "$(echo "${expected}" | jq -c '.[0]')" '[$f] + add')"
  done
done

echo
echo "accounts: ${accounts}, conversations: ${convs}, messages compared: ${msgs}"
if [ "${fail}" -eq 0 ]; then echo "✅  OK: the API returns exactly what the data says"; else echo "❌  MISMATCH: ${fail} comparison(s) differ"; exit 1; fi
