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

FOUNDRY_MODE="${FOUNDRY_MODE:-fake}"   # fake: the fake Foundry (default) | real: the Foundry project of .env
STARTED=0

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
  "${REPO_DIR}/scripts/devmode-local.sh" "${PROJECT}" "APP_TOPIC=${TOPIC}" "APP_KAFKA_GROUPID=${GROUP}" "APP_FOUNDRY_ENDPOINT=${endpoint}" \
    "APP_SYNC_PROJECTIONWAITSECONDS=${PROJECTION_WAIT:-6}" >/dev/null
  for _ in $(seq 1 120); do
    [ "$(log_count 'Successfully joined group')" -gt 0 ] && return 0
    if [ "$(log_count 'Error starting Camel|FailedToCreateRoute|Compilation error')" -gt 0 ]; then
      log_text | grep -E 'ERROR|error:|Caused by' | head -8 >&2; echo "❌  ${PROJECT} did not start" >&2; exit 1
    fi
    sleep 2
  done
  echo "❌  ${PROJECT} did not join the group" >&2; exit 1
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

fx() { # GET path of the Foundry API under test (the fake or the real one); sets STATUS and BODY
  if [ "${FOUNDRY_MODE}" = fake ]; then
    BODY="$(curl -s -m 20 "http://localhost:8098/api/projects/fake$1" -H 'Authorization: Bearer test')"; STATUS=200
  else
    foundry GET "$1"
  fi
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

fake_fail() { curl -s -o /dev/null -X POST http://localhost:8098/__fail -H 'Content-Type: application/json' --data "$1"; }

section_reconcile() {
  echo "== reconcile: an item Foundry kept but we never recorded is adopted, not sent twice"
  if [ "${FOUNDRY_MODE}" != fake ]; then echo "   (needs the fake Foundry's 'drop' fault: skipped with FOUNDRY_MODE=real)"; return 0; fi
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

ALL_SECTIONS="base receive first order wait reconcile"
WANTED="${*:-${ALL_SECTIONS}}"
case " ${WANTED} " in *" base "*) section_base ;; esac
if [ "${WANTED}" != "base" ]; then
  start_project
  for s in ${WANTED}; do [ "${s}" = base ] || "section_${s}"; done
fi
summary
