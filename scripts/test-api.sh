#!/usr/bin/env bash
# Test of the conv-history-api project against the local cluster.
#
#   ./scripts/test-api.sh               run every section
#   ./scripts/test-api.sh skeleton      run only the named sections (see the list at the end of the file)
#
# Starts the project with scripts/devmode-local.sh (the image Karavan's Run uses) and calls it from inside its own
# container, so nothing depends on a published port. Foundry is the fake (scripts/fake-foundry.sh) unless a section
# says it needs the real one. Every section deletes what it creates.
# Needs: the cluster up, the broker (docker compose up -d foundry-token), curl, jq.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"

PROJECT="conv-history-api"
CONTAINER="devmode-local-${PROJECT}"
FAKE_ENDPOINT="http://fake-foundry:8098/api/projects/fake"
HEADERS=""
LAST_METHOD=""; LAST_PATH=""
# Every recorded response goes through the contract check at the end. Inside the repo (git-ignored), because the
# system temp folder is not shared with the Docker VM that runs the checker.
RECORD_DIR="${REPO_DIR}/.devmode-local/records-$$"; mkdir -p "${RECORD_DIR}"

cleanup() {
  sql "DELETE FROM camel_history.foundry_conversation_map WHERE conversation_id LIKE 'ta-%';
       DELETE FROM camel_history.conversation_summaries WHERE conversation_id LIKE 'ta-%';
       DELETE FROM camel_history.conversation_messages WHERE conversation_id LIKE 'ta-%'" >/dev/null 2>&1 || true
  rm -rf "${RECORD_DIR}"
  foundry_cleanup
  "${REPO_DIR}/scripts/devmode-local.sh" stop "${PROJECT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_docker
require_cluster_network
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }

call() { # METHOD PATH -> STATUS BODY HEADERS, from inside the project container
  LAST_METHOD="$1"; LAST_PATH="$2"
  STATUS="$(docker exec "${CONTAINER}" sh -c 'curl -s -g -m 30 -X "$0" -o /tmp/b -D /tmp/h -w "%{http_code}" "$1"' "$1" "http://localhost:8080$2")" || STATUS="000"
  BODY="$(docker exec "${CONTAINER}" cat /tmp/b 2>/dev/null)"
  HEADERS="$(docker exec "${CONTAINER}" cat /tmp/h 2>/dev/null | tr -d '\r')"
}
record() { # NAME: keep the last response for the contract check
  jq -n --arg m "${LAST_METHOD}" --arg p "${LAST_PATH}" --argjson s "${STATUS}" --arg h "${HEADERS}" --arg b "${BODY}" \
    '{method:$m, path:$p, status:$s, headers_raw:$h, body_raw:$b}' > "${RECORD_DIR}/$1.json"
}
problem() { # description, status, type suffix, detail, path   (also records it)
  call GET "$5"
  check "$1: status" "$2" "${STATUS}"
  check "$1: type" "$3" "$(echo "${BODY}" | jq -r .type | sed 's/^tag:yape.com.pe,2026:conversation-history://')"
  [ -z "$4" ] || check "$1: detail" "$4" "$(echo "${BODY}" | jq -r .detail)"
  record "$(echo "$1" | tr -c 'A-Za-z0-9' '_' | cut -c1-60)"
}
header() { echo "${HEADERS}" | grep -i "^$1:" | head -1 | cut -d: -f2- | sed 's/^ *//'; }
log_text() { docker logs "${CONTAINER}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

start_project() { # extra NAME=value pairs for the container
  "${REPO_DIR}/scripts/fake-foundry.sh" start >/dev/null
  curl -s -o /dev/null -X POST http://localhost:8098/__reset
  compose up -d foundry-token >/dev/null
  "${REPO_DIR}/scripts/devmode-local.sh" "${PROJECT}" "APP_FOUNDRY_ENDPOINT=${FAKE_ENDPOINT}" "$@" >/dev/null
  for _ in $(seq 1 90); do
    log_text | grep -qE 'Apache Camel .* started in|Error starting Camel' && break
    sleep 2
  done
  log_text | grep -q 'Apache Camel .* started in' || { echo "❌  ${PROJECT} did not start:" >&2; log_text | grep -E 'ERROR|Error' | tail -5 >&2; exit 1; }
}

section_skeleton() {
  echo "== skeleton: health, 404 and 405"
  check_contains "Camel started" "started in" "$(log_text | grep 'Apache Camel .* started in')"
  # Karavan's REST designer only renders a rest verb whose `to` is a plain string, which Camel calls compact notation;
  # everything else must stay canonical. So a warning is fine for an endpoint-*.camel.yaml file and for nothing else.
  check "no compact-notation warning outside the endpoint files" 0 "$(log_text | grep 'compact notation' | grep -vc 'endpoint-' || true)"
  call GET /health
  check "GET /health is 200" 200 "${STATUS}"
  check "GET /health is JSON" "application/json" "$(header content-type | cut -d';' -f1)"
  check "GET /health says ok" ok "$(echo "${BODY}" | jq -r .status)"
  record health_ok
  call GET /nothing/here
  check "an unknown path is 404" 404 "${STATUS}"
  check "the 404 is problem+json" "application/problem+json" "$(header content-type | cut -d';' -f1)"
  check "the 404 body repeats its status" 404 "$(echo "${BODY}" | jq -r .status)"
  check "the 404 uses about:blank" "about:blank" "$(echo "${BODY}" | jq -r .type)"
  check "the 404 title is the status phrase" "Not Found" "$(echo "${BODY}" | jq -r .title)"
  call POST /health
  check "a wrong method is 405" 405 "${STATUS}"
  check "the 405 is problem+json" "application/problem+json" "$(header content-type | cut -d';' -f1)"
  check "the 405 title is the status phrase" "Method Not Allowed" "$(echo "${BODY}" | jq -r .title)"
  check "the management health the DevMode check uses is UP" UP "$(docker exec "${CONTAINER}" curl -s -m 10 http://localhost:9876/q/observe/health | jq -r .status)"
}


section_validation() {
  echo "== validation: every rule of the contract, with its exact answer"
  local A="/v1/conversations?idYapeAccount=acc-1" M="/v1/conversations/conv-1/messages"
  local long; long="$(head -c 129 /dev/zero | tr '\0' a)"
  echo "   -- the conversation list"
  problem "list: no account" 400 invalid-request "idYapeAccount is missing or malformed" "/v1/conversations"
  problem "list: empty account" 400 invalid-request "idYapeAccount is missing or malformed" "/v1/conversations?idYapeAccount="
  problem "list: account with a space" 400 invalid-request "idYapeAccount is missing or malformed" "/v1/conversations?idYapeAccount=a%20b"
  problem "list: account too long" 400 invalid-request "idYapeAccount is missing or malformed" "/v1/conversations?idYapeAccount=${long}"
  problem "list: account twice" 400 invalid-request "idYapeAccount is given more than once" "/v1/conversations?idYapeAccount=a&idYapeAccount=b"
  problem "list: size twice" 400 invalid-request "page[size] is given more than once" "${A}&page[size]=1&page[size]=2"
  problem "list: before twice" 400 invalid-request "page[before] is given more than once" "${A}&page[before]=1~a&page[before]=2~b"
  for s in 0 101 abc 05 +5 1.5 -1 ""; do
    problem "list: size [${s}]" 400 invalid-request "page[size] must be a whole number from 1 to 100" "${A}&page[size]=${s}"
  done
  problem "list: both cursors" 400 invalid-request "page[before] and page[after] cannot be used together" "${A}&page[before]=1792771602218000~c&page[after]=1792771602218000~c"
  for c in "" abc 1792771602218000 "05~c" "+5~c" "0~c" "1792771602218000~" "1792771602218000~bad%20id" "253402300800000000~c" "1792771602218000.5~c"; do
    problem "list: before [${c}]" 400 invalid-cursor "page[before] or page[after] is not a cursor from the conversation list." "${A}&page[before]=${c}"
  done
  problem "list: after [abc]" 400 invalid-cursor "page[before] or page[after] is not a cursor from the conversation list." "${A}&page[after]=abc"
  echo "   -- the messages"
  problem "messages: id with a space" 400 invalid-request "the conversation id is malformed" "/v1/conversations/bad%20id/messages"
  problem "messages: id too long" 400 invalid-request "the conversation id is malformed" "/v1/conversations/${long}/messages"
  problem "messages: size twice" 400 invalid-request "page[size] is given more than once" "${M}?page[size]=1&page[size]=2"
  for s in 0 101 abc 05 +5 ""; do
    problem "messages: size [${s}]" 400 invalid-request "page[size] must be a whole number from 1 to 100" "${M}?page[size]=${s}"
  done
  problem "messages: both cursors" 400 invalid-request "page[before] and page[after] cannot be used together" "${M}?page[before]=1&page[after]=2"
  for c in "" abc 0 05 +5 -3 1.5 99999999999; do
    problem "messages: before [${c}]" 400 invalid-cursor "page[before] or page[after] is not the _id of a message in this conversation." "${M}?page[before]=${c}"
  done
  problem "messages: after [abc]" 400 invalid-cursor "page[before] or page[after] is not the _id of a message in this conversation." "${M}?page[after]=abc"
  echo "   -- what is valid must get through, brackets included, percent-encoded or not"
  call GET "${A}&page[size]=5";                                   check "list: a valid page[size]" 200 "${STATUS}"
  call GET "/v1/conversations?idYapeAccount=acc-1&page%5Bsize%5D=5"; check "list: page%5Bsize%5D, percent-encoded" 200 "${STATUS}"
  call GET "${A}&page[before]=1792771602218000~conv_v1_abc";      check "list: a well-formed cursor" 200 "${STATUS}"
  call GET "${M}?page[before]=7&page[size]=3";                    check "messages: a well-formed cursor and size" 200 "${STATUS}"
  call GET "${M}?unknown=1&page[size]=3";                         check "messages: an unknown parameter is ignored" 200 "${STATUS}"
  check "no 500 anywhere (the page[...] header trap)" 0 "$(log_text | grep -c 'answering 500' || true)"
}

seed_conversation() { # account conversation last first count [unmapped]   (fixtures: a summary, and the Foundry map unless "unmapped")
  sql "INSERT INTO camel_history.conversation_summaries (id_yape_account, conversation_id, message_count, first_occurred_at, last_occurred_at)
       VALUES ('$1', '$2', $5, timestamptz '$4', timestamptz '$3')" >/dev/null
  [ "${6:-}" = unmapped ] || sql "INSERT INTO camel_history.foundry_conversation_map (conversation_id, foundry_conversation_id, last_synced_sequence)
       VALUES ('$2', 'conv_fixture_$2', 1)" >/dev/null
}
micros_of() { sql "SELECT (extract(epoch FROM last_occurred_at) * 1000000)::bigint FROM camel_history.conversation_summaries WHERE conversation_id='$1'"; }
ids() { echo "${BODY}" | jq -r '[.conversations[]._id] | join(",")'; }
link_target() { echo "${HEADERS}" | grep -i '^link:' | sed -n 's/^[Ll]ink: <\(.*\)>; rel=.*/\1/p'; }
link_rel() { echo "${HEADERS}" | grep -i '^link:' | sed -n 's/.*rel="\([a-z]*\)".*/\1/p'; }

walk() { # PATH [label]: follow the Link header to the end; one line per page with its ids; every page is recorded
  local path="$1" n=0
  while [ -n "${path}" ] && [ "${n}" -lt 20 ]; do
    n=$((n + 1)); call GET "${path}"; record "walk_${2:-x}_${n}"
    echo "${STATUS} $(ids) [$(link_rel)]"
    path="$(link_target)"
  done
}

section_list() {
  echo "== list: the conversations of an account, most recent first, with cursors and Link"
  local A="/v1/conversations?idYapeAccount=acc-ta1"
  seed_conversation acc-ta1 ta-c1 "2026-11-18 10:00:00+00"        "2026-11-18 09:50:00+00" 3
  seed_conversation acc-ta1 ta-c2 "2026-11-18 10:05:00.123456+00" "2026-11-18 10:01:00+00" 5
  seed_conversation acc-ta1 ta-c3 "2026-11-18 10:10:00+00"        "2026-11-18 10:06:00+00" 2
  seed_conversation acc-ta1 ta-c4 "2026-11-18 10:10:00+00"        "2026-11-18 10:08:00+00" 4
  seed_conversation acc-ta1 ta-c5 "2026-11-18 10:20:00+00"        "2026-11-18 10:12:00+00" 7
  seed_conversation acc-ta1 ta-c6 "2026-11-18 10:30:00+00"        "2026-11-18 10:25:00+00" 1 unmapped
  seed_conversation acc-ta2 ta-d1 "2026-11-18 10:15:00+00"        "2026-11-18 10:14:00+00" 9

  echo "   -- the most recent page"
  call GET "${A}"; record list_newest
  check "200" 200 "${STATUS}"
  check "most recent first; the tie on the instant is broken by id, descending" "ta-c5,ta-c4,ta-c3,ta-c2,ta-c1" "$(ids)"
  check "a conversation that is not in Foundry is not listed" 0 "$(echo "${BODY}" | jq '[.conversations[] | select(._id=="ta-c6")] | length')"
  check "no Link when there is nothing more" "" "$(header link)"
  check "the message counts" "7,4,2,5,3" "$(echo "${BODY}" | jq -r '[.conversations[].messageCount] | join(",")')"
  check "a count is an integer" true "$(echo "${BODY}" | jq '[.conversations[].messageCount | (. == floor)] | all')"
  check "the cursor is the last instant in microseconds, a ~ and the id" "$(micros_of ta-c2)~ta-c2" "$(echo "${BODY}" | jq -r '.conversations[3].cursor')"
  check "lastReceived is Unix seconds with milliseconds" "$(sql "SELECT trim(trailing '.' FROM trim(trailing '0' FROM round(extract(epoch FROM last_occurred_at)::numeric, 3)::text)) FROM camel_history.conversation_summaries WHERE conversation_id='ta-c2'")" "$(echo "${BODY}" | jq -r '.conversations[3].lastReceived | tostring')"
  check "firstReceived too" "$(sql "SELECT trim(trailing '.' FROM trim(trailing '0' FROM round(extract(epoch FROM first_occurred_at)::numeric, 3)::text)) FROM camel_history.conversation_summaries WHERE conversation_id='ta-c1'")" "$(echo "${BODY}" | jq -r '.conversations[4].firstReceived | tostring')"
  check "no working header leaks into the response" 0 "$(echo "${HEADERS}" | grep -ciE '^(account|limit|direction|size|cursor[a-z]*|storedrole):' || true)"

  echo "   -- paging back with size 2, following the Link header"
  call GET "${A}&page[size]=2"; record list_size2
  check "the first page" "ta-c5,ta-c4" "$(ids)"
  check "its Link says prev and keeps the size" "/v1/conversations?idYapeAccount=acc-ta1&page[before]=$(micros_of ta-c4)~ta-c4&page[size]=2" "$(link_target)"
  check "rel is prev" prev "$(link_rel)"
  check "walking back gives every conversation once, in pages of 2, 2, 1" $'200 ta-c5,ta-c4 [prev]\n200 ta-c3,ta-c2 [prev]\n200 ta-c1 []' "$(walk "${A}&page[size]=2" back)"

  echo "   -- paging forward from the oldest"
  local c1="$(micros_of ta-c1)~ta-c1"
  call GET "${A}&page[after]=${c1}&page[size]=2"; record list_after
  check "the nearest more recent two, most recent first" "ta-c3,ta-c2" "$(ids)"
  check "rel is next" next "$(link_rel)"
  check "its Link continues from the most recent of the page" "/v1/conversations?idYapeAccount=acc-ta1&page[after]=$(micros_of ta-c3)~ta-c3&page[size]=2" "$(link_target)"
  check "walking forward reaches the newest and stops" $'200 ta-c3,ta-c2 [next]\n200 ta-c5,ta-c4 []' "$(walk "${A}&page[after]=${c1}&page[size]=2" fwd)"

  echo "   -- past the last"
  call GET "${A}&page[before]=${c1}"; record list_past_last
  check "200 with an empty array" "200 " "${STATUS} $(ids)"
  check "and no Link" "" "$(header link)"
  call GET "${A}&page[after]=$(micros_of ta-c5)~ta-c5"
  check "after the newest is empty too" "200 " "${STATUS} $(ids)"

  echo "   -- a cursor is a position: it stays right when a conversation receives a message"
  local c4="$(micros_of ta-c4)~ta-c4"
  sql "UPDATE camel_history.conversation_summaries SET last_occurred_at = timestamptz '2026-11-18 11:00:00+00', message_count = message_count + 1 WHERE conversation_id='ta-c1'" >/dev/null
  call GET "${A}&page[before]=${c4}"; record list_stable
  check "the page below the old cursor does not change" "ta-c3,ta-c2" "$(ids)"
  call GET "${A}"
  check "and the conversation that moved is now first" "ta-c1,ta-c5,ta-c4,ta-c3,ta-c2" "$(ids)"
  check "with its new count" 4 "$(echo "${BODY}" | jq '.conversations[0].messageCount')"

  echo "   -- accounts do not mix"
  call GET "/v1/conversations?idYapeAccount=acc-ta2"; record list_other_account
  check "the other account sees only its own" ta-d1 "$(ids)"
  call GET "/v1/conversations?idYapeAccount=acc-nobody"; record list_empty
  check "an account with none gets 200 and an empty array" "200 " "${STATUS} $(ids)"
  check "no 500 in the log" 0 "$(log_text | grep -c 'answering 500' || true)"
}

section_checker() {
  echo "== checker: the contract check accepts a good response and rejects broken ones"
  local ref="${REPO_DIR}/../ms-ml-conv-history-bs/docs/ms-ml-conv-history-bs-openapi.yml"
  if [ -f "${ref}" ]; then
    check "the copied contract is identical to the reference service's" "$(shasum "${ref}" | cut -c1-40)" "$(shasum "${REPO_DIR}/docs/contract/ms-ml-conv-history-bs-openapi.yml" | cut -c1-40)"
  else
    echo "   (the reference service's repo is not next to this one: the copy was not compared)"
  fi
  local d="${REPO_DIR}/.devmode-local/checker-$$"; mkdir -p "${d}"
  local good='{"conversation":{"_id":"c1"},"messages":[{"_id":"1","type":"text","role":"appUser","authorId":"a","text":"t","received":1.5,"source":{"type":"api"},"metadata":{"sequence":1,"eventName":"UserMessageSent","truncated":false}}]}'
  mk() { jq -n --arg p "$2" --argjson s "$3" --arg h "$4" --arg b "$5" '{method:"GET", path:$p, status:$s, headers_raw:$h, body_raw:$b}' > "${d}/$1.json"; }
  local json=$'HTTP/1.1 200 OK\nContent-Type: application/json\n' pj=$'HTTP/1.1 400 Bad Request\nContent-Type: application/problem+json\n'
  mk good /v1/conversations/c1/messages 200 "${json}" "${good}"
  mk extra_field /v1/conversations/c1/messages 200 "${json}" "$(echo "${good}" | jq -c '.messages[0].extra=1')"
  mk missing_text /v1/conversations/c1/messages 200 "${json}" "$(echo "${good}" | jq -c 'del(.messages[0].text)')"
  mk bad_role /v1/conversations/c1/messages 200 "${json}" "$(echo "${good}" | jq -c '.messages[0].role="bot"')"
  mk id_not_string /v1/conversations/c1/messages 200 "${json}" "$(echo "${good}" | jq -c '.messages[0]._id=1')"
  mk wrong_content_type /v1/conversations/c1/messages 200 $'HTTP/1.1 200 OK\nContent-Type: text/plain\n' "${good}"
  mk no_flow_is_fine /v1/conversations/c1/messages 200 "${json}" "$(echo "${good}" | jq -c '.messages[0].metadata.flow="p2p"')"
  mk problem_wrong_status /v1/conversations/c1/messages 400 "${pj}" '{"type":"tag:yape.com.pe,2026:conversation-history:invalid-request","title":"Invalid request","status":500,"detail":"x"}'
  mk problem_wrong_type /v1/conversations/c1/messages 400 "${pj}" '{"type":"about:blank","title":"Bad Request","status":400,"detail":"x"}'
  mk link_on_error /v1/conversations/c1/messages 400 $'HTTP/1.1 400 Bad Request\nContent-Type: application/problem+json\nLink: </v1/conversations/c1/messages?page[before]=1>; rel="prev"\n' '{"type":"tag:yape.com.pe,2026:conversation-history:invalid-request","title":"Invalid request","status":400,"detail":"x"}'
  mk link_malformed /v1/conversations/c1/messages 200 $'HTTP/1.1 200 OK\nContent-Type: application/json\nLink: /v1/conversations/c1/messages?page[before]=1\n' "${good}"
  mk not_a_contract_path /v1/other 200 "${json}" '{}'
  local out; out="$("${REPO_DIR}/scripts/contract-check.sh" "${d}" 2>&1)" || true
  for ok in good no_flow_is_fine; do check_contains "accepted: ${ok}" "ok    ${ok}:" "${out}"; done
  for bad in extra_field missing_text bad_role id_not_string wrong_content_type problem_wrong_status problem_wrong_type link_on_error link_malformed not_a_contract_path; do
    check_contains "rejected: ${bad}" "FAIL  ${bad}:" "${out}"
  done
  rm -rf "${d}"
}

section_contract() {
  echo "== contract: every recorded response against the reference OpenAPI"
  local out rc=0; out="$("${REPO_DIR}/scripts/contract-check.sh" "${RECORD_DIR}" 2>&1)" || rc=$?
  echo "${out}" | grep -E "FAIL|^ {10}|recorded responses|Error|error" | sed 's/^/   /'
  check "every recorded response is on the contract" 0 "${rc}"
}

ALL_SECTIONS="skeleton validation list checker"
WANTED="${*:-${ALL_SECTIONS}}"
start_project
for s in ${WANTED}; do "section_${s}"; done
if [ "$(find "${RECORD_DIR}" -name '*.json' | wc -l | tr -d ' ')" -gt 0 ]; then section_contract; fi
summary
