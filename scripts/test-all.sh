#!/usr/bin/env bash
# Runs every test of the repo, one suite after another, and ends with one table.
#
#   ./scripts/test-all.sh               everything that needs only the cluster, the fake Foundry and the real Foundry (no VPN)
#   ./scripts/test-all.sh --offline     no call to the real Foundry: docs, JUnit, token broker, fake, consumer, sync (fake), API
#   ./scripts/test-all.sh --e2e         also the real producer flow (needs the VPN and the agent: test-e2e.sh)
#   ./scripts/test-all.sh --only camel,sync     only the named suites (names are in the SUITES list below)
#   ./scripts/test-all.sh --stop        stop at the first suite that fails (the default runs them all)
#
# Needs: Docker, the cluster up, Karavan's API container for the oracle and the real-Foundry checks, curl, jq, python3.
# The full output of each suite is kept in .test-logs/<name>.log (git-ignored); the table shows its last summary line.
# Every suite removes what it created (rows, topics, Foundry conversations), so they can run again at once.

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_docker
require_cluster_network

# name | needs real Foundry (1/0) | command
SUITES=(
  "docs|0|python3 -I scripts/check-docs.py"
  "camel|0|scripts/test-camel.sh"
  "broker|1|scripts/test-token-broker.sh"
  "fake|1|scripts/test-fake-foundry.sh"
  "consumer|0|scripts/test-consumer.sh"
  "sync|0|scripts/test-sync.sh"
  "api|0|scripts/test-api.sh"
  "orphans|1|scripts/test-cleanup-orphans.sh"
  "oracle|0|scripts/oracle-api.sh"
  "foundry-sync|1|scripts/check-foundry-sync.sh"
)
E2E="e2e|1|scripts/test-e2e.sh"

offline=0; stop=0; only=""; with_e2e=0
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) offline=1 ;;
    --e2e) with_e2e=1 ;;
    --stop) stop=1 ;;
    --only) shift; only="$1" ;;
    -h|--help) sed -n 2,13p "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ "${with_e2e}" = 1 ] && SUITES+=("${E2E}")

LOGS="${REPO_DIR}/.test-logs"
mkdir -p "${LOGS}"
cd "${REPO_DIR}"

names=(); results=(); times=(); notes=()
failed=0
for entry in "${SUITES[@]}"; do
  IFS='|' read -r name real command <<< "${entry}"
  if [ -n "${only}" ] && ! [[ ",${only}," == *",${name},"* ]]; then continue; fi
  names+=("${name}"); log="${LOGS}/${name}.log"
  if [ "${offline}" = 1 ] && [ "${real}" = 1 ]; then
    results+=("skipped"); times+=("-"); notes+=("needs the real Foundry (--offline)"); continue
  fi
  echo "▶  ${name}: ${command}"
  start=$(date +%s)
  if bash -c "${command}" > "${log}" 2>&1; then status="ok"; else status="FAILED"; failed=$((failed + 1)); fi
  seconds=$(( $(date +%s) - start ))
  summary="$(sed 's/\x1b\[[0-9;]*m//g' "${log}" | grep -E 'tests,|checks|all checks passed|agree|OK:|ok  |passed|✅|❌' | tail -1 | cut -c1-90)"
  results+=("${status}"); times+=("${seconds}s"); notes+=("${summary}")
  if [ "${status}" = FAILED ]; then
    echo "   ❌ ${name} failed; last lines of ${log}:"; sed 's/\x1b\[[0-9;]*m//g' "${log}" | grep -E 'FAIL|ERROR|expected|❌' | head -12 | cut -c1-200 | sed 's/^/      /'
    [ "${stop}" = 1 ] && break
  fi
done

echo
printf '%-14s %-8s %6s   %s\n' suite result time "last line"
printf '%-14s %-8s %6s   %s\n' -------------- -------- ------ ---------
for i in "${!names[@]}"; do printf '%-14s %-8s %6s   %s\n' "${names[$i]}" "${results[$i]}" "${times[$i]}" "${notes[$i]}"; done
echo
if [ "${failed}" = 0 ]; then echo "✅  every suite passed"; else echo "❌  ${failed} suite(s) failed (full output in .test-logs/)"; exit 1; fi
