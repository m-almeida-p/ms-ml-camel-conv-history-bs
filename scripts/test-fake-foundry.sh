#!/usr/bin/env bash
# Checks that the fake Foundry (scripts/fake-foundry/server.py) behaves like the real one, and that its faults work.
#
#   ./scripts/test-fake-foundry.sh
#
# Part 1 runs ONE block of calls against the real Foundry project and against the fake and compares what each
# observed, line by line (ids and times are left out). A difference means the fake has drifted from the real service.
# Part 2 checks the faults only the fake has: 429, 500, 400, 401, slow, and "applied but not answered".
# The real part creates fake conversations and deletes them when it ends. Needs: az-free (it uses the service
# principal in .env), the cluster network, curl, jq.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"

FAKE="http://localhost:8098/api/projects/fake"
CREATED_REAL=()
HEADERS=""

trap 'foundry_cleanup' EXIT
require_docker
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }
"${REPO_DIR}/scripts/fake-foundry.sh" start >/dev/null
curl -s -o /dev/null -X POST http://localhost:8098/__reset

req() { # base token method path [json] -> STATUS BODY HEADERS
  local base="$1" token="$2" method="$3" path="$4" data="${5:-}" out hdr auth=()
  out="$(mktemp)"; hdr="$(mktemp)"
  [ -n "${token}" ] && auth=(-H "Authorization: Bearer ${token}")
  if [ -n "${data}" ]; then
    STATUS="$(curl -s -m 60 -o "${out}" -D "${hdr}" -w '%{http_code}' -X "${method}" "${base}${path}" ${auth[@]+"${auth[@]}"} -H 'Content-Type: application/json' --data "${data}")" || STATUS="000"
  else
    STATUS="$(curl -s -m 60 -o "${out}" -D "${hdr}" -w '%{http_code}' -X "${method}" "${base}${path}" ${auth[@]+"${auth[@]}"})" || STATUS="000"
  fi
  BODY="$(cat "${out}")"; HEADERS="$(cat "${hdr}")"; rm -f "${out}" "${hdr}"
}
TEXTS='[.data[]? | (.content|if type=="array" then .[0].text else . end)] | join(",")'
msg() { printf '{"type":"message","role":"%s","content":"%s"}' "$1" "$2"; }

observe() { # base token label: prints one "name=value" line per observation
  local base="$1" tok="$2" c b d i first mid last
  req "$base" "$tok" POST /openai/v1/conversations '{"metadata":{"conversation_id":"fidelity","source":"test"},"items":[{"type":"message","role":"user","content":"A1"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"A2"}]}]}'
  c="$(echo "$BODY" | jq -r .id)"; [ "${base}" = "${FAKE}" ] || track_foundry_conversation "$c"
  echo "create.status=$STATUS"; echo "create.id_prefix=${c:0:5}"; echo "create.metadata=$(echo "$BODY" | jq -c .metadata)"
  req "$base" "$tok" GET "/openai/v1/conversations/$c/items?order=asc"
  echo "create.items=$(echo "$BODY" | jq -r "$TEXTS")"; echo "create.roles=$(echo "$BODY" | jq -r '[.data[].role]|join(",")')"
  echo "list.keys=$(echo "$BODY" | jq -c 'keys')"
  req "$base" "$tok" POST "/openai/v1/conversations/$c/items" "{\"items\":[$(msg user B1)]}"
  echo "user.status=$STATUS"; echo "user.id_prefix=$(echo "$BODY" | jq -r '.data[0].id[0:4]')"; echo "user.type=$(echo "$BODY" | jq -r '.data[0].type')"
  echo "user.state=$(echo "$BODY" | jq -r '.data[0].status')"; echo "user.part=$(echo "$BODY" | jq -r '.data[0].content[0].type')"; echo "user.created_at=$(echo "$BODY" | jq -c '.data[0].created_at')"
  req "$base" "$tok" POST "/openai/v1/conversations/$c/items" '{"items":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"B2"}]}]}'
  echo "assistant.part=$(echo "$BODY" | jq -r '.data[0].content[0].type')"
  req "$base" "$tok" POST "/openai/v1/conversations/$c/items" '{"items":[{"type":"message","role":"user","content":"B3","metadata":{"sequence":"9"},"created_at":1767225600}]}'
  echo "item_metadata.status=$STATUS"; echo "item_metadata.value=$(echo "$BODY" | jq -c '.data[0].metadata')"; echo "item_created_at=$(echo "$BODY" | jq -c '.data[0].created_at')"
  # six in one batch, in a known order
  req "$base" "$tok" POST /openai/v1/conversations '{}'; b="$(echo "$BODY" | jq -r .id)"; [ "${base}" = "${FAKE}" ] || track_foundry_conversation "$b"
  req "$base" "$tok" POST "/openai/v1/conversations/$b/items" "{\"items\":[$(for i in 1 2 3 4 5 6; do msg user "C$i"; [ $i -lt 6 ] && printf ,; done)]}"
  echo "batch.create_order=$(echo "$BODY" | jq -r "$TEXTS")"
  req "$base" "$tok" GET "/openai/v1/conversations/$b/items?order=asc&limit=100"; echo "batch.asc=$(echo "$BODY" | jq -r "$TEXTS")"; mid="$(echo "$BODY" | jq -r '.data[2].id')"; first="$(echo "$BODY" | jq -r '.first_id')"
  req "$base" "$tok" GET "/openai/v1/conversations/$b/items?order=desc&limit=100"; echo "batch.desc=$(echo "$BODY" | jq -r "$TEXTS")"
  req "$base" "$tok" GET "/openai/v1/conversations/$b/items?order=desc&limit=2"; echo "desc.p1=$(echo "$BODY" | jq -r "$TEXTS") more=$(echo "$BODY" | jq -r .has_more)"; last="$(echo "$BODY" | jq -r .last_id)"
  req "$base" "$tok" GET "/openai/v1/conversations/$b/items?order=desc&limit=2&after=$last"; echo "desc.p2_after=$(echo "$BODY" | jq -r "$TEXTS") more=$(echo "$BODY" | jq -r .has_more)"
  last="$(echo "$BODY" | jq -r .last_id)"
  req "$base" "$tok" GET "/openai/v1/conversations/$b/items?order=desc&limit=2&after=$last"; echo "desc.p3_after=$(echo "$BODY" | jq -r "$TEXTS") more=$(echo "$BODY" | jq -r .has_more)"
  req "$base" "$tok" GET "/openai/v1/conversations/$b/items?order=asc&limit=2&after=$first"; echo "asc.after_first=$(echo "$BODY" | jq -r "$TEXTS") more=$(echo "$BODY" | jq -r .has_more)"
  req "$base" "$tok" GET "/openai/v1/conversations/$b/items?order=asc&limit=100&before=$mid"; echo "asc.before_third=$(echo "$BODY" | jq -r "$TEXTS")"
  req "$base" "$tok" GET "/openai/v1/conversations/$b/items/$mid"; echo "item.get=$STATUS $(echo "$BODY" | jq -r '.content[0].text')"
  # limits
  req "$base" "$tok" POST /openai/v1/conversations '{}'; d="$(echo "$BODY" | jq -r .id)"; [ "${base}" = "${FAKE}" ] || track_foundry_conversation "$d"
  req "$base" "$tok" POST "/openai/v1/conversations/$d/items" "{\"items\":[$(for i in $(seq 1 20); do msg user "D$i"; [ $i -lt 20 ] && printf ,; done)]}"; echo "batch20=$STATUS $(echo "$BODY" | jq -r '.data|length')"
  req "$base" "$tok" POST "/openai/v1/conversations/$d/items" "{\"items\":[$(for i in $(seq 1 21); do msg user "E$i"; [ $i -lt 21 ] && printf ,; done)]}"; echo "batch21=$STATUS $(echo "$BODY" | jq -r '.error.code')"
  req "$base" "$tok" POST "/openai/v1/conversations/$d/items" "{\"items\":[{\"type\":\"message\",\"role\":\"user\",\"content\":\"$(head -c 100000 /dev/zero | tr '\0' x)\"}]}"; echo "text100k=$STATUS $(echo "$BODY" | jq -r '.data[0].content[0].text|length')"
  req "$base" "$tok" GET "/openai/v1/conversations/$d"; echo "conversation.get=$STATUS $(echo "$BODY" | jq -r '.object')"
  # the list of conversations carries the metadata
  req "$base" "$tok" GET "/openai/v1/conversations?limit=100&order=desc"; echo "convlist.keys=$(echo "$BODY" | jq -c 'keys')"
  echo "convlist.found_by_metadata=$(echo "$BODY" | jq '[.data[]? | select(.metadata.conversation_id=="fidelity")] | length')"
  # delete and the errors
  req "$base" "$tok" DELETE "/openai/v1/conversations/$d"; echo "delete=$STATUS"
  req "$base" "$tok" GET "/openai/v1/conversations/$d"; echo "after_delete.get=$STATUS $(echo "$BODY" | jq -r '.error.code')"
  req "$base" "$tok" GET "/openai/v1/conversations/$d/items"; echo "after_delete.items=$STATUS $(echo "$BODY" | jq -r '.error.code')"
  req "$base" "$tok" DELETE "/openai/v1/conversations/$d"; echo "delete_again=$STATUS"
  req "$base" "$tok" GET "/openai/v1/conversations/conv_doesnotexist0000"; echo "malformed=$STATUS $(echo "$BODY" | jq -r '.error.code')"
  req "$base" "not-a-token" GET "/openai/v1/conversations?limit=1"; echo "bad_token=$STATUS"
}

echo "== part 1: the real Foundry and the fake, the same calls"
foundry_token
# Redirected to files, not captured with $( ): a subshell would lose the conversations registered for cleanup.
OBS_DIR="$(mktemp -d)"
observe "${FOUNDRY_ENDPOINT}" "${FOUNDRY_TOKEN_CACHE}" > "${OBS_DIR}/real.txt"
observe "${FAKE}" "fake-token" > "${OBS_DIR}/fake.txt"
REAL_OBS="$(cat "${OBS_DIR}/real.txt")"; FAKE_OBS="$(cat "${OBS_DIR}/fake.txt")"; rm -rf "${OBS_DIR}"
check "the real block ran to the end" true "$(echo "${REAL_OBS}" | grep -q '^bad_token=401$' && echo true || echo false)"
while IFS= read -r line; do
  name="${line%%=*}"
  fake_line="$(echo "${FAKE_OBS}" | grep -F -- "${name}=" | head -1)"
  if [ "${line}" = "${fake_line}" ]; then pass "${line}"; else fail "${name}: real [${line#*=}] fake [${fake_line#*=}]"; fi
done <<< "${REAL_OBS}"
check "the fake saw the same number of observations" "$(echo "${REAL_OBS}" | wc -l | tr -d ' ')" "$(echo "${FAKE_OBS}" | wc -l | tr -d ' ')"

echo "== part 2: the faults only the fake has"
ctl() { curl -s -m 10 -X POST "http://localhost:8098$1" ${2:+-H 'Content-Type: application/json' --data "$2"}; }
ctl /__reset >/dev/null
for mode in 429 500 400 401; do
  ctl /__fail "{\"mode\":\"${mode}\",\"count\":2}" >/dev/null
  req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"; check "fault ${mode}: first call" "${mode}" "${STATUS}"
  req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"; check "fault ${mode}: second call" "${mode}" "${STATUS}"
  req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"; check "fault ${mode}: ends after its count" 200 "${STATUS}"
done
ctl /__fail '{"mode":"429","count":1}' >/dev/null; req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"
check_contains "429 carries Retry-After" "Retry-After: 1" "${HEADERS}"
ctl /__fail '{"mode":"500","count":-1}' >/dev/null
req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"; req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"
check "count -1 keeps failing until reset" 500 "${STATUS}"
ctl /__reset >/dev/null; req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"; check "reset clears the fault" 200 "${STATUS}"
ctl /__fail '{"mode":"500","count":1,"method":"POST"}' >/dev/null
req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"; check "a method filter lets other methods through" 200 "${STATUS}"
req "${FAKE}" tok POST /openai/v1/conversations '{}'; check "and fails the method it names" 500 "${STATUS}"
req "${FAKE}" tok POST /openai/v1/conversations '{}'; check "once, as counted" 200 "${STATUS}"
ctl /__fail '{"mode":"slow","count":1,"delayMs":800}' >/dev/null
START="$(python3 -I -c 'import time; print(int(time.time()*1000))')"; req "${FAKE}" tok GET "/openai/v1/conversations?limit=1"
ELAPSED=$(( $(python3 -I -c 'import time; print(int(time.time()*1000))') - START ))
check "slow still serves the request" 200 "${STATUS}"; check "slow takes the delay" true "$([ "${ELAPSED}" -ge 750 ] && echo true || echo false)"
req "${FAKE}" tok POST /openai/v1/conversations '{}'; CF="$(echo "${BODY}" | jq -r .id)"
ctl /__fail '{"mode":"late","count":1,"delayMs":1500}' >/dev/null
START="$(python3 -I -c 'import time; print(int(time.time()*1000))')"; req "${FAKE}" tok POST "/openai/v1/conversations/${CF}/items" "{\"items\":[$(msg user held)]}"
ELAPSED=$(( $(python3 -I -c 'import time; print(int(time.time()*1000))') - START ))
check "late: the answer comes after the delay" true "$([ "${ELAPSED}" -ge 1400 ] && echo true || echo false)"
check "late: and the item was applied" 1 "$(curl -s http://localhost:8098/__state | jq -r ".items[\"${CF}\"]")"
ctl /__fail '{"mode":"drop","count":1}' >/dev/null
req "${FAKE}" tok POST "/openai/v1/conversations/${CF}/items" "{\"items\":[$(msg user once)]}"
check "drop: the caller gets no answer" 000 "${STATUS}"
check "drop: but Foundry applied the item" 2 "$(curl -s http://localhost:8098/__state | jq -r ".items[\"${CF}\"]")"
req "${FAKE}" tok POST "/openai/v1/conversations/${CF}/items" "{\"items\":[$(msg user once)]}"
check "a plain retry after a drop duplicates (the reason the sync reconciles)" 3 "$(curl -s http://localhost:8098/__state | jq -r ".items[\"${CF}\"]")"
ctl /__reset >/dev/null

summary
