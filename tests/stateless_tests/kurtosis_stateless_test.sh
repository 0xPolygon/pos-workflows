#!/bin/bash
set -e

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/kurtosis_test_utils.sh"

echo "Starting stateless sync tests..."

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
	echo "=== Test 1: Checking all the nodes reach block $TARGET_BLOCK and have the same block hash ==="

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

		# Check all services (stateless_sync validators + legacy validators + RPC)
		ALL_TEST_SERVICES=("${STATELESS_SYNC_VALIDATORS[@]}" "${LEGACY_VALIDATORS[@]}" "${STATELESS_RPC_SERVICES[@]}")

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
	echo "=== Test 2: Checking post-veblop HF behavior (after block $TARGET_BLOCK_HF) ==="
	echo "Waiting for block $TARGET_BLOCK_POST_HF to ensure we're past veblop HF..."

	while true; do
		current_time=$SECONDS
		elapsed=$((current_time - start_time))

		# Timeout check
		if [ $elapsed -gt $TEST_TIMEOUT_SECONDS ]; then
			echo "Timeout waiting for post-HF block $TARGET_BLOCK_POST_HF (after ${TEST_TIMEOUT_SECONDS}s)"
			return 1
		fi

		# Check stateless_sync services (should continue syncing after HF)
		max_stateless_block=0
		for service in "${STATELESS_SYNC_VALIDATORS[@]}" "${STATELESS_RPC_SERVICES[@]}"; do
			block_num=$(get_block_number $service)
			if [[ "$block_num" =~ ^[0-9]+$ ]] && [ $block_num -gt $max_stateless_block ]; then
				max_stateless_block=$block_num
			fi
		done

		# Check legacy services (might stop syncing after HF)
		max_legacy_block=0
		for service in "${LEGACY_VALIDATORS[@]}"; do
			block_num=$(get_block_number $service)
			if [[ "$block_num" =~ ^[0-9]+$ ]] && [ $block_num -gt $max_legacy_block ]; then
				max_legacy_block=$block_num
			fi
		done

		echo "Current stateless_sync max block: $max_stateless_block"
		echo "Current legacy max block: $max_legacy_block"

		if [ $max_stateless_block -ge $TARGET_BLOCK_POST_HF ]; then
			echo "✅ Stateless sync nodes continued syncing past veblop HF"

			# Check if legacy nodes stopped progressing
			if [ $max_legacy_block -lt $TARGET_BLOCK_HF ]; then
				echo "✅ Legacy nodes appropriately stopped syncing after veblop HF (at block $max_legacy_block)"
			else
				echo "⚠️  Legacy nodes are still running (at block $max_legacy_block) - forked off from stateless sync validators"
			fi

			# Check block hash consensus for stateless sync services at block TARGET_BLOCK_POST_HF
			echo "Checking block hash consensus for stateless sync services at block $TARGET_BLOCK_POST_HF..."

			# Only check stateless sync validators and RPC services (not legacy validators).
			STATELESS_SERVICES=("${STATELESS_SYNC_VALIDATORS[@]}" "${STATELESS_RPC_SERVICES[@]}")

			# Get block hash for block TARGET_BLOCK_POST_HF from all stateless sync services
			block_hashes=()
			reference_hash=""
			hash_mismatch=false

			for service in "${STATELESS_SERVICES[@]}"; do
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
				echo "✅ All stateless sync services have the same hash for block $TARGET_BLOCK_POST_HF: $reference_hash"
			fi

			break
		fi

		sleep $SLEEP_INTERVAL
	done
}

# Test 3: Check milestone settlement latency without network latency
test_baseline_milestone_settlement_latency() {
	echo ""
	echo "=== Test 3: Checking baseline milestone settlement latency ==="

	if ! test_milestone_settlement_latency "baseline (no network latency)" "$LATENCY_CHECK_ITERATIONS" "$NORMAL_SETTLEMENT_LATENCY_SECONDS"; then
		return 1
	fi
}

# Test 4: Network latency test
test_network_latency_resilience() {
	echo ""
	echo "=== Test 4: Network latency resilience test ==="

	# Set up cleanup trap to ensure network latency is stopped
	cleanup_network_latency() {
		echo "Cleaning up network latency..."
		wait_for_pending_network_latency
	}
	trap cleanup_network_latency EXIT

	# Start network latency in background with explicit parameters
	if ! start_network_latency "$DELAY_EL" "$JITTER_EL" "$DELAY_CL" "$JITTER_CL" "$NETWORK_LATENCY_DURATION"; then
		echo "❌ Failed to start network latency, skipping network latency test"
		return 1
	fi

	# Wait a bit for network latency to take effect
	echo "Waiting 10 seconds for network latency to stabilize..."
	sleep 10

	# Test milestone settlement latency with network latency applied
	echo "Testing milestone settlement latency with network latency applied..."
	if ! test_milestone_settlement_latency "with network latency" "$LATENCY_CHECK_ITERATIONS" "$MAX_SETTLEMENT_LATENCY_SECONDS"; then
		echo "❌ Network latency test failed - settlement latency exceeded threshold"
		return 1
	fi

	# Wait for network latency to complete
	wait_for_pending_network_latency

	echo "✅ Network latency test passed - milestone settlement latency remained acceptable despite network delays"
}

# Test 5: Extreme network latency recovery test
test_extreme_network_latency_recovery() {
	echo ""
	echo "=== Test 5: Extreme network latency recovery test ==="

	# Get initial block numbers before applying extreme latency
	echo "Recording initial block numbers before extreme latency..."
	initial_max_block=$(get_max_block_from_services "${STATELESS_SYNC_VALIDATORS[@]}" "${STATELESS_RPC_SERVICES[@]}")
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

# Test 6: Block producer rotation test
test_block_producer_rotation() {
	echo ""
	echo "=== Test 6: Block producer rotation test ==="

	# Get stateless node 7 for reorg monitoring (l2-el-7-bor-heimdall-v2-validator)
	STATELESS_NODE_7="l2-el-7-bor-heimdall-v2-validator"
	echo "Monitoring stateless node 7: $STATELESS_NODE_7"

	# Check initial reorg count
	initial_reorg_count=$(get_reorg_count "$STATELESS_NODE_7")
	echo "Initial reorg count for $STATELESS_NODE_7: $initial_reorg_count"

	# Run the rotation script 3 times with 15 second intervals
	for rotation_round in {1..3}; do
		echo ""
		echo "--- Rotation round $rotation_round/3 ---"

		# Run the rotation script
		echo "Running block producer rotation script (15 seconds)..."
		"$SCRIPT_DIR/rotate_current_block_producer.sh"

		echo "Rotation script completed. Waiting 15 seconds before next round..."
		sleep 15
	done

	echo ""
	echo "All 3 rotation rounds completed. Analyzing results..."

	# Wait a bit for blocks to stabilize after rotations
	echo "Waiting 10 seconds for blocks to stabilize..."
	sleep 10

	# Check block author diversity in last 100 blocks
	echo ""
	echo "Checking block author diversity..."
	if ! check_block_author_diversity "$STATELESS_NODE_7" 100 2; then
		echo "❌ Block producer rotation test failed - insufficient author diversity"
		return 1
	fi

	# Check that stateless node 7 didn't have reorgs during rotation
	echo ""
	echo "Checking reorg count after rotation..."
	final_reorg_count=$(get_reorg_count "$STATELESS_NODE_7")
	echo "Final reorg count for $STATELESS_NODE_7: $final_reorg_count"

	if [[ "$initial_reorg_count" =~ ^[0-9]+$ ]] && [[ "$final_reorg_count" =~ ^[0-9]+$ ]]; then
		reorg_diff=$((final_reorg_count - initial_reorg_count))
		echo "Reorg count difference: $reorg_diff"

		if [ "$reorg_diff" -eq 0 ]; then
			echo "✅ No reorgs detected on stateless node 7 during block producer rotation"
		else
			echo "❌ Detected $reorg_diff reorgs on stateless node 7 during rotation (expected: 0)"
			return 1
		fi
	else
		echo "❌ Failed to parse reorg counts (initial: $initial_reorg_count, final: $final_reorg_count)"
		return 1
	fi

	echo "✅ Block producer rotation test passed - authors rotated successfully with no reorgs on stateless nodes"
}

# Test 7: Load test with polycli
test_polycli_load_test() {
	echo ""
	echo "=== Test 7: Load test with polycli ==="

	polycli_bin=$(which polycli)
	first_rpc_service="${STATELESS_RPC_SERVICES[0]}"
	first_rpc_url=$(get_rpc_url "$first_rpc_service")
	echo "Using RPC service: $first_rpc_service -> $first_rpc_url"

	# Check initial nonce
	test_account="0x97538585a02A3f1B1297EB9979cE1b34ff953f1E"
	num_txs=1000
	initial_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
	echo "Initial nonce for account $test_account: $initial_nonce"

	# Run load test
	$polycli_bin loadtest --rpc-url "$first_rpc_url" --private-key "0x2a4ae8c4c250917781d38d95dafbb0abe87ae2c9aea02ed7c7524685358e49c2" --verbosity 500 --requests $num_txs --rate-limit 500 --mode uniswapv3 --gas-price 35000000000

	# Check final nonce after load test
	final_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
	echo "Final nonce for account $test_account: $final_nonce"

	# Calculate nonce difference to verify transactions processed
	if [[ "$initial_nonce" =~ ^[0-9]+$ ]] && [[ "$final_nonce" =~ ^[0-9]+$ ]]; then
		nonce_diff=$((final_nonce - initial_nonce))
		echo "Transactions processed: $nonce_diff (nonce increased from $initial_nonce to $final_nonce)"

		if [ "$nonce_diff" -gt $num_txs ]; then
			echo "✅ Load test successful - processed $nonce_diff transactions (> $num_txs)"
		else
			echo "❌ Load test failed - only processed $nonce_diff transactions (< $num_txs required)"
			return 1
		fi
	else
		echo "❌ Load test failed - unable to parse nonce values (initial: $initial_nonce, final: $final_nonce)"
		return 1
	fi
}

# Test 8: Combined load test with block producer rotation
test_polycli_load_with_rotation() {
	echo ""
	echo "=== Test 8: Combined load test with block producer rotation ==="
	echo "This test ensures all transactions are mined during producer rotations"

	# Check if polycli is available
	if ! command -v polycli &>/dev/null; then
		echo "⚠️  polycli not found, skipping combined load test"
		return 0
	fi

	polycli_bin=$(which polycli)
	first_rpc_service="${STATELESS_RPC_SERVICES[0]}"
	first_rpc_url=$(get_rpc_url "$first_rpc_service")
	echo "Using RPC service: $first_rpc_service -> $first_rpc_url"

	# Record initial state
	test_account="0x97538585a02A3f1B1297EB9979cE1b34ff953f1E"
	num_txs=6000 # More transactions for longer test
	initial_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")

	echo "Initial account nonce: $initial_nonce"
	echo "Target transactions: $num_txs"

	# Start load test in background
	echo ""
	echo "Starting polycli load test in background with $num_txs transactions..."
	$polycli_bin loadtest \
		--rpc-url "$first_rpc_url" \
		--private-key "0x2a4ae8c4c250917781d38d95dafbb0abe87ae2c9aea02ed7c7524685358e49c2" \
		--verbosity 500 \
		--requests $num_txs \
		--rate-limit 100 \
		--mode t \
		--gas-price 35000000000 >/tmp/polycli_rotation_test.log 2>&1 &

	LOAD_PID=$!
	echo "Load test started with PID: $LOAD_PID"

	# Give load test time to start
	sleep 5

	# Perform rotations while load test is running
	for rotation_round in {1..2}; do
		echo ""
		echo "--- Rotation round $rotation_round/2 ---"

		# Check transaction progress before rotation
		current_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
		txs_mined=$((current_nonce - initial_nonce))
		echo "Before rotation $rotation_round: $txs_mined transactions mined"

		# Perform rotation
		echo "Executing block producer rotation..."
		if ! "$SCRIPT_DIR/rotate_current_block_producer.sh"; then
			echo "⚠️  Rotation script failed, but continuing test..."
		fi

		# Wait after rotation
		echo "Waiting 10 seconds after rotation..."
		sleep 10

		# Check transaction progress after rotation
		post_rotation_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
		txs_during_rotation=$((post_rotation_nonce - current_nonce))
		total_txs_so_far=$((post_rotation_nonce - initial_nonce))

		echo "After rotation $rotation_round:"
		echo "  Transactions mined during rotation: $txs_during_rotation"
		echo "  Total transactions mined so far: $total_txs_so_far / $num_txs"
	done

	# Wait for load test to complete or timeout
	echo ""
	echo "Waiting for load test to complete (max 120 seconds)..."
	WAIT_COUNT=0
	while kill -0 $LOAD_PID 2>/dev/null && [ $WAIT_COUNT -lt 120 ]; do
		sleep 5
		WAIT_COUNT=$((WAIT_COUNT + 5))
		current_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
		txs_so_far=$((current_nonce - initial_nonce))
		echo "  Progress: $txs_so_far/$num_txs transactions mined ($WAIT_COUNT seconds elapsed)"

		# If we've mined enough transactions, we can stop waiting
		if [ $txs_so_far -ge $num_txs ]; then
			echo "  Target transaction count reached, stopping load test..."
			kill $LOAD_PID 2>/dev/null || true
			break
		fi
	done

	# Kill load test if still running
	if kill -0 $LOAD_PID 2>/dev/null; then
		echo "Load test still running after timeout, terminating..."
		kill $LOAD_PID 2>/dev/null || true
	fi

	# Wait a bit for final transactions to settle
	echo "Waiting 10 seconds for final transactions to settle..."
	sleep 10

	# Final verification
	echo ""
	echo "=== Final Verification ==="

	final_nonce=$(cast nonce "$test_account" --rpc-url "$first_rpc_url")
	total_txs_mined=$((final_nonce - initial_nonce))

	echo "Test results:"
	echo "  Initial nonce: $initial_nonce"
	echo "  Final nonce: $final_nonce"
	echo "  Total transactions mined: $total_txs_mined / $num_txs"

	# Check if ALL transactions were mined
	if [ $total_txs_mined -ge $num_txs ]; then
		echo ""
		echo "✅ Combined load test with producer rotation PASSED"
		echo "   All $total_txs_mined transactions were successfully mined during block producer rotations"
		return 0
	else
		echo ""
		echo "❌ Combined load test with producer rotation FAILED"
		echo "   Only $total_txs_mined out of $num_txs transactions were mined"
		echo "   Check /tmp/polycli_rotation_test.log for details"
		return 1
	fi
}

# Test 9: Erigon node sync verification
test_erigon_node_sync() {
	echo ""
	echo "=== Test 9: Verifying Erigon node is in sync with all nodes (except legacy) ==="

	# Get erigon service name
	ERIGON_SERVICE="l2-el-12-erigon-heimdall-v2-rpc"
	echo "Checking sync status of Erigon node: $ERIGON_SERVICE"

	# Build list of nodes to compare against (all except legacy validator)
	SYNC_NODES=("${STATELESS_SYNC_VALIDATORS[@]}" "${STATELESS_RPC_SERVICES[@]}")
	# Remove erigon from the comparison list since we're comparing it against others
	COMPARISON_NODES=()
	for node in "${SYNC_NODES[@]}"; do
		if [[ "$node" != "$ERIGON_SERVICE" ]]; then
			COMPARISON_NODES+=("$node")
		fi
	done

	echo "Comparing Erigon node against ${#COMPARISON_NODES[@]} other nodes (excluding legacy validator)"

	# Use first stateless validator as reference node
	REFERENCE_NODE="${STATELESS_SYNC_VALIDATORS[0]}"
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

	# Also verify that legacy node is NOT in sync (it should have diverged)
	echo ""
	echo "Verifying legacy node divergence..."
	LEGACY_NODE="${LEGACY_VALIDATORS[0]}"
	legacy_hash=$(get_block_hash "$LEGACY_NODE" "$test_block")

	if [ -n "$legacy_hash" ]; then
		if [ "$legacy_hash" = "$reference_hash" ]; then
			echo "⚠️  Legacy node $LEGACY_NODE has same hash as network: $legacy_hash"
			echo "    This might indicate the legacy node hasn't diverged yet, which is acceptable"
		else
			echo "✅ Legacy node $LEGACY_NODE has different hash: $legacy_hash (expected divergence)"
		fi
	else
		echo "⚠️  Could not get hash from legacy node $LEGACY_NODE (possibly stopped syncing)"
	fi

	if [ "$sync_mismatch" = false ]; then
		echo ""
		echo "✅ Erigon node sync test passed - Erigon node is in sync with all non-legacy nodes"
		echo "   Successful comparisons: $successful_comparisons"
		return 0
	else
		echo ""
		echo "❌ Erigon node sync test failed - sync mismatches detected"
		return 1
	fi
}

# Test 10: Fastforward sync verification
test_fastforward_sync() {
	echo ""
	echo "=== Test 10: Verifying fastforward sync functionality on stateless node ==="

	TARGET_VALIDATOR="l2-el-5-bor-heimdall-v2-validator"
	REFERENCE_NODE="${STATELESS_SYNC_VALIDATORS[0]}"
	test_account="0x97538585a02A3f1B1297EB9979cE1b34ff953f1E"
	num_txs=3000

	# Check if polycli is available
	if ! command -v polycli &>/dev/null; then
		echo "⚠️  polycli not found, skipping fastforward sync test"
		return 0
	fi

	first_rpc_url=$(get_rpc_url "${STATELESS_RPC_SERVICES[0]}")
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
		--private-key "0x2a4ae8c4c250917781d38d95dafbb0abe87ae2c9aea02ed7c7524685358e49c2" \
		--verbosity 500 --requests $num_txs --rate-limit 100 --mode uniswapv3 \
		--gas-price 35000000000 >/tmp/polycli_fastforward_test.log 2>&1 &
	LOAD_PID=$!

	# Wait for 120s to create block gap
	echo "Waiting 120s for network to advance (target: >30 blocks gap)..."
	for ((i = 120; i > 0; i -= 10)); do
		sleep 10
		current_block=$(get_block_number "$REFERENCE_NODE")
		echo "  ${i}s remaining... Block: $current_block (+$((current_block - initial_block)) blocks)"
	done

	blocks_gap=$(($(get_block_number "$REFERENCE_NODE") - initial_block))
	echo "Network advanced by $blocks_gap blocks"
	[ "$blocks_gap" -lt 30 ] && echo "⚠️  Gap may be insufficient to trigger fastforward"

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
	echo "Monitoring sync progress (max 120s)..."
	sync_timeout=120
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
test_baseline_milestone_settlement_latency || exit 1
test_network_latency_resilience || exit 1
test_extreme_network_latency_recovery || exit 1
test_block_producer_rotation || exit 1
test_polycli_load_test || exit 1
test_polycli_load_with_rotation || exit 1
test_erigon_node_sync || exit 1
test_fastforward_sync || exit 1

echo ""
echo "🎉 All stateless sync tests passed successfully!"
