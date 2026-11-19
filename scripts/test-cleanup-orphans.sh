#!/usr/bin/env bash
# Test of scripts/foundry-cleanup-orphans.sh on the real Foundry project, with fake conversations it creates and removes.
#
#   ./scripts/test-cleanup-orphans.sh
#
# Makes three conversations: an orphan of this project (metadata.source ours, in no map row), one of another source, and one
# of ours that IS mapped (a fixture row). Checks that listing deletes nothing, that --delete removes only the orphan, that
# the minimum age protects a young one, and that the real, mapped conversations are left alone.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
SCRIPT="${REPO_DIR}/scripts/foundry-cleanup-orphans.sh"
trap 'foundry_cleanup; sql "DELETE FROM camel_history.foundry_conversation_map WHERE conversation_id LIKE '"'"'tco-%'"'"'" >/dev/null 2>&1 || true' EXIT
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }

make() { foundry POST /openai/v1/conversations "{\"metadata\":{\"conversation_id\":\"$1\",\"source\":\"$2\"${3:-}}}"; echo "${BODY}" | jq -r .id; }
orphan="$(make tco-orphan ms-ml-camel-conv-history-bs)"; track_foundry_conversation "${orphan}"
foreign="$(make tco-foreign some-other-project)";        track_foundry_conversation "${foreign}"
mapped="$(make tco-mapped ms-ml-camel-conv-history-bs)"; track_foundry_conversation "${mapped}"
other_stack="$(make tco-other ms-ml-camel-conv-history-bs ',"instance":"someone-else"')"; track_foundry_conversation "${other_stack}"
sql "INSERT INTO camel_history.foundry_conversation_map (conversation_id, foundry_conversation_id, last_synced_sequence) VALUES ('tco-mapped', '${mapped}', 1)" >/dev/null
real_before="$(sql "SELECT count(*) FROM camel_history.foundry_conversation_map WHERE conversation_id NOT LIKE 'tco-%'")"
status_of() { foundry GET "/openai/v1/conversations/$1"; echo "${STATUS}"; }

echo "== listing"
out="$("${SCRIPT}" --min-age 0)"
check_contains "the orphan is listed" "${orphan}" "${out}"
check "the foreign conversation is not" 0 "$(grep -cF "${foreign}" <<< "${out}" || true)"
check "the mapped one is not" 0 "$(grep -cF "${mapped}" <<< "${out}" || true)"
check "nothing was deleted by listing" 200 "$(status_of "${orphan}")"
check_contains "it says so" "nothing deleted" "${out}"

echo "== a conversation of another instance (stack) is not ours to clean"
check "the other stack's orphan is not listed by default" 0 "$(grep -cF "${other_stack}" <<< "${out}" || true)"
out2="$("${SCRIPT}" --min-age 0 --instance someone-else)"
check_contains "but it is when that instance is asked for" "${other_stack}" "${out2}"
check "and then the default one is not" 0 "$(grep -cF "${orphan}" <<< "${out2}" || true)"

echo "== an empty map: --delete --yes refuses, because every conversation would look like an orphan"
rc=0; out="$(CLEANUP_MAP_QUERY="SELECT foundry_conversation_id FROM camel_history.foundry_conversation_map WHERE false" "${SCRIPT}" --min-age 0 --delete --yes 2>&1)" || rc=$?
check "it exits with an error" 2 "${rc}"
check_contains "and says why" "the map has no rows" "${out}"
check "nothing was deleted" 200 "$(status_of "${orphan}")"
check "the mapped conversation is still there too" 200 "$(status_of "${mapped}")"

echo "== the minimum age protects a young conversation"
out="$("${SCRIPT}" --min-age 3600 --delete --yes)"
check_contains "the young orphan is skipped" "skipped as younger than 3600 s: 1" "${out}"
check "and still there" 200 "$(status_of "${orphan}")"

echo "== --delete without --yes asks first, and does nothing unless told yes"
out="$(echo no | "${SCRIPT}" --min-age 0 --delete)"
check_contains "it asked" "Type yes" "${out}"
check "and a no deleted nothing" 200 "$(status_of "${orphan}")"

echo "== --delete --yes"
out="$("${SCRIPT}" --min-age 0 --delete --yes)"
check_contains "it reports one deletion" "deleted 1 of 1" "${out}"
check "the orphan is gone" 404 "$(status_of "${orphan}")"
check "the foreign conversation is untouched" 200 "$(status_of "${foreign}")"
check "the mapped conversation is untouched" 200 "$(status_of "${mapped}")"
check "the other stack's orphan is untouched" 200 "$(status_of "${other_stack}")"
check "every real mapped conversation is still in Foundry" "${real_before}" "$(for id in $(sql "SELECT foundry_conversation_id FROM camel_history.foundry_conversation_map WHERE conversation_id NOT LIKE 'tco-%'"); do foundry GET "/openai/v1/conversations/${id}"; echo "${STATUS}"; done | grep -c '^200$')"
out="$("${SCRIPT}" --min-age 0)"
check_contains "a second run finds no orphan" "(instance default): 0" "${out}"
summary
