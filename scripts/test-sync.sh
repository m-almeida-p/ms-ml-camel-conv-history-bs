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

require_docker
require_cluster_network
command -v jq >/dev/null || { echo "❌  jq is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "❌  python3 is required" >&2; exit 1; }

section_base() {
  echo "== base: the copied beans are the consumer's beans"
  for f in ConversationEventDecoder.java PoisonRecordException.java OffsetCommit.java; do
    check "${f} is identical to the consumer's" "$(shasum "${REPO_DIR}/conv-history-consumer/${f}" | cut -c1-40)" "$(shasum "${REPO_DIR}/${PROJECT}/${f}" | cut -c1-40)"
  done
  check "the group is not the consumer's" true "$(! grep -q 'groupId=ms-ml-camel-conv-history-bs$' "${REPO_DIR}/${PROJECT}/application.properties" && echo true || echo false)"
  check "the group is not the original service's" true "$(! grep -q 'ms-ml-conv-history-bs$' "${REPO_DIR}/${PROJECT}/application.properties" && echo true || echo false)"
  check "no secret and no endpoint in the properties" 0 "$(grep -cE 'client_secret|password=[^$]|https://.*\.azure\.com' "${REPO_DIR}/${PROJECT}/application.properties" | tr -d ' ')"
}

ALL_SECTIONS="base"
for s in ${*:-${ALL_SECTIONS}}; do "section_${s}"; done
summary
