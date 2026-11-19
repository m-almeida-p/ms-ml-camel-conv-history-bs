#!/usr/bin/env bash
# Runs scripts/contract-check.py in a container, so nothing is installed on this computer.
#
#   ./scripts/contract-check.sh <directory of recorded responses>
#
# Checks them against docs/contract/ms-ml-conv-history-bs-openapi.yml (the OpenAPI of ms-ml-conv-history-bs, copied unchanged).

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
dir="${1:?usage: $0 <directory of recorded responses>}"
require_docker
docker run --rm -v "${REPO_DIR}/scripts/contract-check.py:/check.py:ro" -v "${REPO_DIR}/docs/contract:/contract:ro" \
  -v "$(cd "${dir}" && pwd):/recorded:ro" -v contract-check-pip:/root/.cache/pip python:3.13-alpine \
  sh -c 'pip install -q pyyaml jsonschema >/dev/null 2>&1 && python /check.py /contract/ms-ml-conv-history-bs-openapi.yml /recorded'
