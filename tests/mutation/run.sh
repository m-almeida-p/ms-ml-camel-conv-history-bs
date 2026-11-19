#!/usr/bin/env bash
# Runs the mutation experiment (tests/mutation/mutate.py) in a copy of the repo, and removes the copy.
#
#   ./tests/mutation/run.sh            every mutation (about 20 minutes)
#   ./tests/mutation/run.sh 3 12 13    only those numbers (the order of the list in mutate.py, from 0)
#
# The copy goes under your HOME, not under /tmp: on macOS Docker cannot see /private/tmp, and Maven would find an empty folder
# ("NO TESTS RAN"). Needs Docker, the cluster, and what scripts/test-camel.sh needs.

# shellcheck source=../../scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"
require_docker
require_cluster_network
COPY="${HOME}/.mutation-scratch-$$"
trap 'rm -rf "${COPY}"' EXIT
mkdir -p "${COPY}"
rsync -a --exclude .git --exclude temp --exclude target --exclude .devmode-local --exclude .test-logs "${REPO_DIR}/" "${COPY}/"
cd "${COPY}"
python3 -I tests/mutation/mutate.py "${COPY}" "$@"
