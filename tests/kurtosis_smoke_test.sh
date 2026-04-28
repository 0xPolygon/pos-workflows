#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bridge_test_utils.sh"
source "$SCRIPT_DIR/evm_test_helpers.sh"

ENCLAVE_NAME=${ENCLAVE_NAME:-"kurtosis-e2e"}
HEIMDALL_SERVICE_NAME=${HEIMDALL_SERVICE_NAME:-"l2-cl-1-heimdall-v2-bor-validator"}
TX_MINE_TIMEOUT=${TX_MINE_TIMEOUT:-120}

# Service configuration for e2e tests
# 4 validators (l2-el-1 to l2-el-4) + 2 RPC nodes (l2-el-5, l2-el-6)
VALIDATORS=("l2-el-1-bor-heimdall-v2-validator" "l2-el-2-bor-heimdall-v2-validator" "l2-el-3-bor-heimdall-v2-validator" "l2-el-4-bor-heimdall-v2-validator")
RPC_SERVICES=("l2-el-5-bor-heimdall-v2-rpc")
BASELINE_SERVICE="l2-el-6-bor-heimdall-v2-rpc"

get_http_url() {
	local service_name=$1
	kurtosis port print $ENCLAVE_NAME $service_name http 2>/dev/null || echo ""
}

get_rpc_url() {
	local service_name=$1
	kurtosis port print $ENCLAVE_NAME $service_name rpc 2>/dev/null || echo ""
}

get_block_number() {
	local service_name=$1
	local rpc_url=$(get_rpc_url "$service_name")
	if [ -z "$rpc_url" ]; then
		echo ""
		return
	fi
	cast block-number --rpc-url "$rpc_url" 2>/dev/null || echo ""
}

get_block_hash() {
	local service_name=$1
	local block_number=$2
	local rpc_url=$(get_rpc_url "$service_name")
	if [ -z "$rpc_url" ]; then
		echo ""
		return
	fi
	cast block "$block_number" --rpc-url "$rpc_url" --json 2>/dev/null | jq -r '.hash // empty'
}

wait_for_block() {
	local target_block=$1
	local service_name="${VALIDATORS[0]}"
	echo "Waiting for block $target_block..."

	while true; do
		current_block=$(get_block_number "$service_name")
		if [[ "$current_block" =~ ^[0-9]+$ ]] && [ "$current_block" -ge "$target_block" ]; then
			echo "Reached block $current_block (target: $target_block)"
			return 0
		fi
		echo "Current block: $current_block, waiting for $target_block..."
		sleep 1
	done
}

test_checkpoints() {
	echo "Starting checkpoints test..."

	local http_url=$(get_http_url $HEIMDALL_SERVICE_NAME)

	if [ -z "$http_url" ]; then
		echo "Failed to get HTTP URL for service: $HEIMDALL_SERVICE_NAME"
		echo "Available services in enclave:"
		kurtosis enclave inspect $ENCLAVE_NAME 2>/dev/null || echo "Could not inspect enclave"
		return 1
	fi

	echo "Using Heimdall HTTP URL: $http_url"

	local max_attempts=100
	local attempt=0

	while [ $attempt -lt $max_attempts ]; do
		checkpointID=$(curl -s "${http_url}/checkpoints/latest" | jq -r '.checkpoint.id' 2>/dev/null || echo "null")

		if [ "$checkpointID" != "null" ] && [ "$checkpointID" != "" ]; then
			echo "Checkpoint created, ID: $checkpointID"
			return 0
		else
			echo "Current checkpoint: none (polling... attempt $((attempt + 1))/$max_attempts)"
			sleep 5
			((attempt++))
		fi
	done

	echo "❌ Timeout: No checkpoint created after $((max_attempts * 5)) seconds"
	return 1
}

test_milestones() {
	echo "Starting milestones test..."

	local http_url=$(get_http_url $HEIMDALL_SERVICE_NAME)

	if [ -z "$http_url" ]; then
		echo "Failed to get HTTP URL for service: $HEIMDALL_SERVICE_NAME"
		return 1
	fi

	echo "Using Heimdall HTTP URL: $http_url"

	local initial_count=$(curl -s "${http_url}/milestones/count" | jq -r '.count' 2>/dev/null || echo "0")

	if [ "$initial_count" = "null" ] || [ "$initial_count" = "" ]; then
		initial_count=0
	fi

	echo "Initial milestones count: $initial_count"
	local target_count=$((initial_count + 10))
	echo "Target milestones count: $target_count"

	local max_attempts=20
	local attempt=0

	while [ $attempt -lt $max_attempts ]; do
		current_count=$(curl -s "${http_url}/milestones/count" | jq -r '.count' 2>/dev/null || echo "0")

		if [ "$current_count" = "null" ] || [ "$current_count" = "" ]; then
			current_count=0
		fi

		if [ "$current_count" -ge "$target_count" ]; then
			echo "Milestones target reached, count: $current_count (+$((current_count - initial_count)))"
			return 0
		else
			echo "Current milestones count: $current_count (need $((target_count - current_count)) more, polling... attempt $((attempt + 1))/$max_attempts)"
			sleep 5
			((attempt++))
		fi
	done

	echo "❌ Timeout: Only $((current_count - initial_count)) milestones created in 100 seconds (expected 10)"
	return 1
}

# EVM opcode and precompile coverage test
# Tests all EVM opcodes and precompiled contracts using polycli's LoadTester and evm-stress contracts
# Verifies transactions on both primary RPC and baseline node (stable release)
test_evm_opcode_coverage() {
	echo "Starting evm opcode and precompile coverage test..."

	# Check polycli availability
	if ! command -v polycli &>/dev/null; then
		echo "⚠️  polycli not found, skipping EVM opcode coverage test"
		return 0
	fi

	# Get RPC URLs
	first_rpc_service="${RPC_SERVICES[0]}"
	first_rpc_url=$(get_rpc_url "$first_rpc_service")
	baseline_rpc_url=$(get_rpc_url "$BASELINE_SERVICE")

	if [ -z "$first_rpc_url" ]; then
		echo "❌ Failed to get primary RPC URL for $first_rpc_service"
		return 1
	fi

	if [ -z "$baseline_rpc_url" ]; then
		echo "❌ Failed to get baseline RPC URL for $BASELINE_SERVICE"
		return 1
	fi

	PRIVATE_KEY="0xd40311b5a5ca5eaeb48dfba5403bde4993ece8eccf4190e98e19fcd4754260ea"
	SENDER_ADDR="0x74Ed6F462Ef4638dc10FFb05af285e8976Fb8DC9"
	GAS_PRICE="50000000000"

	echo "Primary RPC: $first_rpc_service -> $first_rpc_url"
	echo "Baseline RPC: $BASELINE_SERVICE -> $baseline_rpc_url"

	declare -A tx_hashes
	declare -A tx_status
	failed_tests=()
	current_nonce=0

	# Deploy and send polycli LoadTester transactions
	if ! deploy_load_tester "$first_rpc_url"; then
		echo "❌ LoadTester deployment failed"
		return 1
	fi

	send_opcode_transactions "$first_rpc_url"
	send_precompile_transactions "$first_rpc_url"

	# Deploy and send evm-stress transactions
	if ! deploy_evm_stress "$first_rpc_url"; then
		echo "❌ evm-stress deployment failed"
		return 1
	fi

	send_evm_stress_transactions "$first_rpc_url"

	# Wait for all transactions to be mined
	wait_for_mining "$first_rpc_url"

	# Check for timeouts
	for test_name in "${!tx_status[@]}"; do
		if [ "${tx_status[$test_name]}" = "timeout" ]; then
			echo "❌ Some transactions timed out"
			return 1
		fi
	done

	# Verify receipts on primary and baseline nodes
	echo ""
	echo "Verifying transaction receipts..."
	passed=0
	failed=0

	EVM_STRESS_NAMES=()
	for action in "${ACTION_CODES[@]}"; do
		EVM_STRESS_NAMES+=("${EVM_STRESS_ACTIONS[$action]}")
	done

	ALL_TESTS=("${OPCODES[@]}" "${PRECOMPILE_NAMES[@]}" "${EVM_STRESS_NAMES[@]}")

	for test_name in "${ALL_TESTS[@]}"; do
		if [ "${tx_status[$test_name]}" = "send_failed" ]; then
			failed=$((failed + 1))
			failed_tests+=("$test_name:send_failed")
			continue
		fi

		tx_hash="${tx_hashes[$test_name]}"
		receipt=$(timeout 30 cast receipt "$tx_hash" --rpc-url "$first_rpc_url" --json 2>/dev/null)
		status=$(echo "$receipt" | jq -r '.status // "0x0"')

		if [ "$status" != "0x1" ]; then
			failed=$((failed + 1))
			failed_tests+=("$test_name:reverted")
			continue
		fi

		baseline_receipt=$(timeout 30 cast receipt "$tx_hash" --rpc-url "$baseline_rpc_url" --json 2>/dev/null)
		baseline_status=$(echo "$baseline_receipt" | jq -r '.status // empty')

		if [ "$baseline_status" != "0x1" ]; then
			failed=$((failed + 1))
			failed_tests+=("$test_name:not_on_baseline")
			continue
		fi

		passed=$((passed + 1))
	done
	echo "All transaction receipts verified"

	# Final sync verification
	echo ""
	echo "Final sync verification..."

	REFERENCE_NODE="${VALIDATORS[0]}"
	reference_block=$(get_block_number "$REFERENCE_NODE")

	if ! [[ "$reference_block" =~ ^[0-9]+$ ]] || [ "$reference_block" -le 0 ]; then
		echo "❌ Failed to get reference block number"
		return 1
	fi

	test_block=$((reference_block - 3))
	[ "$test_block" -le 0 ] && test_block=1

	reference_hash=$(get_block_hash "$REFERENCE_NODE" "$test_block")
	baseline_hash=$(get_block_hash "$BASELINE_SERVICE" "$test_block")

	if [ "$baseline_hash" != "$reference_hash" ]; then
		echo "❌ Block hash mismatch at block $test_block"
		return 1
	fi
	echo "Baseline node in sync at block $test_block"

	# Results
	total=$((passed + failed))
	echo ""
	echo "Results: $passed/$total passed"

	if [ $failed -gt 0 ]; then
		echo "Failed tests:"
		for ft in "${failed_tests[@]}"; do
			echo "  - $ft"
		done
		return 1
	fi

	return 0
}

main() {
	echo "Starting kurtosis smoke tests"
	echo "Enclave: $ENCLAVE_NAME"
	echo "Service: $HEIMDALL_SERVICE_NAME"
	echo ""

	wait_for_block 128
	echo ""

	# Setup producer planned downtime early
	"$SCRIPT_DIR/producer_planned_downtime/setup.sh"
	echo ""

	if ! test_evm_opcode_coverage; then
		echo "❌ EVM opcode coverage test failed"
		exit 1
	fi
	echo "✅ EVM opcode and precompile coverage test passed"
	echo ""

	if ! test_milestones; then
		echo "❌ Milestones test failed"
		exit 1
	fi
	echo "✅ Milestones test passed"
	echo ""

	setup_pos_env
	if ! test_bridge_l1_to_l2; then
		echo "❌ Plasma bridge test (POL + ERC20 + ERC721) failed"
		exit 1
	fi
	echo "✅ Plasma bridge test (POL + ERC20 + ERC721) passed"
	echo ""

	if ! test_checkpoints; then
		echo "❌ Checkpoints test failed"
		exit 1
	fi
	echo "✅ Checkpoints test passed"
	echo ""

	echo "✅ All smoke tests passed"
	exit 0
}

main "$@"
