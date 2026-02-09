#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pos_test_utils.sh"

test_checkpoint() {
	echo ""
	echo "Starting checkpoint monitor..."

	local heimdall_http_url
	heimdall_http_url=$(kurtosis port print "${ENCLAVE_NAME}" "l2-cl-1-heimdall-v2-bor-validator" http 2>/dev/null)
	echo "Heimdall HTTP: ${heimdall_http_url}"

	local initial_id
	initial_id=$(curl -s "${heimdall_http_url}/checkpoints/latest" | jq -r '.checkpoint.id // 0')
	[[ "${initial_id}" == "null" || -z "${initial_id}" ]] && initial_id=0
	local target=$((initial_id + 1))
	echo "Initial checkpoint ID: ${initial_id}, waiting for: ${target}"

	local checkpoint_cmd='curl -s "'"${heimdall_http_url}"'/checkpoints/latest" | jq -r ".checkpoint.id // 0"'
	_assert_cmd_eventually_gte "${checkpoint_cmd}" "${target}" 600 5

	echo "✅ Checkpoint monitor passed: new checkpoint created"
}

setup_pos_env
test_checkpoint
