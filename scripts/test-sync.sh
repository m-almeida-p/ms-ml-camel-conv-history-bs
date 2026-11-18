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

wait_until() { # description, timeout in seconds, command...
  local what="$1" limit="$2"; shift 2
  for _ in $(seq 1 "${limit}"); do "$@" && return 0; sleep 1; done
  fail "timed out waiting for: ${what}"
  echo "    last relevant log lines:" >&2
  log_text | grep -E ' (ERROR|WARN) |Chat message|Not a chat|DLQ|Tombstone|Exception' | tail -12 | cut -c1-260 | sed 's/^/      /' >&2
  return 1
}

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
  printf '%s\n' \
    $'ts-r1\t1\tUserMessageSent\thola' \
    $'ts-r1\t2\tAgentMessageSent\thola, en que te ayudo\tagent' \
    $'ts-r1\t3\tGuardrailResponseSent\tno puedo ayudarte con eso\tagent' \
    $'ts-r1\t4\tToolCallSummary\tlookup\tagent' \
    $'ts-r1\t5\tToolActionSummarized\tpay\tagent' \
    $'RAW\tts-r1\tnot json at all' \
    $'TOMBSTONE\tts-r1' | publish
  wait_until "the 7 records handled" 90 test "$(( $(log_count 'Chat message conversation=') + $(log_count 'Not a chat message') + $(log_count 'DLQ reason=') + $(log_count 'Tombstone skipped') ))" -ge 7
  sleep 3
  check "3 chat messages reach route 2" 3 "$(log_count 'Chat message conversation=ts-r1 sequence=[123]$')"
  check "2 other events are skipped" 2 "$(log_count 'Not a chat message, skipped event=Tool')"
  check "1 poison record in the dead-letter log" 1 "$(log_count 'DLQ reason=')"
  check_contains "the dead-letter line carries the body" "not json at all" "$(log_text | grep 'DLQ reason=' | head -1)"
  check "1 tombstone skipped" 1 "$(log_count 'Tombstone skipped')"
  check "every offset is committed (no lag)" 0 "$(group_lag)"
}

ALL_SECTIONS="base receive"
WANTED="${*:-${ALL_SECTIONS}}"
case " ${WANTED} " in *" base "*) section_base ;; esac
if [ "${WANTED}" != "base" ]; then
  start_project
  for s in ${WANTED}; do [ "${s}" = base ] || "section_${s}"; done
fi
summary
