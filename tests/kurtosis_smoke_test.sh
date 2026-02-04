#!/bin/bash
set -e

# Kurtosis E2E smoke tests.

ENCLAVE_NAME=${ENCLAVE_NAME:-"kurtosis-e2e"}
HEIMDALL_SERVICE_NAME=${HEIMDALL_SERVICE_NAME:-"l2-cl-1-heimdall-v2-bor-validator"}

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

test_checkpoints() {
	echo "Starting checkpoints test…"

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
			echo "✅ Checkpoint created! ID: $checkpointID"
			return 0
		else
			echo "Current checkpoint: none (polling… attempt $((attempt + 1))/$max_attempts)"
			sleep 5
			((attempt++))
		fi
	done

	echo "❌ Timeout: No checkpoint created after $((max_attempts * 5)) seconds"
	return 1
}

test_milestones() {
	echo "Starting milestones test…"

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
			echo "✅ Milestones target reached! Current count: $current_count (increased by $((current_count - initial_count)))"
			return 0
		else
			echo "Current milestones count: $current_count (need $((target_count - current_count)) more, polling… attempt $((attempt + 1))/$max_attempts)"
			sleep 5
			((attempt++))
		fi
	done

	echo "❌ Timeout: Only $((current_count - initial_count)) milestones created in 100 seconds (expected 10)"
	return 1
}

# EVM opcode and precompile coverage test
# Tests all EVM opcodes and precompiled contracts using polycli's LoadTester contract
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

	PRIVATE_KEY="0x2a4ae8c4c250917781d38d95dafbb0abe87ae2c9aea02ed7c7524685358e49c2"
	SENDER_ADDR="0x97538585a02A3f1B1297EB9979cE1b34ff953f1E"
	GAS_PRICE="35000000000"

	echo "Primary RPC: $first_rpc_service -> $first_rpc_url"
	echo "Baseline RPC: $BASELINE_SERVICE -> $baseline_rpc_url"

	# Deploy LoadTester contract
	echo ""
	echo "Deploying LoadTester contract..."

	deploy_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$first_rpc_url")
	if ! [[ "$deploy_nonce" =~ ^[0-9]+$ ]]; then
		echo "❌ Failed to get nonce for deployment"
		return 1
	fi
	echo "Deploying with nonce: $deploy_nonce"

	if ! polycli loadtest --rpc-url "$first_rpc_url" \
		--private-key "$PRIVATE_KEY" \
		--verbosity 500 \
		--requests 1 \
		--gas-price "$GAS_PRICE" \
		--mode d 2>&1; then
		echo "❌ polycli loadtest failed"
		return 1
	fi

	CONTRACT_ADDR=$(cast compute-address "$SENDER_ADDR" --nonce "$deploy_nonce" | grep -oE "0x[a-fA-F0-9]{40}")

	if [ -z "$CONTRACT_ADDR" ]; then
		echo "❌ Failed to compute contract address"
		return 1
	fi

	contract_code=$(cast code "$CONTRACT_ADDR" --rpc-url "$first_rpc_url" 2>/dev/null)
	if [ -z "$contract_code" ] || [ "$contract_code" = "0x" ]; then
		echo "❌ Contract not deployed at expected address: $CONTRACT_ADDR"
		return 1
	fi
	echo "✅ LoadTester deployed at: $CONTRACT_ADDR"

	# Track results
	declare -A tx_hashes
	declare -A tx_status
	failed_tests=()

	# EVM opcodes (60 total)
	echo ""
	echo "Sending EVM opcode transactions (60 functions)..."

	OPCODES=(
		"testADD" "testMUL" "testSUB" "testDIV" "testSDIV"
		"testMOD" "testSMOD" "testADDMOD" "testMULMOD" "testEXP"
		"testSIGNEXTEND" "testLT" "testGT" "testSLT" "testSGT"
		"testEQ" "testISZERO" "testAND" "testOR" "testXOR"
		"testNOT" "testBYTE" "testSHL" "testSHR" "testSAR"
		"testSHA3" "testADDRESS" "testBALANCE" "testORIGIN" "testCALLER"
		"testCALLVALUE" "testCALLDATALOAD" "testCALLDATASIZE" "testCALLDATACOPY"
		"testCODESIZE" "testCODECOPY" "testGASPRICE" "testEXTCODESIZE"
		"testRETURNDATASIZE" "testBLOCKHASH" "testCOINBASE" "testTIMESTAMP"
		"testNUMBER" "testDIFFICULTY" "testGASLIMIT" "testCHAINID"
		"testSELFBALANCE" "testBASEFEE" "testMLOAD" "testMSTORE"
		"testMSTORE8" "testSLOAD" "testSSTORE" "testMSIZE" "testGAS"
		"testLOG0" "testLOG1" "testLOG2" "testLOG3" "testLOG4"
	)

	current_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$first_rpc_url")
	sent_count=0

	for opcode in "${OPCODES[@]}"; do
		tx_hash=$(cast send "$CONTRACT_ADDR" "${opcode}(uint256)" 10 \
			--rpc-url "$first_rpc_url" \
			--private-key "$PRIVATE_KEY" \
			--gas-price "$GAS_PRICE" \
			--nonce "$current_nonce" \
			--legacy \
			--async 2>/dev/null)

		if [[ "$tx_hash" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
			tx_hashes["$opcode"]="$tx_hash"
			tx_status["$opcode"]="pending"
			sent_count=$((sent_count + 1))
			current_nonce=$((current_nonce + 1))
		else
			tx_status["$opcode"]="send_failed"
		fi
	done
	echo "Sent $sent_count/60 opcode transactions"

	# Precompiles (10 total)
	echo ""
	echo "Sending precompile transactions (10 functions)..."

	MODEXP_INPUT="0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001020305"
	ECADD_INPUT="0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
	ECMUL_INPUT="0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002"
	ECRECOVER_INPUT="0x456e9aea5e197a1f1af7a3e85a3212fa4049a3ba34c2289b4c860fc0b0c64ef3000000000000000000000000000000000000000000000000000000000000001c9242685bf161793cc25603c231bc2f568eb630ea16aa137d2664ac80388256084f8ae3bd7535248d0bd448298cc2e2071e56992d0774dc340c368ae950852ada"
	P256_INPUT="0x4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4da73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d604aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff37618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e"

	declare -A PRECOMPILES=(
		["testSHA256"]="testSHA256(bytes)|0xdeadbeef"
		["testRipemd160"]="testRipemd160(bytes)|0xdeadbeef"
		["testIdentity"]="testIdentity(bytes)|0xdeadbeef"
		["testBlake2f"]="testBlake2f(bytes)|0x"
		["testModExp"]="testModExp(bytes)|$MODEXP_INPUT"
		["testECAdd"]="testECAdd(bytes)|$ECADD_INPUT"
		["testECMul"]="testECMul(bytes)|$ECMUL_INPUT"
		["testECPairing"]="testECPairing(bytes)|0x"
		["testECRecover"]="testECRecover(bytes)|$ECRECOVER_INPUT"
		["testP256Verify"]="testP256Verify(bytes)|$P256_INPUT"
	)

	precompile_sent=0
	for name in testSHA256 testRipemd160 testIdentity testBlake2f testModExp testECAdd testECMul testECPairing testECRecover testP256Verify; do
		IFS='|' read -r sig args <<<"${PRECOMPILES[$name]}"
		tx_hash=$(cast send "$CONTRACT_ADDR" "$sig" $args \
			--rpc-url "$first_rpc_url" \
			--private-key "$PRIVATE_KEY" \
			--gas-price "$GAS_PRICE" \
			--nonce "$current_nonce" \
			--legacy \
			--async 2>/dev/null)

		if [[ "$tx_hash" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
			tx_hashes["$name"]="$tx_hash"
			tx_status["$name"]="pending"
			precompile_sent=$((precompile_sent + 1))
			current_nonce=$((current_nonce + 1))
		else
			tx_status["$name"]="send_failed"
		fi
	done
	echo "Sent $precompile_sent/10 precompile transactions"

	# Wait and verify
	echo ""
	echo "Waiting for transactions to be mined..."
	sleep 15

	echo ""
	echo "Verifying transaction receipts..."
	passed=0
	failed=0

	ALL_TESTS=("${OPCODES[@]}" "testSHA256" "testRipemd160" "testIdentity" "testBlake2f" "testModExp" "testECAdd" "testECMul" "testECPairing" "testECRecover" "testP256Verify")

	for test_name in "${ALL_TESTS[@]}"; do
		if [ "${tx_status[$test_name]}" = "send_failed" ]; then
			echo "❌ $test_name (send failed)"
			failed=$((failed + 1))
			failed_tests+=("$test_name")
			continue
		fi

		tx_hash="${tx_hashes[$test_name]}"
		receipt=$(cast receipt "$tx_hash" --rpc-url "$first_rpc_url" --json 2>/dev/null)
		status=$(echo "$receipt" | jq -r '.status // "0x0"')

		if [ "$status" != "0x1" ]; then
			echo "❌ $test_name (tx reverted)"
			failed=$((failed + 1))
			failed_tests+=("$test_name")
			continue
		fi

		baseline_receipt=$(cast receipt "$tx_hash" --rpc-url "$baseline_rpc_url" --json 2>/dev/null)
		baseline_status=$(echo "$baseline_receipt" | jq -r '.status // empty')

		if [ "$baseline_status" != "0x1" ]; then
			echo "❌ $test_name (not on baseline)"
			failed=$((failed + 1))
			failed_tests+=("$test_name")
			continue
		fi

		echo "✅ $test_name"
		passed=$((passed + 1))
	done

	# Final sync verification
	echo ""
	echo "Final sync verification..."
	sleep 10

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
	echo "✅ Baseline node in sync at block $test_block"

	# Results
	total=$((passed + failed))
	echo ""
	echo "EVM opcode and precompile coverage results:"
	echo "Total: $total | Passed: $passed | Failed: $failed"

	if [ $failed -gt 0 ]; then
		echo "❌ EVM opcode coverage test FAILED"
		return 1
	fi

	echo "✅ EVM opcode coverage test PASSED"
	return 0
}

main() {
	echo "Starting kurtosis smoke tests"
	echo "Enclave: $ENCLAVE_NAME"
	echo "Service: $HEIMDALL_SERVICE_NAME"
	echo ""

	if ! test_checkpoints; then
		echo "❌ Checkpoints test failed"
		exit 1
	fi
	echo "✅ Checkpoints test passed — Heimdall checkpoints are being created!"
	echo ""

	if ! test_milestones; then
		echo "❌ Milestones test failed"
		exit 1
	fi
	echo "✅ Milestones test passed — Heimdall milestones are being created!"
	echo ""

	if ! test_evm_opcode_coverage; then
		echo "❌ EVM opcode coverage test failed"
		exit 1
	fi
	echo ""

	echo "✅ All kurtosis smoke tests completed successfully!"
	exit 0
}

main "$@"
