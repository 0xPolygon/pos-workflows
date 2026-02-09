#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pos_test_utils.sh"

test_milestones() {
	echo ""
	echo "Starting milestone monitor..."

	local heimdall_http_url
	heimdall_http_url=$(kurtosis port print "${ENCLAVE_NAME}" "l2-cl-1-heimdall-v2-bor-validator" http 2>/dev/null)
	echo "Heimdall HTTP: ${heimdall_http_url}"

	local initial_count
	initial_count=$(curl -s "${heimdall_http_url}/milestones/count" | jq -r '.count // 0')
	[[ "${initial_count}" == "null" || -z "${initial_count}" ]] && initial_count=0
	local target=$((initial_count + 10))
	echo "Initial milestone count: ${initial_count}, target: ${target}"

	local milestone_cmd='curl -s "'"${heimdall_http_url}"'/milestones/count" | jq -r ".count // 0"'
	_assert_cmd_eventually_gte "${milestone_cmd}" "${target}" 300 5

	echo "✅ Milestone monitor passed: reached ${target} milestones"
}

setup_pos_env
test_milestones
