#!/usr/bin/env bash
# Finds the Foundry conversations that this project created and that its map does not know (orphans), and can delete them.
#
#   ./scripts/foundry-cleanup-orphans.sh                     list them; deletes nothing
#   ./scripts/foundry-cleanup-orphans.sh --delete            delete them, after asking
#   ./scripts/foundry-cleanup-orphans.sh --delete --yes      delete them without asking
#   ./scripts/foundry-cleanup-orphans.sh --min-age SECONDS   only those older than this (default 600)
#
# How an orphan happens: the sync creates the Foundry conversation, and only then saves the map row. A crash between the two
# leaves a conversation in Foundry that nothing maps; the retry makes another one. Nothing reads an orphan, so it is harmless,
# but it takes room in the project.
#
# What it touches: only conversations whose metadata.source is ms-ml-camel-conv-history-bs and whose id is in no row of
# camel_history.foundry_conversation_map. A conversation of another source is never touched. The minimum age keeps it
# away from one the sync has just created and is about to map. Needs the FOUNDRY_* variables in .env, curl, jq.

# shellcheck source=./test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
DELETE=0; YES=0; MIN_AGE=600
while [ $# -gt 0 ]; do
  case "$1" in
    --delete) DELETE=1 ;;
    --yes) YES=1 ;;
    --min-age) MIN_AGE="${2:?--min-age needs a number of seconds}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }
[ -n "${FOUNDRY_ENDPOINT}" ] || { echo "❌  FOUNDRY_PROJECT_ENDPOINT is not set in .env" >&2; exit 1; }

known="$(sql "SELECT foundry_conversation_id FROM camel_history.foundry_conversation_map" | sort)"
now="$(date +%s)"; orphans=(); skipped_young=0; after=""; total=0
while :; do
  foundry GET "/openai/v1/conversations?limit=100&order=desc${after:+&after=${after}}"
  [ "${STATUS}" = 200 ] || { echo "❌  Foundry answered ${STATUS} when listing" >&2; exit 1; }
  total=$((total + $(echo "${BODY}" | jq '.data | length')))
  while IFS=$'\t' read -r id created; do
    [ -n "${id}" ] || continue
    grep -qxF "${id}" <<< "${known}" && continue
    if [ $((now - created)) -lt "${MIN_AGE}" ]; then skipped_young=$((skipped_young + 1)); continue; fi
    orphans+=("${id}")
  done < <(echo "${BODY}" | jq -r '.data[] | select(.metadata.source == "ms-ml-camel-conv-history-bs") | [.id, .created_at] | @tsv')
  [ "$(echo "${BODY}" | jq -r .has_more)" = true ] || break
  after="$(echo "${BODY}" | jq -r .last_id)"
done

echo "Foundry holds ${total} conversation(s); the map knows $(echo "${known}" | grep -c . || true)."
echo "orphans of this project: ${#orphans[@]}   (skipped as younger than ${MIN_AGE} s: ${skipped_young})"
for id in ${orphans[@]+"${orphans[@]}"}; do echo "  ${id}"; done
[ "${#orphans[@]}" -gt 0 ] || exit 0
[ "${DELETE}" = 1 ] || { echo "nothing deleted. Add --delete to remove them."; exit 0; }
if [ "${YES}" != 1 ]; then
  printf "Delete these %s conversation(s) from Foundry? This cannot be undone. Type yes: " "${#orphans[@]}"
  read -r answer || answer=no
  [ "${answer}" = yes ] || { echo "nothing deleted."; exit 0; }
fi
deleted=0
for id in "${orphans[@]}"; do
  foundry DELETE "/openai/v1/conversations/${id}"
  if [ "${STATUS}" = 200 ] || [ "${STATUS}" = 404 ]; then deleted=$((deleted + 1)); else echo "  could not delete ${id}: HTTP ${STATUS}" >&2; fi
done
echo "deleted ${deleted} of ${#orphans[@]}"
