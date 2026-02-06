#!/bin/bash
set -e

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/kurtosis_test_utils.sh"
source "$SCRIPT_DIR/../bridge_test_utils.sh"

echo "Starting kurtosis stateless sync tests..."

# Check if required tools are available
check_required_tools

# Define the enclave name
ENCLAVE_NAME=${ENCLAVE_NAME:-"kurtosis-stateless-e2e"}
export ENCLAVE_NAME

# Setup service lists
setup_service_lists

# Verify services are accessible
verify_service_accessibility

# Test 1: Check all nodes reach TARGET_BLOCK and have same block hash
test_block_hash_consensus() {
	echo ""
	echo "Test 1: Checking all the nodes reach block $TARGET_BLOCK and have the same block hash"
	echo ""

	SECONDS=0
	start_time=$SECONDS

	while true; do
		current_time=$SECONDS
		elapsed=$((current_time - start_time))

		# Timeout check
		if [ $elapsed -gt $TEST_TIMEOUT_SECONDS ]; then
			echo "Timeout waiting for block $TARGET_BLOCK (after ${TEST_TIMEOUT_SECONDS}s)"
			return 1
		fi

		# Get block numbers from all services
		block_numbers=()
		max_block=0

		# Check all services (validators + RPC)
		ALL_TEST_SERVICES=("${VALIDATORS[@]}" "${RPC_SERVICES[@]}")

		for service in "${ALL_TEST_SERVICES[@]}"; do
			block_num=$(get_block_number $service)
			if [[ "$block_num" =~ ^[0-9]+$ ]]; then
				block_numbers+=($block_num)
				if [ $block_num -gt $max_block ]; then
					max_block=$block_num
				fi
			fi
		done

		echo "Current max block: $max_block ($(printf '%02dm:%02ds\n' $((elapsed / 60)) $((elapsed % 60)))) [${#block_numbers[@]} nodes responding]"

		# Check if all nodes have reached the target block
		min_block=${block_numbers[0]}
		for block in "${block_numbers[@]}"; do
			if [ $block -lt $min_block ]; then
				min_block=$block
			fi
		done

		if [ $min_block -ge $TARGET_BLOCK ]; then
			echo "All nodes have reached block $TARGET_BLOCK, checking block hash consensus..."

			# Get block hash for block TARGET_BLOCK from all services
			block_hashes=()
			reference_hash=""
			hash_mismatch=false

			for service in "${ALL_TEST_SERVICES[@]}"; do
				block_hash=$(get_block_hash $service $TARGET_BLOCK)
				if [ -n "$block_hash" ]; then
					block_hashes+=("$service:$block_hash")

					# Set reference hash from first service
					if [ -z "$reference_hash" ]; then
						reference_hash=$block_hash
						echo "Reference hash from $service: $reference_hash"
					else
						# Compare with reference hash.
						if [ "$block_hash" != "$reference_hash" ]; then
							echo "❌ Hash mismatch! $service has hash: $block_hash (expected: $reference_hash)"
							hash_mismatch=true
						else
							echo "✅ $service has matching hash: $block_hash"
						fi
					fi
				else
					echo "❌ Failed to get hash for block $TARGET_BLOCK from $service"
					hash_mismatch=true
				fi
			done

			if [ "$hash_mismatch" = true ]; then
				echo "❌ Block hash verification failed for block $TARGET_BLOCK"
				echo "All hashes collected:"
				for hash_entry in "${block_hashes[@]}"; do
					echo "  $hash_entry"
				done
				return 1
			else
				echo "✅ All nodes have reached block $TARGET_BLOCK with the same hash: $reference_hash"
				break
			fi
		fi

		sleep $SLEEP_INTERVAL
	done
}

# Test 2: Check nodes continue syncing after block TARGET_BLOCK_HF (veblop HF)
test_post_veblop_hf_behavior() {
	echo ""
	echo "Test 2: Checking post-veblop HF behavior (after block $TARGET_BLOCK_HF)"
	echo ""
	echo "Waiting for block $TARGET_BLOCK_POST_HF to ensure we're past veblop HF..."

	while true; do
		current_time=$SECONDS
		elapsed=$((current_time - start_time))

		# Timeout check
		if [ $elapsed -gt $TEST_TIMEOUT_SECONDS ]; then
			echo "Timeout waiting for post-HF block $TARGET_BLOCK_POST_HF (after ${TEST_TIMEOUT_SECONDS}s)"
			return 1
		fi

		# Check all services (should continue syncing after HF)
		max_block=0
		for service in "${VALIDATORS[@]}" "${RPC_SERVICES[@]}"; do
			block_num=$(get_block_number $service)
			if [[ "$block_num" =~ ^[0-9]+$ ]] && [ $block_num -gt $max_block ]; then
				max_block=$block_num
			fi
		done

		echo "Current max block: $max_block"

		if [ $max_block -ge $TARGET_BLOCK_POST_HF ]; then
			echo "✅ All nodes continued syncing past veblop HF"

			# Check block hash consensus for all services at block TARGET_BLOCK_POST_HF
			echo "Checking block hash consensus for all services at block $TARGET_BLOCK_POST_HF..."

			ALL_SERVICES=("${VALIDATORS[@]}" "${RPC_SERVICES[@]}")

			# Get block hash for block TARGET_BLOCK_POST_HF from all services
			block_hashes=()
			reference_hash=""
			hash_mismatch=false

			for service in "${ALL_SERVICES[@]}"; do
				block_hash=$(get_block_hash $service $TARGET_BLOCK_POST_HF)
				if [ -n "$block_hash" ]; then
					block_hashes+=("$service:$block_hash")

					# Set reference hash from first service
					if [ -z "$reference_hash" ]; then
						reference_hash=$block_hash
						echo "Reference hash from $service: $reference_hash"
					else
						# Compare with reference hash
						if [ "$block_hash" != "$reference_hash" ]; then
							echo "❌ Hash mismatch! $service has hash: $block_hash (expected: $reference_hash)"
							hash_mismatch=true
						else
							echo "✅ $service has matching hash: $block_hash"
						fi
					fi
				else
					echo "❌ Failed to get hash for block $TARGET_BLOCK_POST_HF from $service"
					hash_mismatch=true
				fi
			done

			if [ "$hash_mismatch" = true ]; then
				echo "❌ Block hash verification failed for block $TARGET_BLOCK_POST_HF"
				echo "All hashes collected:"
				for hash_entry in "${block_hashes[@]}"; do
					echo "  $hash_entry"
				done
				return 1
			else
				echo "✅ All services have the same hash for block $TARGET_BLOCK_POST_HF: $reference_hash"
			fi

			break
		fi

		sleep $SLEEP_INTERVAL
	done
}

# Test 3: Milestone settlement latency (baseline + with network latency)
test_milestone_settlement_latency_resilience() {
	echo ""
	echo "Test 3: Milestone settlement latency test"
	echo ""

	# Phase 1: Baseline check (no network latency, strict threshold)
	echo "Phase 1: Baseline (no network latency)"
	echo ""
	if ! test_milestone_settlement_latency "baseline" "$LATENCY_CHECK_ITERATIONS" "$NORMAL_SETTLEMENT_LATENCY_SECONDS"; then
		echo "❌ Baseline milestone settlement latency check failed"
		return 1
	fi
	echo "Baseline check passed"

	# Phase 2: With network latency (relaxed threshold)
	echo ""
	echo "Phase 2: With network latency"
	echo ""

	cleanup_network_latency() {
		echo "Cleaning up network latency..."
		wait_for_pending_network_latency
	}
	trap cleanup_network_latency EXIT

	if ! start_network_latency "$DELAY_EL" "$JITTER_EL" "$DELAY_CL" "$JITTER_CL" "$NETWORK_LATENCY_DURATION"; then
		echo "❌ Failed to start network latency"
		return 1
	fi

	echo "Waiting 10s for network latency to stabilize..."
	sleep 10

	if ! test_milestone_settlement_latency "with network latency" "$LATENCY_CHECK_ITERATIONS" "$MAX_SETTLEMENT_LATENCY_SECONDS"; then
		echo "❌ Milestone settlement latency exceeded threshold under network latency"
		return 1
	fi

	wait_for_pending_network_latency
	trap - EXIT
}

# Test 4: Extreme network latency recovery test
test_extreme_network_latency_recovery() {
	echo ""
	echo "Test 4: Extreme network latency recovery test"
	echo ""

	# Get initial block numbers before applying extreme latency
	echo "Recording initial block numbers before extreme latency..."
	initial_max_block=$(get_max_block_from_services "${VALIDATORS[@]}" "${RPC_SERVICES[@]}")
	echo "Initial max block: $initial_max_block"

	# Start extreme network latency
	echo "Applying extreme network latency (EL: ${EXTREME_DELAY_EL}ms±${EXTREME_JITTER_EL}ms, CL: ${EXTREME_DELAY_CL}ms±${EXTREME_JITTER_CL}ms)..."
	if ! start_network_latency "$EXTREME_DELAY_EL" "$EXTREME_JITTER_EL" "$EXTREME_DELAY_CL" "$EXTREME_JITTER_CL" "$EXTREME_LATENCY_DURATION"; then
		echo "❌ Failed to start extreme network latency, skipping extreme latency recovery test"
		return 1
	fi

	# Wait for network latency to complete
	wait_for_pending_network_latency

	# Test that nodes can recover and generate new blocks after extreme latency is removed
	echo "Testing recovery after extreme network latency removal..."
	if ! test_sync_recovery "after extreme network latency" 300 5; then
		echo "❌ Extreme network latency recovery test failed"
		return 1
	fi

	echo "✅ Extreme network latency recovery test passed - nodes successfully recovered and resumed block generation"
}

# Test 5: Load test with block producer rotation
test_load_with_rotation() {
	echo ""
	echo "Test 5: Load test with block producer rotation"
	echo ""

	if ! command -v polycli &>/dev/null; then
		echo "⚠️  polycli not found, skipping load test"
		return 0
	fi

	# Configuration
	MONITOR_NODE="l2-el-4-bor-heimdall-v2-validator"
	first_rpc_service="${RPC_SERVICES[0]}"
	first_rpc_url=$(get_rpc_url "$first_rpc_service")
	test_account="0x74Ed6F462Ef4638dc10FFb05af285e8976Fb8DC9"
	num_txs=6000
	num_rotations=3

	echo "RPC: $first_rpc_service -> $first_rpc_url"
	echo "Monitor node: $MONITOR_NODE"
	echo "Target: $num_txs txs, $num_rotations rotations"

	# Record initial state
	initial_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
	initial_reorg_count=$(get_reorg_count "$MONITOR_NODE")
	echo "Initial nonce: $initial_nonce, Initial reorgs: $initial_reorg_count"

	# Start load test in background
	echo ""
	echo "Starting load test in background..."
	polycli loadtest \
		--rpc-url "$first_rpc_url" \
		--private-key "0xd40311b5a5ca5eaeb48dfba5403bde4993ece8eccf4190e98e19fcd4754260ea" \
		--verbosity 500 \
		--requests $num_txs \
		--rate-limit 100 \
		--mode t \
		--gas-price 50000000000 >/tmp/polycli_rotation_test.log 2>&1 &
	LOAD_PID=$!
	echo "Load test PID: $LOAD_PID"
	sleep 5

	# Perform rotations while load test is running
	for rotation_round in $(seq 1 $num_rotations); do
		echo ""
		echo "Rotation $rotation_round/$num_rotations"

		current_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
		echo "Txs mined before rotation: $((current_nonce - initial_nonce))"

		echo "Executing rotation..."
		"$SCRIPT_DIR/rotate_current_block_producer.sh" || echo "⚠️  Rotation script failed, continuing..."

		if [ $rotation_round -lt $num_rotations ]; then
			echo "Waiting 15s before next rotation..."
			sleep 15
		fi

		post_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
		echo "Txs mined after rotation: $((post_nonce - initial_nonce))/$num_txs"
	done

	# Wait for load test to complete
	echo ""
	echo "Waiting for load test to complete (max 120s)..."
	WAIT_COUNT=0
	while kill -0 $LOAD_PID 2>/dev/null && [ $WAIT_COUNT -lt 120 ]; do
		sleep 5
		WAIT_COUNT=$((WAIT_COUNT + 5))
		current_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
		txs_so_far=$((current_nonce - initial_nonce))
		echo "  Progress: $txs_so_far/$num_txs ($WAIT_COUNT s)"

		if [ $txs_so_far -ge $num_txs ]; then
			echo "  Target reached, stopping load test..."
			kill $LOAD_PID 2>/dev/null || true
			break
		fi
	done

	kill $LOAD_PID 2>/dev/null || true
	echo "Waiting 10s for final txs to settle..."
	sleep 10

	# Verification
	echo ""
	echo "Verification"

	# 1. Check transactions mined
	final_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
	total_txs_mined=$((final_nonce - initial_nonce))
	echo "Transactions: $total_txs_mined/$num_txs mined"

	if [ $total_txs_mined -lt $num_txs ]; then
		echo "❌ Not all transactions mined"
		return 1
	fi

	# 2. Check block author diversity
	echo ""
	echo "Checking block author diversity..."
	if ! check_block_author_diversity "$MONITOR_NODE" 100 2; then
		echo "❌ Insufficient block author diversity"
		return 1
	fi

	# 3. Check no reorgs during test
	echo ""
	final_reorg_count=$(get_reorg_count "$MONITOR_NODE")
	echo "Reorg count: initial=$initial_reorg_count, final=$final_reorg_count"

	if [[ "$initial_reorg_count" =~ ^[0-9]+$ ]] && [[ "$final_reorg_count" =~ ^[0-9]+$ ]]; then
		reorg_diff=$((final_reorg_count - initial_reorg_count))
		if [ "$reorg_diff" -gt 0 ]; then
			echo "❌ Detected $reorg_diff reorgs during test"
			return 1
		fi
		echo "No reorgs detected"
	fi
}

# Test 6: Erigon node sync verification
test_erigon_node_sync() {
	echo ""
	echo "Test 6: Erigon node sync verification"
	echo ""

	# Get erigon service name
	ERIGON_SERVICE="l2-el-9-erigon-heimdall-v2-rpc"
	echo "Checking sync status of Erigon node: $ERIGON_SERVICE"

	# Build list of nodes to compare against
	SYNC_NODES=("${VALIDATORS[@]}" "${RPC_SERVICES[@]}")
	# Remove erigon from the comparison list since we're comparing it against others
	COMPARISON_NODES=()
	for node in "${SYNC_NODES[@]}"; do
		if [[ "$node" != "$ERIGON_SERVICE" ]]; then
			COMPARISON_NODES+=("$node")
		fi
	done

	echo "Comparing Erigon node against ${#COMPARISON_NODES[@]} other nodes"

	# Use first validator as reference node
	REFERENCE_NODE="${VALIDATORS[0]}"
	echo "Using reference node: $REFERENCE_NODE"

	# Get current block number from reference node
	reference_block=$(get_block_number "$REFERENCE_NODE")
	if ! [[ "$reference_block" =~ ^[0-9]+$ ]] || [ "$reference_block" -le 0 ]; then
		echo "❌ Failed to get valid block number from reference node: $reference_block"
		return 1
	fi

	# Use a recent block that should be stable (slightly behind current tip)
	test_block=$((reference_block - 3))
	if [ "$test_block" -le 0 ]; then
		test_block=1
	fi

	echo "Testing sync at block $test_block (reference node at block $reference_block)"

	# Get block hash from reference node
	reference_hash=$(get_block_hash "$REFERENCE_NODE" "$test_block")
	if [ -z "$reference_hash" ]; then
		echo "❌ Failed to get block hash from reference node for block $test_block"
		return 1
	fi

	echo "Reference hash from $REFERENCE_NODE: $reference_hash"

	# First check if Erigon node has reached this block
	erigon_block=$(get_block_number "$ERIGON_SERVICE")
	if ! [[ "$erigon_block" =~ ^[0-9]+$ ]] || [ "$erigon_block" -le 0 ]; then
		echo "❌ Failed to get valid block number from Erigon node: $erigon_block"
		return 1
	fi

	if [ "$erigon_block" -lt "$test_block" ]; then
		echo "❌ Erigon node is behind - current block: $erigon_block, test block: $test_block"
		return 1
	fi

	echo "Erigon node current block: $erigon_block"

	# Get block hash from Erigon node
	erigon_hash=$(get_block_hash "$ERIGON_SERVICE" "$test_block")
	if [ -z "$erigon_hash" ]; then
		echo "❌ Failed to get block hash from Erigon node for block $test_block"
		return 1
	fi

	# Check if Erigon matches the reference
	if [ "$erigon_hash" = "$reference_hash" ]; then
		echo "✅ Erigon node matches reference hash: $erigon_hash"
	else
		echo "❌ Erigon hash mismatch! Erigon: $erigon_hash, Reference: $reference_hash"
		return 1
	fi

	# Compare against additional nodes for comprehensive verification
	sync_mismatch=false
	successful_comparisons=1 # Already verified Erigon matches reference

	# Remove the reference node from comparison list since we already used it
	REMAINING_NODES=()
	for node in "${COMPARISON_NODES[@]}"; do
		if [[ "$node" != "$REFERENCE_NODE" ]]; then
			REMAINING_NODES+=("$node")
		fi
	done

	echo ""
	echo "Verifying additional nodes also match the reference hash..."
	for node in "${REMAINING_NODES[@]}"; do
		node_hash=$(get_block_hash "$node" "$test_block")
		if [ -n "$node_hash" ]; then
			if [ "$node_hash" = "$reference_hash" ]; then
				echo "✅ $node matches reference hash: $node_hash"
				successful_comparisons=$((successful_comparisons + 1))
			else
				echo "❌ Hash mismatch! $node has hash: $node_hash (expected: $reference_hash)"
				sync_mismatch=true
			fi
		else
			# Failure to get hash is not a sync mismatch - could be temporary node unavailability
			echo "⚠️  Failed to get hash for block $test_block from $node (node may be temporarily unavailable)"
		fi
	done

	# Verify we had enough successful comparisons (including Erigon)
	if [ "$successful_comparisons" -lt 4 ]; then
		echo "❌ Insufficient successful comparisons: $successful_comparisons (need at least 4 including Erigon)"
		sync_mismatch=true
	fi

	if [ "$sync_mismatch" = false ]; then
		echo ""
		echo "✅ Erigon node sync test passed - Erigon node is in sync with all nodes"
		echo "   Successful comparisons: $successful_comparisons"
		return 0
	else
		echo ""
		echo "❌ Erigon node sync test failed - sync mismatches detected"
		return 1
	fi
}

# Test 7: Fastforward sync verification
test_fastforward_sync() {
	echo ""
	echo "Test 7: Fastforward sync verification"
	echo ""

	TARGET_VALIDATOR="l2-el-4-bor-heimdall-v2-validator"
	REFERENCE_NODE="${VALIDATORS[0]}"
	test_account="0x74Ed6F462Ef4638dc10FFb05af285e8976Fb8DC9"
	num_txs=3000

	# Check if polycli is available
	if ! command -v polycli &>/dev/null; then
		echo "⚠️  polycli not found, skipping fastforward sync test"
		return 0
	fi

	first_rpc_url=$(get_rpc_url "${RPC_SERVICES[0]}")
	initial_block=$(get_block_number "$REFERENCE_NODE")
	initial_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")

	echo "Target: $TARGET_VALIDATOR | Initial block: $initial_block | Initial nonce: $initial_nonce"

	# Stop validator and start load test
	echo "Stopping target validator..."
	kurtosis service stop "$ENCLAVE_NAME" "$TARGET_VALIDATOR" || {
		echo "❌ Failed to stop validator"
		return 1
	}
	sleep 5

	echo "Starting uniswapv3 load test in background..."
	polycli loadtest --rpc-url "$first_rpc_url" \
		--private-key "0xd40311b5a5ca5eaeb48dfba5403bde4993ece8eccf4190e98e19fcd4754260ea" \
		--verbosity 500 --requests $num_txs --rate-limit 100 --mode uniswapv3 \
		--gas-price 35000000000 >/tmp/polycli_fastforward_test.log 2>&1 &
	LOAD_PID=$!

	# Wait for network to advance (target: >64 blocks gap, max 90s)
	echo "Waiting for network to advance (target: >64 blocks gap, max 90s)..."
	for ((i = 90; i > 0; i -= 10)); do
		sleep 10
		current_block=$(get_block_number "$REFERENCE_NODE")
		blocks_advanced=$((current_block - initial_block))
		echo "  ${i}s remaining... Block: $current_block (+$blocks_advanced blocks)"
		if [ "$blocks_advanced" -gt 64 ]; then
			echo "  Target gap reached, continuing..."
			break
		fi
	done

	blocks_gap=$(($(get_block_number "$REFERENCE_NODE") - initial_block))
	echo "Network advanced by $blocks_gap blocks"
	[ "$blocks_gap" -lt 64 ] && echo "⚠️  Gap may be insufficient to trigger fastforward"

	# Restart validator
	echo "Restarting target validator..."
	if ! kurtosis service start "$ENCLAVE_NAME" "$TARGET_VALIDATOR"; then
		echo "❌ Failed to start validator"
		kill $LOAD_PID 2>/dev/null || true
		return 1
	fi

	sleep 15

	# Check for fastforward in logs
	fastforward_detected=false
	for attempt in {1..3}; do
		if kurtosis service logs "$ENCLAVE_NAME" "$TARGET_VALIDATOR" --all 2>&1 | grep -q "Fast forwarding stateless node due to large gap"; then
			echo "✅ Fastforward mode detected in logs!"
			fastforward_detected=true
			break
		fi
		[ $attempt -lt 3 ] && sleep 10
	done

	if [ "$fastforward_detected" = false ]; then
		echo "❌ Fastforward indicator not found in logs after 3 attempts"
		kill $LOAD_PID 2>/dev/null || true
		return 1
	fi

	# Wait for validator to sync to tip
	echo "Monitoring sync progress (max 60s)..."
	sync_timeout=60
	sync_start=$SECONDS
	synced_successfully=false

	while [ $((SECONDS - sync_start)) -lt $sync_timeout ]; do
		reference_block=$(get_block_number "$REFERENCE_NODE")
		target_block=$(get_block_number "$TARGET_VALIDATOR")

		if [[ "$target_block" =~ ^[0-9]+$ ]] && [ "$target_block" -gt 0 ]; then
			block_diff=$((reference_block - target_block))
			echo "  $((SECONDS - sync_start))s: Target=$target_block, Ref=$reference_block, Diff=$block_diff"

			if [ "$block_diff" -le 5 ] && [ "$block_diff" -ge -5 ]; then
				echo "✅ Target validator synced to tip"
				synced_successfully=true
				break
			fi
		fi
		sleep 5
	done

	# Cleanup and final verification
	kill $LOAD_PID 2>/dev/null || true
	final_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
	total_txs=$((final_nonce - initial_nonce))

	if [ "$synced_successfully" = true ]; then
		echo "✅ Fastforward sync test PASSED - Gap: $blocks_gap blocks, Txs: $total_txs"
		return 0
	else
		echo "❌ Fastforward sync test FAILED - Validator didn't sync within ${sync_timeout}s"
		return 1
	fi
}

# Run all tests
test_block_hash_consensus || exit 1
test_post_veblop_hf_behavior || exit 1
test_milestone_settlement_latency_resilience || exit 1
test_extreme_network_latency_recovery || exit 1
test_load_with_rotation || exit 1
test_erigon_node_sync || exit 1
test_fastforward_sync || exit 1

# Run bridge test
setup_pos_env
test_bridge_l1_to_l2 || exit 1

echo ""
echo "✅ All stateless sync tests passed"
