#!/usr/bin/env bash
# Test of the conv-history-sync project against the local cluster.
#
#   ./scripts/test-sync.sh              run every section
#   ./scripts/test-sync.sh base         run only the named sections (the list is at the end of the file)
#
# The sections that start the project use a throwaway topic and consumer group, the fake Foundry (scripts/fake-foundry.sh)
# and fixture rows in camel_history, all removed on exit. The real topic and the real groups are never touched.
# Needs: the cluster up, the camel_history migrations applied (through 000004), the broker, curl, jq, python3.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"

PROJECT="conv-history-sync"
CONTAINER="devmode-local-${PROJECT}"
RUN="$(date +%s)"
TOPIC="camel.sync.${RUN}"
GROUP="camel-sync-${RUN}"
FAKE_ENDPOINT="http://fake-foundry:8098/api/projects/fake"
KAFKA=(docker exec -i yape-kafka)


STARTED=0
EXTRA_ENV=()   # more NAME=value pairs for the project container (a section may restart the project with them)

require_docker
require_cluster_network
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "❌  python3 is required" >&2; exit 1; }

cleanup() {
  [ "${STARTED}" = 1 ] || return 0
  "${REPO_DIR}/scripts/devmode-local.sh" stop "${PROJECT}" >/dev/null 2>&1 || true
  if [ "${FOUNDRY_MODE}" = real ]; then
    for id in $(sql "SELECT foundry_conversation_id FROM camel_history.foundry_conversation_map WHERE conversation_id LIKE 'ts-%'" 2>/dev/null); do track_foundry_conversation "${id}"; done
    foundry_cleanup
  else
    curl -s -o /dev/null -X POST http://localhost:8098/__reset || true
  fi
  sql "DELETE FROM camel_history.foundry_conversation_map WHERE conversation_id LIKE 'ts-%';
       DELETE FROM camel_history.conversation_messages WHERE conversation_id LIKE 'ts-%'" >/dev/null 2>&1 || true
  "${KAFKA[@]}" kafka-topics --bootstrap-server kafka:29092 --delete --topic "${TOPIC}" >/dev/null 2>&1 || true
  "${KAFKA[@]}" kafka-consumer-groups --bootstrap-server kafka:29092 --delete --group "${GROUP}" >/dev/null 2>&1 || true
  docker start foundry-token >/dev/null 2>&1 || true   # the broker section stops it
  docker rm -f foundry-token-flaky >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_text() { docker logs "${CONTAINER}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
log_count() { local out; out="$(log_text)"; grep -cE "$1" <<< "${out}" || true; }

publish() { # TSV lines on stdin (see scripts/lib/events.py)
  python3 -I "${REPO_DIR}/scripts/lib/events.py" | "${KAFKA[@]}" kafka-console-producer --bootstrap-server kafka:29092 --topic "${TOPIC}" \
    --property parse.key=true --property "key.separator=$(printf '\t')" >/dev/null 2>&1
}

store_message() { # conversation_id sequence role text   (stands in for the history consumer's row)
  local author="acc-$1"; [ "$3" = appMaker ] && author="ms-ml-genai-agent-bs"
  sql "INSERT INTO camel_history.conversation_messages (conversation_id, sequence, role, author_id, text, event_name, id_yape_account, flow, occurred_at)
       VALUES ('$1', $2, '$3', '${author}', '$4', 'fixture', 'acc-$1', 'p2p', timestamptz '2026-11-18 10:00:00+00' + ($2 || ' seconds')::interval)
       ON CONFLICT (conversation_id, sequence) DO NOTHING" >/dev/null
}

wait_until() { # description, timeout in seconds, a shell expression that is true when done. It is evaluated again every second.
  local what="$1" limit="$2" condition="$3"
  for _ in $(seq 1 "${limit}"); do eval "${condition}" && return 0; sleep 1; done
  fail "timed out waiting for: ${what}"
  echo "    last relevant log lines:" >&2
  log_text | grep -vE 'Unknown keyword|^\s+at |^\s*\.\.\. [0-9]+ more|^$|Fetching project|ConnectException|UnresolvedAddress|Error: null' | tail -16 | cut -c1-520 | sed 's/^/      /' >&2
  return 1
}

DLQ_MARK=0
dlq_mark() { DLQ_MARK="$(log_count 'DLQ reason=')"; }
dlq_new() { echo "$(( $(log_count 'DLQ reason=') - DLQ_MARK ))"; }
synced() { log_count "Message synced conversation=$1 sequence=$2 "; }

group_lag() { # total lag of the throwaway group, 0 when everything is committed
  "${KAFKA[@]}" kafka-consumer-groups --bootstrap-server kafka:29092 --describe --group "${GROUP}" 2>/dev/null \
    | awk -v t="${TOPIC}" '$2==t && $6 ~ /^[0-9]+$/ {lag+=$6; seen=1} END {print seen ? lag+0 : "none"}'
}

relaunch_project() { # start the project again on the same topic and group (it replaces a running or killed container)
  local endpoint=""
  [ "${FOUNDRY_MODE}" = fake ] && endpoint="${FAKE_ENDPOINT}"
  "${REPO_DIR}/scripts/devmode-local.sh" "${PROJECT}" "APP_TOPIC=${TOPIC}" "APP_KAFKA_GROUPID=${GROUP}" "APP_FOUNDRY_ENDPOINT=${endpoint}" \
    "APP_SYNC_PROJECTIONWAITSECONDS=${PROJECTION_WAIT:-6}" "APP_FOUNDRY_TIMEOUTMS=${FOUNDRY_TIMEOUT_MS:-2000}" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} >/dev/null
  for _ in $(seq 1 120); do
    [ "$(log_count 'Successfully joined group')" -gt 0 ] && return 0
    if [ "$(log_count 'Error starting Camel|FailedToCreateRoute|Compilation error')" -gt 0 ]; then
      log_text | grep -E 'ERROR|error:|Caused by' | head -8 >&2; echo "❌  ${PROJECT} did not start" >&2; exit 1
    fi
    sleep 2
  done
  echo "❌  ${PROJECT} did not join the group" >&2; exit 1
}

start_project() {
  STARTED=1
  echo "🧪  topic ${TOPIC}, group ${GROUP}, Foundry: ${FOUNDRY_MODE}"
  "${KAFKA[@]}" kafka-topics --bootstrap-server kafka:29092 --create --topic "${TOPIC}" --partitions 3 --replication-factor 1 >/dev/null 2>&1
  compose up -d foundry-token >/dev/null 2>&1
  local endpoint=""
  if [ "${FOUNDRY_MODE}" = fake ]; then
    "${REPO_DIR}/scripts/fake-foundry.sh" start >/dev/null; curl -s -o /dev/null -X POST http://localhost:8098/__reset
    endpoint="${FAKE_ENDPOINT}"
  fi
  echo "🚀  starting ${PROJECT} (the first start downloads dependencies, about a minute)"
  relaunch_project
}

section_base() {
  echo "== base: the copied beans are the consumer's beans"
  for f in ConversationEventDecoder.java PoisonRecordException.java OffsetCommit.java; do
    check "${f} is identical to the consumer's" "$(shasum "${REPO_DIR}/conv-history-consumer/${f}" | cut -c1-40)" "$(shasum "${REPO_DIR}/${PROJECT}/${f}" | cut -c1-40)"
  done
  check "the group is not the consumer's" true "$(! grep -q 'groupId=ms-ml-camel-conv-history-bs$' "${REPO_DIR}/${PROJECT}/application.properties" && echo true || echo false)"
  check "the group is not the original service's" true "$(! grep -q 'ms-ml-conv-history-bs$' "${REPO_DIR}/${PROJECT}/application.properties" && echo true || echo false)"
  check "no secret and no endpoint in the properties" 0 "$(grep -cE 'client_secret|password=[^$]|https://.*\.azure\.com' "${REPO_DIR}/${PROJECT}/application.properties" | tr -d ' ')"
}

section_receive() {
  echo "== receive: chat messages go to route 2, the rest is skipped, poison goes to the dead-letter log"
  dlq_mark
  store_message ts-r1 1 appUser "hola"
  store_message ts-r1 2 appMaker "hola, en que te ayudo"
  store_message ts-r1 3 appMaker "no puedo ayudarte con eso"
  printf '%s\n' \
    $'ts-r1\t1\tUserMessageSent\thola' \
    $'ts-r1\t2\tAgentMessageSent\thola, en que te ayudo\tagent' \
    $'ts-r1\t3\tGuardrailResponseSent\tno puedo ayudarte con eso\tagent' \
    $'ts-r1\t4\tToolCallSummary\tlookup\tagent' \
    $'ts-r1\t5\tToolActionSummarized\tpay\tagent' \
    $'RAW\tts-r1\tnot json at all' \
    $'TOMBSTONE\tts-r1' | publish
  wait_until "the 7 records handled" 90 '[ "$(( $(log_count "Message synced conversation=ts-r1 ") + $(log_count "Not a chat message") + $(dlq_new) + $(log_count "Tombstone skipped") ))" -ge 7 ]'
  sleep 3
  check "3 chat messages reach route 2 and are synced" 3 "$(log_count 'Message synced conversation=ts-r1 sequence=[123] ')"
  check "2 other events are skipped" 2 "$(log_count 'Not a chat message, skipped event=Tool')"
  check "1 poison record in the dead-letter log" 1 "$(dlq_new)"
  check_contains "the dead-letter line carries the body" "not json at all" "$(log_text | grep 'DLQ reason=' | tail -1)"
  check "1 tombstone skipped" 1 "$(log_count 'Tombstone skipped')"
  check "every offset is committed (no lag)" 0 "$(group_lag)"
}

fid() { sql "SELECT foundry_conversation_id FROM camel_history.foundry_conversation_map WHERE conversation_id='$1'"; }
texts() { echo "${BODY}" | jq -r '[.data[]? | (.content|if type=="array" then .[0].text else . end)] | join(",")'; }
section_first() {
  echo "== first: the first message creates the Foundry conversation and both maps"
  dlq_mark
  store_message ts-f1 1 appUser "hola, quiero yapear"
  store_message ts-f2 1 appMaker "claro, te ayudo"
  printf '%s\n' $'ts-f1\t1\tUserMessageSent\thola, quiero yapear' $'ts-f2\t1\tAgentMessageSent\tclaro, te ayudo\tagent' | publish
  wait_until "both first messages synced" 90 '[ "$(( $(synced ts-f1 1) + $(synced ts-f2 1) ))" -ge 2 ]'
  check "a conversation row per conversation" 2 "$(sql "SELECT count(*) FROM camel_history.foundry_conversation_map WHERE conversation_id IN ('ts-f1','ts-f2')")"
  check "an item row per message" 2 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id IN ('ts-f1','ts-f2')")"
  check "last synced sequence is the message's" 1 "$(sql "SELECT last_synced_sequence FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-f1'")"
  fx "/openai/v1/conversations/$(fid ts-f1)"
  check "Foundry keeps our conversation id in the metadata" ts-f1 "$(echo "${BODY}" | jq -r .metadata.conversation_id)"
  check "and the source" ms-ml-camel-conv-history-bs "$(echo "${BODY}" | jq -r .metadata.source)"
  fx "/openai/v1/conversations/$(fid ts-f1)/items?order=asc"
  check "the user message is the stored text" "hola, quiero yapear" "$(texts)"
  check "as a user item" user "$(echo "${BODY}" | jq -r '.data[0].role')"
  check "the item id in the map is Foundry's item" "$(echo "${BODY}" | jq -r '.data[0].id')" "$(sql "SELECT foundry_item_id FROM camel_history.foundry_item_map WHERE conversation_id='ts-f1' AND sequence=1")"
  fx "/openai/v1/conversations/$(fid ts-f2)/items?order=asc"
  check "the agent message is the stored text" "claro, te ayudo" "$(texts)"
  check "as an assistant item" assistant "$(echo "${BODY}" | jq -r '.data[0].role')"
  check "with output_text content" output_text "$(echo "${BODY}" | jq -r '.data[0].content[0].type')"
  check "no dead-letter line in this section" 0 "$(dlq_new)"
}

section_order() {
  echo "== order: messages arrive in sequence order, gaps included, and a repeat sends nothing"
  local seqs=(1 2 3 5 6 9) roles=(appUser appMaker appUser appMaker appUser appMaker) i
  for i in 0 1 2 3 4 5; do store_message ts-o1 "${seqs[$i]}" "${roles[$i]}" "m${seqs[$i]}"; done
  local lines=()
  for i in 0 1 2 3 4 5; do
    local ev=UserMessageSent; [ "${roles[$i]}" = appMaker ] && ev=AgentMessageSent
    lines+=("ts-o1"$'\t'"${seqs[$i]}"$'\t'"${ev}"$'\t'"m${seqs[$i]}")
  done
  printf '%s\n' "${lines[@]}" | publish
  wait_until "6 messages synced" 90 '[ "$(log_count "Message synced conversation=ts-o1 ")" -ge 6 ]'
  fx "/openai/v1/conversations/$(fid ts-o1)/items?order=asc&limit=100"
  check "Foundry holds them in sequence order" "m1,m2,m3,m5,m6,m9" "$(texts)"
  check "the item map has 6 rows" 6 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-o1'")"
  check "last synced sequence is 9" 9 "$(sql "SELECT last_synced_sequence FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-o1'")"
  check "only one Foundry conversation was made" 1 "$(sql "SELECT count(*) FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-o1'")"
  echo "   -- the same 6 events again"
  printf '%s\n' "${lines[@]}" | publish
  wait_until "6 repeats recognised" 60 '[ "$(log_count "Message duplicate conversation=ts-o1 ")" -ge 6 ]'
  fx "/openai/v1/conversations/$(fid ts-o1)/items?order=asc&limit=100"
  check "Foundry still holds 6 items" "m1,m2,m3,m5,m6,m9" "$(texts)"
  check "the item map still has 6 rows" 6 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-o1'")"
}

section_wait() {
  echo "== wait: the sync waits for the history consumer's row, for a while"
  printf '%s\n' $'ts-w1\t1\tUserMessageSent\tllega tarde' | publish
  sleep 3
  check "nothing is sent while the row is missing" 0 "$(synced ts-w1 1)"
  store_message ts-w1 1 appUser "llega tarde"
  wait_until "the late row is picked up" 30 '[ "$(synced ts-w1 1)" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-w1)/items?order=asc"
  check "it is sent once the row exists" "llega tarde" "$(texts)"
  check "and the late message was not dead-lettered" 0 "$(log_text | grep -c 'DLQ reason=projection-missing.*ts-w1' || true)"
  echo "   -- a row that never comes (the wait is ${PROJECTION_WAIT:-6} s here), then a normal message behind it"
  printf '%s\n' $'ts-w2\t1\tUserMessageSent\tnunca llega' | publish
  wait_until "the missing row dead-lettered" 60 '[ "$(log_count "DLQ reason=projection-missing.*ts-w2")" -ge 1 ]'
  check_contains "the line names the conversation table" "field=conversation_messages" "$(log_text | grep 'DLQ reason=projection-missing.*ts-w2' | head -1)"
  store_message ts-w3 1 appUser "sigue"
  printf '%s\n' $'ts-w3\t1\tUserMessageSent\tsigue' | publish
  wait_until "the next message is not blocked" 60 '[ "$(synced ts-w3 1)" -ge 1 ]'
  check "no conversation was made for the missing one" 0 "$(sql "SELECT count(*) FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-w2'")"
}

section_reconcile() {
  echo "== reconcile: an item Foundry kept but we never recorded is adopted, not sent twice"
  if [ "${FOUNDRY_MODE}" != fake ]; then
    # The real Foundry cannot be told to lose an answer, so the state a crash leaves is made by hand: the item is already in
    # Foundry and the item map has no row for it. What is tested is the same: the list after the last mapped item, on the real API.
    echo "   (real Foundry: the item is put there by hand, which is exactly the state a lost answer leaves)"
    store_message ts-c1 1 appUser "m1"; store_message ts-c1 2 appMaker "m2"; store_message ts-c1 3 appUser "m3"
    printf '%s\n' $'ts-c1\t1\tUserMessageSent\tm1' | publish
    wait_until "the first message synced" 60 '[ "$(synced ts-c1 1)" -ge 1 ]'
    fxw POST "/openai/v1/conversations/$(fid ts-c1)/items" '{"items":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"m2"}]}]}'
    printf '%s\n' $'ts-c1\t2\tAgentMessageSent\tm2\tagent' | publish
    wait_until "message 2 recorded" 60 '[ "$(synced ts-c1 2)" -ge 1 ]'
    fx "/openai/v1/conversations/$(fid ts-c1)/items?order=asc&limit=100"
    check "on the real Foundry each message is still there once" "m1,m2" "$(texts)"
    check "the real item was adopted, not sent again" 1 "$(log_count 'Message adopted conversation=ts-c1 sequence=2')"
    check "the map holds the real item's id" "$(echo "${BODY}" | jq -r '.data[1].id')" "$(sql "SELECT foundry_item_id FROM camel_history.foundry_item_map WHERE conversation_id='ts-c1' AND sequence=2")"
    printf '%s\n' $'ts-c1\t3\tUserMessageSent\tm3' | publish
    wait_until "message 3" 60 '[ "$(synced ts-c1 3)" -ge 1 ]'
    fx "/openai/v1/conversations/$(fid ts-c1)/items?order=asc&limit=100"
    check "and the conversation goes on in order" "m1,m2,m3" "$(texts)"
    return 0
  fi
  store_message ts-c1 1 appUser "m1"; store_message ts-c1 2 appMaker "m2"; store_message ts-c1 3 appUser "m3"
  printf '%s\n' $'ts-c1\t1\tUserMessageSent\tm1' | publish
  wait_until "the first message synced" 60 '[ "$(synced ts-c1 1)" -ge 1 ]'
  echo "   -- the next add is applied by Foundry, but its answer never arrives (the crash window)"
  fake_fail '{"mode":"drop","count":1,"method":"POST"}'
  printf '%s\n' $'ts-c1\t2\tAgentMessageSent\tm2\tagent' | publish
  wait_until "the message recorded after the retry" 60 '[ "$(synced ts-c1 2)" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-c1)/items?order=asc&limit=100"
  check "Foundry holds each message once" "m1,m2" "$(texts)"
  check "the item map has both rows" 2 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-c1'")"
  check "the retry found the item and adopted it" 1 "$(log_count 'Message adopted conversation=ts-c1 sequence=2')"
  check "the map holds Foundry's own item id" "$(echo "${BODY}" | jq -r '.data[1].id')" "$(sql "SELECT foundry_item_id FROM camel_history.foundry_item_map WHERE conversation_id='ts-c1' AND sequence=2")"
  check "last synced sequence moved to 2" 2 "$(sql "SELECT last_synced_sequence FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-c1'")"
  printf '%s\n' $'ts-c1\t3\tUserMessageSent\tm3' | publish
  wait_until "the next message after it" 60 '[ "$(synced ts-c1 3)" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-c1)/items?order=asc&limit=100"
  check "and the conversation goes on in order" "m1,m2,m3" "$(texts)"
  echo "   -- two applied-but-lost adds in a row, for messages 2 and 3 of another conversation"
  store_message ts-c2 1 appUser "a1"; store_message ts-c2 2 appMaker "a2"; store_message ts-c2 3 appUser "a3"
  printf '%s\n' $'ts-c2\t1\tUserMessageSent\ta1' | publish
  wait_until "ts-c2 created" 60 '[ "$(synced ts-c2 1)" -ge 1 ]'
  fake_fail '{"mode":"drop","count":2,"method":"POST"}'
  printf '%s\n' $'ts-c2\t2\tAgentMessageSent\ta2\tagent' $'ts-c2\t3\tUserMessageSent\ta3' | publish
  wait_until "both recorded" 90 '[ "$(( $(synced ts-c2 2) + $(synced ts-c2 3) ))" -ge 2 ]'
  fx "/openai/v1/conversations/$(fid ts-c2)/items?order=asc&limit=100"
  check "still each message once, in order" "a1,a2,a3" "$(texts)"
  check "three rows in the item map" 3 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-c2'")"
}

fake_items() { curl -s http://localhost:8098/__state | jq -r ".items[\"$1\"] // 0"; }
fake_conversations() { curl -s http://localhost:8098/__state | jq -r '.conversations'; }
orphans_of() { # our conversation id: how many Foundry conversations carry it in their metadata but are not the mapped one
  fx "/openai/v1/conversations?limit=100&order=desc"
  echo "${BODY}" | jq -r --arg c "$1" '.data[] | select(.metadata.conversation_id == $c) | .id' | grep -vxF "$(fid "$1")" | wc -l | tr -d ' '
}
kill_sync() { docker kill "${CONTAINER}" >/dev/null; }

section_crash() {
  echo "== crash: the sync is killed (docker kill, SIGKILL) while Foundry holds work it never recorded"
  if [ "${FOUNDRY_MODE}" != fake ]; then echo "   (needs the fake Foundry to hold an answer back: skipped with FOUNDRY_MODE=real)"; return 0; fi
  dlq_mark

  echo "   -- 1. killed after Foundry kept the item and before the sync recorded it"
  store_message ts-k1 1 appUser "m1"; store_message ts-k1 2 appMaker "m2"; store_message ts-k1 3 appUser "m3"
  printf '%s\n' $'ts-k1\t1\tUserMessageSent\tm1' | publish
  wait_until "message 1 synced" 60 '[ "$(synced ts-k1 1)" -ge 1 ]'
  local k1; k1="$(fid ts-k1)"
  fake_fail '{"mode":"late","count":1,"delayMs":25000,"method":"POST"}'
  printf '%s\n' $'ts-k1\t2\tAgentMessageSent\tm2\tagent' | publish
  wait_until "Foundry applied message 2" 40 "[ \"\$(fake_items ${k1})\" = 2 ]"
  kill_sync
  fx "/openai/v1/conversations/${k1}/items?order=asc&limit=100"
  check "the process is dead" false "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}")"
  check "Foundry holds the item the dead sync never recorded" "m1,m2" "$(texts)"
  check "the item map has no row for it" 0 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-k1' AND sequence=2")"
  check "its offset was never committed: the group still owes records" true "$([ "$(group_lag)" != 0 ] && [ "$(group_lag)" != none ] && echo true || echo false)"
  relaunch_project
  wait_until "message 2 recorded after the restart" 90 '[ "$(synced ts-k1 2)" -ge 1 ]'
  fx "/openai/v1/conversations/${k1}/items?order=asc&limit=100"
  check "after the restart Foundry still holds each message once" "m1,m2" "$(texts)"
  check "the restarted sync adopted the item instead of sending it again" 1 "$(log_count 'Message adopted conversation=ts-k1 sequence=2')"
  check "the item map has both rows, with Foundry's own ids" "$(echo "${BODY}" | jq -r '[.data[].id] | join(",")')" "$(sql "SELECT string_agg(foundry_item_id, ',' ORDER BY sequence) FROM camel_history.foundry_item_map WHERE conversation_id='ts-k1'")"
  printf '%s\n' $'ts-k1\t3\tUserMessageSent\tm3' | publish
  wait_until "message 3 after the recovery" 60 '[ "$(synced ts-k1 3)" -ge 1 ]'
  fx "/openai/v1/conversations/${k1}/items?order=asc&limit=100"
  check "and the conversation goes on in order" "m1,m2,m3" "$(texts)"

  echo "   -- 2. killed while creating a conversation: Foundry made it, the sync never recorded it"
  store_message ts-k2 1 appUser "c1"
  local before; before="$(fake_conversations)"
  fake_fail '{"mode":"late","count":1,"delayMs":25000,"method":"POST"}'
  printf '%s\n' $'ts-k2\t1\tUserMessageSent\tc1' | publish
  wait_until "Foundry created the conversation" 40 "[ \"\$(fake_conversations)\" -gt ${before} ]"
  kill_sync
  check "the sync recorded no map row" 0 "$(sql "SELECT count(*) FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-k2'")"
  relaunch_project
  wait_until "the message synced after the restart" 90 '[ "$(synced ts-k2 1)" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-k2)/items?order=asc&limit=100"
  check "the mapped conversation holds the message once" "c1" "$(texts)"
  check "ONE ORPHAN is left: the conversation the dead process made (a known limit; foundry-cleanup-orphans.sh removes it)" 1 "$(orphans_of ts-k2)"
  check "the map names exactly one conversation" 1 "$(sql "SELECT count(*) FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-k2'")"

  echo "   -- 3. killed in the middle of a rebuild"
  store_message ts-k3 1 appUser "r1"; store_message ts-k3 2 appMaker "r2"; store_message ts-k3 3 appUser "r3"
  printf '%s\n' $'ts-k3\t1\tUserMessageSent\tr1' $'ts-k3\t3\tUserMessageSent\tr3' | publish
  wait_until "messages 1 and 3 synced" 60 '[ "$(( $(synced ts-k3 1) + $(synced ts-k3 3) ))" -ge 2 ]'
  local old; old="$(fid ts-k3)"
  before="$(fake_conversations)"
  fake_fail '{"mode":"late","count":1,"delayMs":25000,"method":"POST"}'
  printf '%s\n' $'ts-k3\t2\tAgentMessageSent\tr2\tagent' | publish      # a late message: the conversation must be rebuilt
  wait_until "the rebuild created the new conversation" 40 "[ \"\$(curl -s http://localhost:8098/__state | jq -r '.items | length')\" -ge 0 ] && [ \"\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8098/api/projects/fake/openai/v1/conversations/${old} -H 'Authorization: Bearer t')\" = 404 ]"
  kill_sync
  check "the old Foundry conversation was already deleted by the rebuild" 404 "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8098/api/projects/fake/openai/v1/conversations/${old}" -H 'Authorization: Bearer t')"
  check "but the map still points at it" "${old}" "$(fid ts-k3)"
  relaunch_project
  wait_until "the rebuild finished after the restart" 90 '[ "$(log_count "Conversation rebuilt conversation=ts-k3")" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-k3)/items?order=asc&limit=100"
  check "the rebuilt conversation holds all three, in order" "r1,r2,r3" "$(texts)"
  check "the item map has three rows" 3 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-k3'")"
  check "the half-built conversation of the dead process is an orphan" 1 "$(orphans_of ts-k3)"
  # not dlq_new: the container was killed and relaunched, so its log (and the counter taken at the start) began again
  check "nothing of this section was dead-lettered" 0 "$(log_text | grep -c 'DLQ reason=.*ts-k[123]' || true)"
}


section_real401() {
  echo "== real401: a REAL 401 from Foundry makes the sync ask the broker again, and nothing is lost"
  if [ "${FOUNDRY_MODE}" != real ]; then echo "   (only against the real Foundry: skipped with the fake)"; return 0; fi
  docker rm -f foundry-token-flaky >/dev/null 2>&1 || true
  docker run -d --name foundry-token-flaky --network yape-local -v "${REPO_DIR}/scripts/lib/flaky-broker.py:/app/flaky.py:ro" \
    python:3.13-alpine python -u /app/flaky.py >/dev/null
  sleep 2
  EXTRA_ENV=("APP_FOUNDRY_TOKENURL=http://foundry-token-flaky:8099/token")
  relaunch_project
  store_message ts-r4 1 appUser "token malo primero"
  printf '%s\n' $'ts-r4\t1\tUserMessageSent\ttoken malo primero' | publish
  wait_until "the message synced after the real 401" 90 '[ "$(synced ts-r4 1)" -ge 1 ]'
  check "Foundry really answered 401 to the junk token" true "$([ "$(log_count 'Foundry answered 401')" -ge 1 ] && echo true || echo false)"
  check "the sync asked the broker again (two tokens served)" 2 "$(docker exec foundry-token-flaky python -c "import urllib.request,json; print(json.load(urllib.request.urlopen('http://localhost:8099/stats'))['n'])")"
  fx "/openai/v1/conversations/$(fid ts-r4)/items?order=asc&limit=100"
  check "the message is in Foundry exactly once" "token malo primero" "$(texts)"
  check "no dead-letter line for it" 0 "$(log_text | grep -c 'DLQ reason=.*ts-r4' || true)"
  docker rm -f foundry-token-flaky >/dev/null 2>&1 || true
  EXTRA_ENV=()
}

section_rebuild() {
  echo "== rebuild: a conversation Foundry cannot repair by adding is built again from the stored messages"
  dlq_mark
  echo "   -- a late event: message 2 arrives after message 3"
  store_message ts-l1 1 appUser "m1"; store_message ts-l1 2 appMaker "m2"; store_message ts-l1 3 appUser "m3"
  printf '%s\n' $'ts-l1\t1\tUserMessageSent\tm1' $'ts-l1\t3\tUserMessageSent\tm3' | publish
  wait_until "messages 1 and 3 synced" 60 '[ "$(( $(synced ts-l1 1) + $(synced ts-l1 3) ))" -ge 2 ]'
  local old; old="$(fid ts-l1)"
  fx "/openai/v1/conversations/${old}/items?order=asc"; check "Foundry has the gap before the late event" "m1,m3" "$(texts)"
  printf '%s\n' $'ts-l1\t2\tAgentMessageSent\tm2\tagent' | publish
  wait_until "the late message rebuilt the conversation" 60 '[ "$(log_count "Conversation rebuilt conversation=ts-l1 reason=late-event")" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-l1)/items?order=asc&limit=100"
  check "the new conversation holds all three in order" "m1,m2,m3" "$(texts)"
  check "it is a new Foundry conversation" true "$([ "$(fid ts-l1)" != "${old}" ] && echo true || echo false)"
  fx "/openai/v1/conversations/${old}"
  check "the old Foundry conversation was deleted" 404 "${STATUS}"
  check "the item map has three rows" 3 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-l1'")"
  check "last synced sequence is 3" 3 "$(sql "SELECT last_synced_sequence FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-l1'")"
  check "every mapped item exists in the new conversation" 3 "$(for id in $(sql "SELECT foundry_item_id FROM camel_history.foundry_item_map WHERE conversation_id='ts-l1'"); do fx "/openai/v1/conversations/$(fid ts-l1)/items/${id}"; echo "${STATUS}"; done | grep -c '^200$')"
  printf '%s\n' $'ts-l1\t3\tUserMessageSent\tm3' | publish
  wait_until "the repeat of message 3 recognised" 60 '[ "$(log_count "Message duplicate conversation=ts-l1 sequence=3")" -ge 1 ]'

  echo "   -- Foundry lost the conversation"
  store_message ts-g1 1 appUser "g1"; store_message ts-g1 2 appMaker "g2"
  printf '%s\n' $'ts-g1\t1\tUserMessageSent\tg1' | publish
  wait_until "message 1 synced" 60 '[ "$(synced ts-g1 1)" -ge 1 ]'
  old="$(fid ts-g1)"; fxw DELETE "/openai/v1/conversations/${old}"
  printf '%s\n' $'ts-g1\t2\tAgentMessageSent\tg2\tagent' | publish
  wait_until "the lost conversation rebuilt" 60 '[ "$(log_count "Conversation rebuilt conversation=ts-g1 reason=gone")" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-g1)/items?order=asc&limit=100"
  check "the new conversation holds both messages" "g1,g2" "$(texts)"
  check "the map points at the new conversation" true "$([ "$(fid ts-g1)" != "${old}" ] && echo true || echo false)"
  check "two rows in the item map" 2 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-g1'")"

  echo "   -- Foundry holds an item nobody can account for"
  store_message ts-u1 1 appUser "u1"; store_message ts-u1 2 appMaker "u2"
  printf '%s\n' $'ts-u1\t1\tUserMessageSent\tu1' | publish
  wait_until "message 1 synced" 60 '[ "$(synced ts-u1 1)" -ge 1 ]'
  fxw POST "/openai/v1/conversations/$(fid ts-u1)/items" '{"items":[{"type":"message","role":"user","content":"stray"}]}'
  printf '%s\n' $'ts-u1\t2\tAgentMessageSent\tu2\tagent' | publish
  wait_until "the unknown item rebuilt the conversation" 60 '[ "$(log_count "Conversation rebuilt conversation=ts-u1 reason=unknown-items")" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-u1)/items?order=asc&limit=100"
  check "the stray item is gone and the messages are in order" "u1,u2" "$(texts)"
  check "nothing was dead-lettered in this section" 0 "$(dlq_new)"
}

retries_for() { log_count "Failed delivery.*$1"; }

section_errors() {
  echo "== errors: a Foundry that is down or slow is waited for; a refusal is dead-lettered and the partition goes on"
  if [ "${FOUNDRY_MODE}" != fake ]; then echo "   (needs the fake Foundry's faults: skipped with FOUNDRY_MODE=real)"; return 0; fi
  dlq_mark
  local mode n
  for mode in 429 500 401; do
    n=$((n + 1)); local c="ts-e${n}"
    echo "   -- Foundry answers ${mode} three times to the call that creates a conversation"
    store_message "${c}" 1 appUser "hola ${mode}"
    fake_fail "{\"mode\":\"${mode}\",\"count\":3,\"method\":\"POST\"}"
    printf '%s\n' "${c}"$'\t1\tUserMessageSent\t'"hola ${mode}" | publish
    wait_until "${c} synced after the retries" 90 "[ \"\$(synced ${c} 1)\" -ge 1 ]"
    fx "/openai/v1/conversations/$(fid "${c}")/items?order=asc&limit=100"
    check "${mode}: the message is in Foundry exactly once" "hola ${mode}" "$(texts)"
    check "${mode}: one conversation in the map" 1 "$(sql "SELECT count(*) FROM camel_history.foundry_conversation_map WHERE conversation_id='${c}'")"
    check "${mode}: the retries are in the log" true "$([ "$(retries_for "Foundry answered ${mode}")" -ge 3 ] && echo true || echo false)"
  done
  check "none of that went to the dead-letter log" 0 "$(dlq_new)"

  echo "   -- Foundry refuses a message for good (400), and the next message of the conversation still goes through"
  store_message ts-e4 1 appUser "refusado"; store_message ts-e4 2 appMaker "sigue"
  fake_fail '{"mode":"400","count":1,"method":"POST"}'
  printf '%s\n' $'ts-e4\t1\tUserMessageSent\trefusado' $'ts-e4\t2\tAgentMessageSent\tsigue\tagent' | publish
  wait_until "the message behind the refused one synced" 90 '[ "$(synced ts-e4 2)" -ge 1 ]'
  check "one dead-letter line" 1 "$(dlq_new)"
  check_contains "with the reason" "DLQ reason=foundry-rejected field=http-400" "$(log_text | grep 'DLQ reason=foundry-rejected' | tail -1)"
  check_contains "and the body, to replay it" "refusado" "$(log_text | grep 'DLQ reason=foundry-rejected' | tail -1)"
  fx "/openai/v1/conversations/$(fid ts-e4)/items?order=asc&limit=100"
  check "Foundry holds only the message that was not refused" "sigue" "$(texts)"
  check "the refused message has no item row" 0 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-e4' AND sequence=1")"

  echo "   -- Foundry is slower than the timeout (${FOUNDRY_TIMEOUT_MS:-2000} ms) on a read"
  store_message ts-e5 1 appUser "p1"; store_message ts-e5 2 appMaker "p2"
  printf '%s\n' $'ts-e5\t1\tUserMessageSent\tp1' | publish
  wait_until "ts-e5 first message synced" 60 '[ "$(synced ts-e5 1)" -ge 1 ]'
  fake_fail '{"mode":"slow","count":1,"delayMs":4500,"method":"GET"}'
  printf '%s\n' $'ts-e5\t2\tAgentMessageSent\tp2\tagent' | publish
  wait_until "ts-e5 second message synced after the timeout" 90 '[ "$(synced ts-e5 2)" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-e5)/items?order=asc&limit=100"
  check "the timeout was retried and nothing was duplicated" "p1,p2" "$(texts)"
  check "the timeout is in the log" true "$([ "$(retries_for 'did not answer GET')" -ge 1 ] && echo true || echo false)"
}

all_item_texts() { # a Foundry conversation id: the text of every item, oldest first, each followed by "|" (pages of 20)
  local after="" out="" more=true
  while [ "${more}" = true ]; do
    fx "/openai/v1/conversations/$1/items?order=asc&limit=20${after:+&after=${after}}"
    out+="$(echo "${BODY}" | jq -j '[.data[]? | (.content|if type=="array" then .[0].text else . end)] | map(. + "|") | add // ""')"
    more="$(echo "${BODY}" | jq -r '.has_more // false')"; after="$(echo "${BODY}" | jq -r '.data[-1].id // empty')"
  done
  printf '%s' "${out}"
}

sha() { shasum -a 256 | cut -c1-64; }

section_edge() {
  echo "== edge: a long conversation, the whole sync repeated, interleaved conversations, awkward text"
  if [ "${FOUNDRY_MODE}" != fake ]; then echo "   (skipped with FOUNDRY_MODE=real: it sends hundreds of items)"; return 0; fi
  dlq_mark

  echo "   -- 130 messages in one conversation (more than a page of 100, more than 6 pages of 20)"
  sql "INSERT INTO camel_history.conversation_messages (conversation_id, sequence, role, author_id, text, event_name, id_yape_account, flow, occurred_at)
       SELECT 'ts-x1', n, CASE WHEN n % 2 = 1 THEN 'appUser' ELSE 'appMaker' END, CASE WHEN n % 2 = 1 THEN 'acc-ts-x1' ELSE 'ms-ml-genai-agent-bs' END,
              'long-m' || n, 'fixture', 'acc-ts-x1', 'p2p', timestamptz '2026-11-18 10:00:00+00' + (n || ' seconds')::interval
       FROM generate_series(1, 130) n ON CONFLICT DO NOTHING" >/dev/null
  python3 -I -c '
for n in range(1, 131):
    print("ts-x1\t%d\t%s\tlong-m%d%s" % (n, "UserMessageSent" if n % 2 else "AgentMessageSent", n, "" if n % 2 else "\tagent"))' > "/tmp/ts-x1.$$"
  publish < "/tmp/ts-x1.$$"
  wait_until "ts-x1: 130 messages synced" 300 '[ "$(synced ts-x1 130)" -ge 1 ] && [ "$(log_count "Message synced conversation=ts-x1 ")" -ge 130 ]'
  local expected; expected="$(seq 1 130 | sed 's/^/long-m/; s/$/|/' | tr -d '\n')"
  check "Foundry holds the 130 messages, in order, once each" "${expected}" "$(all_item_texts "$(fid ts-x1)")"
  check "the item map has 130 rows" 130 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-x1'")"
  check "last synced sequence is 130" 130 "$(sql "SELECT last_synced_sequence FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-x1'")"
  check "one Foundry conversation was made for it" 1 "$(sql "SELECT count(*) FROM camel_history.foundry_conversation_map WHERE conversation_id='ts-x1'")"

  echo "   -- the complete sync repeated: the same 130 events again"
  local items_before conv_before; items_before="$(fake_items "$(fid ts-x1)")"; conv_before="$(fake_conversations)"
  publish < "/tmp/ts-x1.$$"
  wait_until "ts-x1: all 130 repeats recognised" 300 '[ "$(log_count "Message duplicate conversation=ts-x1 ")" -ge 130 ]'
  check "Foundry still holds 130 items" "${items_before}" "$(fake_items "$(fid ts-x1)")"
  check "no Foundry conversation was added" "${conv_before}" "$(fake_conversations)"
  check "the item map has still 130 rows" 130 "$(sql "SELECT count(*) FROM camel_history.foundry_item_map WHERE conversation_id='ts-x1'")"
  check "and no message was synced twice" 130 "$(log_count 'Message synced conversation=ts-x1 ')"
  rm -f "/tmp/ts-x1.$$"

  echo "   -- six conversations interleaved across the three partitions"
  sql "INSERT INTO camel_history.conversation_messages (conversation_id, sequence, role, author_id, text, event_name, id_yape_account, flow, occurred_at)
       SELECT c, n, CASE WHEN n % 2 = 1 THEN 'appUser' ELSE 'appMaker' END, CASE WHEN n % 2 = 1 THEN 'acc-' || c ELSE 'ms-ml-genai-agent-bs' END,
              c || '-m' || n, 'fixture', 'acc-' || c, 'p2p', timestamptz '2026-11-18 11:00:00+00' + (n || ' seconds')::interval
       FROM unnest(ARRAY['ts-i1','ts-i2','ts-i3','ts-i4','ts-i5','ts-i6']) c, generate_series(1, 8) n ON CONFLICT DO NOTHING" >/dev/null
  python3 -I -c '
for n in range(1, 9):
    for c in ("ts-i1", "ts-i2", "ts-i3", "ts-i4", "ts-i5", "ts-i6"):
        print("%s\t%d\t%s\t%s-m%d%s" % (c, n, "UserMessageSent" if n % 2 else "AgentMessageSent", c, n, "" if n % 2 else "\tagent"))' | publish
  wait_until "the 48 interleaved messages synced" 240 '[ "$(log_count "Message synced conversation=ts-i[1-6] ")" -ge 48 ]'
  local c
  for c in ts-i1 ts-i2 ts-i3 ts-i4 ts-i5 ts-i6; do
    expected="$(seq 1 8 | sed "s/^/${c}-m/; s/\$/|/" | tr -d '\n')"
    check "${c}: its 8 messages are in Foundry in order, and only its own" "${expected}" "$(all_item_texts "$(fid "${c}")")"
  done
  check "six conversations, six Foundry conversations" 6 "$(sql "SELECT count(DISTINCT foundry_conversation_id) FROM camel_history.foundry_conversation_map WHERE conversation_id LIKE 'ts-i%'")"

  echo "   -- awkward text goes to Foundry byte for byte (compared by SHA-256 with what Postgres holds)"
  python3 -I - <<'SQLGEN' | docker exec -i yape-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q >/dev/null
texts = [
    "hola", "\U0001F468‍\U0001F469‍\U0001F467 \U0001F44D\U0001F3FD", "é vs é", "שלום مرحبا 中文",
    "line1\nline2\ttab\r\nend", "\\ \"quotes\" 'single' {\"json\":true} <b>&amp;</b> '; DROP TABLE x;--", "   spaces around   ", "", "á" * 20000, "  ​﻿",
]
for i, text in enumerate(texts, start=1):
    role, author = ("appUser", "acc-ts-w1") if i % 2 else ("appMaker", "ms-ml-genai-agent-bs")
    assert "$tt$" not in text
    print(f"INSERT INTO camel_history.conversation_messages (conversation_id, sequence, role, author_id, text, event_name, id_yape_account, flow, occurred_at) "
          f"VALUES ('ts-w1', {i}, '{role}', '{author}', $tt${text}$tt$, 'fixture', 'acc-ts-w1', 'p2p', timestamptz '2026-11-18 12:00:00+00' + interval '{i} seconds') ON CONFLICT DO NOTHING;")
SQLGEN
  python3 -I -c '
for n in range(1, 11):
    print("ts-w1\t%d\t%s\tplaceholder%s" % (n, "UserMessageSent" if n % 2 else "AgentMessageSent", "" if n % 2 else "\tagent"))' | publish
  wait_until "ts-w1: 10 messages synced" 120 '[ "$(log_count "Message synced conversation=ts-w1 ")" -ge 10 ]'
  local fidw n db_sha f_sha; fidw="$(fid ts-w1)"
  for n in 1 2 3 4 5 6 7 8 9 10; do
    db_sha="$(sql "SELECT encode(sha256(convert_to(text, 'UTF8')), 'hex') FROM camel_history.conversation_messages WHERE conversation_id='ts-w1' AND sequence=${n}")"
    fx "/openai/v1/conversations/${fidw}/items?order=asc&limit=1$( [ "${n}" -gt 1 ] && echo "&after=$(sql "SELECT foundry_item_id FROM camel_history.foundry_item_map WHERE conversation_id='ts-w1' AND sequence=$((n - 1))")" )"
    f_sha="$(echo "${BODY}" | jq -j '.data[0].content | if type=="array" then .[0].text else . end' | sha)"
    check "text #${n} is identical in Foundry and Postgres" "${db_sha}" "${f_sha}"
  done

  check "nothing was dead-lettered in this section" 0 "$(dlq_new)"
  sleep 2
  check "every offset is committed (no lag)" 0 "$(group_lag)"
}

section_broker() {
  echo "== broker: with the token broker down the sync waits, and goes on when it is back"
  if [ "${FOUNDRY_MODE}" != fake ]; then echo "   (skipped with FOUNDRY_MODE=real)"; return 0; fi
  store_message ts-b1 1 appUser "con el broker caido"
  docker stop foundry-token >/dev/null
  # a fresh start: the new container has no cached token and must ask the broker
  "${REPO_DIR}/scripts/devmode-local.sh" "${PROJECT}" "APP_TOPIC=${TOPIC}" "APP_KAFKA_GROUPID=${GROUP}-b" "APP_FOUNDRY_ENDPOINT=${FAKE_ENDPOINT}" \
    "APP_SYNC_PROJECTIONWAITSECONDS=6" "APP_FOUNDRY_TIMEOUTMS=2000" >/dev/null
  for _ in $(seq 1 90); do [ "$(log_count 'Successfully joined group')" -gt 0 ] && break; sleep 2; done
  printf '%s\n' $'ts-b1\t1\tUserMessageSent\tcon el broker caido' | publish
  wait_until "the broker failure retried" 60 '[ "$(retries_for "the token broker did not answer")" -ge 2 ]'
  check "nothing is sent while there is no token" 0 "$(synced ts-b1 1)"
  compose up -d foundry-token >/dev/null 2>&1
  wait_until "the message synced once the broker is back" 90 '[ "$(synced ts-b1 1)" -ge 1 ]'
  fx "/openai/v1/conversations/$(fid ts-b1)/items?order=asc&limit=100"
  check "it is in Foundry exactly once" "con el broker caido" "$(texts)"
  # The restarted project has a group of its own, so it reads the whole topic again, and dead-letters the poison record of the
  # receive section once more. What matters is that nothing was dead-lettered for this section's message.
  check "this message was not dead-lettered" 0 "$(log_text | grep -c 'DLQ reason=.*ts-b1' || true)"
  "${KAFKA[@]}" kafka-consumer-groups --bootstrap-server kafka:29092 --delete --group "${GROUP}-b" >/dev/null 2>&1 || true
}

ALL_SECTIONS="base receive first order wait reconcile rebuild edge errors broker crash real401"
WANTED="${*:-${ALL_SECTIONS}}"
case " ${WANTED} " in *" base "*) section_base ;; esac
if [ "${WANTED}" != "base" ]; then
  start_project
  for s in ${WANTED}; do [ "${s}" = base ] || "section_${s}"; done
fi
summary
