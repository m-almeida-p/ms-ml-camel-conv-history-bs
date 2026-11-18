#!/usr/bin/env bash
# Proves the Camel consumer builds the same history as the original consumer (ms-ml-conv-history-bs).
#
#   ./scripts/parity-check.sh
#
# It replays every row of public.conversation_events (the agent's event store, which Debezium publishes) as a
# Debezium-formatted record (Schema Registry header with the cluster's schema id + JSON, the JSONB columns as
# strings) onto a THROWAWAY topic, runs the Camel consumer on it, and then compares the three tables it wrote
# (camel_history.*) with the three the original consumer wrote (public.conversation_inbox, _messages and
# _summaries): every column of every row, in both directions. It also checks that nothing was dead-lettered.
#
# It TRUNCATES the camel_history tables before and after. The public tables are only read.
# Needs: the cluster up, the camel_history migrations applied, python3.

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT="conv-history-consumer"
RUN="$(date +%s)"
TOPIC="camel.parity.${RUN}"
GROUP="camel-parity-${RUN}"
CONTAINER="devmode-local-${PROJECT}"
SCHEMA_ID="${SCHEMA_ID:-2}"
PSQL=(docker exec -i yape-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA)
KAFKA=(docker exec -i yape-kafka)
FAILS=0

require_docker
require_cluster_network
command -v python3 >/dev/null || { echo "❌  python3 is required" >&2; exit 1; }

sql() { "${PSQL[@]}" -c "$1"; }
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$2] got [$3]"; fi; }
log_has() { local out; out="$(docker logs "${CONTAINER}" 2>&1 || true)"; grep -qE "$1" <<< "${out}"; }

cleanup() {
  "${REPO_DIR}/scripts/devmode-local.sh" stop "${PROJECT}" >/dev/null 2>&1 || true
  sql "TRUNCATE camel_history.conversation_summaries, camel_history.conversation_messages, camel_history.conversation_inbox" >/dev/null 2>&1 || true
  "${KAFKA[@]}" kafka-topics --bootstrap-server kafka:29092 --delete --topic "${TOPIC}" >/dev/null 2>&1 || true
  "${KAFKA[@]}" kafka-consumer-groups --bootstrap-server kafka:29092 --delete --group "${GROUP}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

EVENTS="$(sql "SELECT count(*) FROM public.conversation_events")"
echo "🧪  replaying ${EVENTS} events of public.conversation_events (schema id ${SCHEMA_ID}) on topic ${TOPIC}"
sql "TRUNCATE camel_history.conversation_summaries, camel_history.conversation_messages, camel_history.conversation_inbox" >/dev/null
"${KAFKA[@]}" kafka-topics --bootstrap-server kafka:29092 --create --topic "${TOPIC}" --partitions 3 --replication-factor 1 >/dev/null 2>&1

"${REPO_DIR}/scripts/devmode-local.sh" "${PROJECT}" "APP_TOPIC=${TOPIC}" "APP_KAFKA_GROUPID=${GROUP}" >/dev/null
for _ in $(seq 1 90); do
  log_has 'Successfully joined group' && break
  if log_has 'Error starting Camel|FailedToCreateRoute|Compilation error'; then docker logs "${CONTAINER}" 2>&1 | tail -30; echo "❌  the consumer did not start" >&2; exit 1; fi
  sleep 2
done
log_has 'Successfully joined group' || { echo "❌  the consumer did not join the group" >&2; exit 1; }

# Debezium's record: key {"conversation_id": ...}, value the flat row, payload and metadata as JSON strings,
# occurred_at as an ISO-8601 UTC time with microseconds; both framed with the Schema Registry header.
sql "SELECT json_build_object(
        'conversation_id', conversation_id, 'sequence', sequence, 'event_name', event_name, 'event_version', event_version,
        'payload', payload::text, 'metadata', metadata::text, 'correlation_id', correlation_id,
        'id_yape_account', id_yape_account, 'actor', actor, 'flow', flow,
        'occurred_at', to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'))::text
     FROM public.conversation_events ORDER BY conversation_id, sequence" \
| SCHEMA_ID="${SCHEMA_ID}" python3 -I -c '
import json, os, sys
sid = int(os.environ["SCHEMA_ID"])
frame = lambda i, b: b"\x00" + i.to_bytes(4, "big") + b
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    cid = json.loads(line)["conversation_id"]
    key = frame(sid - 1, json.dumps({"conversation_id": cid}).encode())
    sys.stdout.buffer.write(key + b"\t" + frame(sid, line.encode()) + b"\n")
' | "${KAFKA[@]}" kafka-console-producer --bootstrap-server kafka:29092 --topic "${TOPIC}" \
      --property parse.key=true --property "key.separator=$(printf '\t')" >/dev/null 2>&1

echo "⏳  waiting for the consumer"
handled() { local out; out="$(docker logs "${CONTAINER}" 2>&1 || true)"; grep -cE 'Event (stored|duplicate) conversation=|DLQ reason=|Tombstone skipped' <<< "${out}" || true; }
for _ in $(seq 1 90); do
  [ "$(handled)" -ge "${EVENTS}" ] && break
  if log_has 'Failed delivery'; then echo "❌  an unexpected error:" >&2; docker logs "${CONTAINER}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep 'Failed delivery' | head -1 | cut -c1-400 >&2; exit 1; fi
  sleep 2
done
echo "    handled $(handled) of ${EVENTS}"
sleep 3

echo "🔎  comparing camel_history with the original consumer's public tables (every column, both directions)"
INBOX="conversation_id, sequence, event_name, event_version, payload, metadata, correlation_id, id_yape_account, actor, flow, occurred_at"
MESSAGES="conversation_id, sequence, role, author_id, type, text, truncated, event_name, id_yape_account, flow, occurred_at"
SUMMARIES="id_yape_account, conversation_id, message_count, first_occurred_at, last_occurred_at"
for pair in "conversation_inbox:${INBOX}" "conversation_messages:${MESSAGES}" "conversation_summaries:${SUMMARIES}"; do
  table="${pair%%:*}"; cols="${pair#*:}"
  original="$(sql "SELECT count(*) FROM public.${table}")"
  mine="$(sql "SELECT count(*) FROM camel_history.${table}")"
  check "${table}: same number of rows (original ${original})" "${original}" "${mine}"
  only_original="$(sql "SELECT count(*) FROM (SELECT ${cols} FROM public.${table} EXCEPT SELECT ${cols} FROM camel_history.${table}) d")"
  only_mine="$(sql "SELECT count(*) FROM (SELECT ${cols} FROM camel_history.${table} EXCEPT SELECT ${cols} FROM public.${table}) d")"
  check "${table}: rows only in the original" "0" "${only_original}"
  check "${table}: rows only in camel_history" "0" "${only_mine}"
done
dlq="$(docker logs "${CONTAINER}" 2>&1 | grep -c 'DLQ reason=' || true)"
check "no real record was dead-lettered" "0" "${dlq}"

echo
if [ "${FAILS}" -eq 0 ]; then echo "✅  parity: the Camel consumer built the same history"; else echo "❌  ${FAILS} difference(s)"; exit 1; fi
