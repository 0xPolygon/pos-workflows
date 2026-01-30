#!/bin/bash
# Test 11: EVM opcode and precompile coverage test
# This test exercises all available EVM opcodes and precompiled contracts
# using polycli's LoadTester contract.

test_evm_opcode_coverage() {
	echo ""
	echo "=== Test 11: EVM opcode and precompile coverage test ==="

	# Check polycli availability
	if ! command -v polycli &>/dev/null; then
		echo "⚠️  polycli not found, skipping EVM opcode coverage test"
		return 0
	fi

	# Get RPC URLs - primary and baseline
	first_rpc_service="${RPC_SERVICES[0]}"
	first_rpc_url=$(get_rpc_url "$first_rpc_service")

	# Baseline node for verification
	baseline_service="l2-el-10-bor-heimdall-v2-rpc"
	baseline_rpc_url=$(get_rpc_url "$baseline_service")

	PRIVATE_KEY="0x2a4ae8c4c250917781d38d95dafbb0abe87ae2c9aea02ed7c7524685358e49c2"
	SENDER_ADDR="0x97538585a02A3f1B1297EB9979cE1b34ff953f1E"
	GAS_PRICE="35000000000"

	echo "Primary RPC: $first_rpc_service -> $first_rpc_url"
	echo "Baseline RPC: $baseline_service -> $baseline_rpc_url"

	# Deploy LoadTester contract
	echo ""
	echo "Deploying LoadTester contract..."

	# Get current nonce before deployment to compute contract address
	deploy_nonce=$(cast nonce "$SENDER_ADDR" --rpc-url "$first_rpc_url")
	if ! [[ "$deploy_nonce" =~ ^[0-9]+$ ]]; then
		echo "❌ Failed to get nonce for deployment"
		return 1
	fi
	echo "Deploying with nonce: $deploy_nonce"

	# Deploy the contract
	deploy_output=$(polycli loadtest --rpc-url "$first_rpc_url" \
		--private-key "$PRIVATE_KEY" \
		--verbosity 500 \
		--requests 1 \
		--gas-price "$GAS_PRICE" \
		--mode d 2>&1)

	# Compute the deployed contract address from sender + nonce
	CONTRACT_ADDR=$(cast compute-address "$SENDER_ADDR" --nonce "$deploy_nonce" | grep -oE "0x[a-fA-F0-9]{40}")

	if [ -z "$CONTRACT_ADDR" ]; then
		echo "❌ Failed to compute contract address"
		echo "Deploy output: $deploy_output"
		return 1
	fi

	# Verify contract was deployed by checking code exists
	contract_code=$(cast code "$CONTRACT_ADDR" --rpc-url "$first_rpc_url" 2>/dev/null)
	if [ -z "$contract_code" ] || [ "$contract_code" = "0x" ]; then
		echo "❌ Contract not deployed at expected address: $CONTRACT_ADDR"
		echo "Deploy output: $deploy_output"
		return 1
	fi
	echo "✅ LoadTester deployed at: $CONTRACT_ADDR"

	# Track results
	declare -A tx_hashes # test_name -> tx_hash
	declare -A tx_status # test_name -> status (pending/success/failed)
	failed_tests=()

	#=========================================================================
	# Part 1: Send all EVM opcode transactions (60 total)
	#=========================================================================
	echo ""
	echo "--- Sending EVM Opcode Transactions (60 functions) ---"

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

	# Get current nonce for manual nonce management
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

	#=========================================================================
	# Part 2: Send all precompile transactions (10 total)
	#=========================================================================
	echo ""
	echo "--- Sending Precompile Transactions (10 functions) ---"

	# Define precompile inputs
	MODEXP_INPUT="0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001020305"
	# ECAdd/ECMul use point at infinity (0,0) - valid on BN254
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

	#=========================================================================
	# Part 3: Wait for all transactions to be mined and verify
	#=========================================================================
	echo ""
	echo "--- Waiting for transactions to be mined ---"
	echo "Waiting 15 seconds for transactions to be included in blocks..."
	sleep 15

	echo ""
	echo "--- Verifying transaction receipts ---"
	passed=0
	failed=0

	# Combine all test names
	ALL_TESTS=("${OPCODES[@]}" "testSHA256" "testRipemd160" "testIdentity" "testBlake2f" "testModExp" "testECAdd" "testECMul" "testECPairing" "testECRecover" "testP256Verify")

	for test_name in "${ALL_TESTS[@]}"; do
		if [ "${tx_status[$test_name]}" = "send_failed" ]; then
			echo "❌ $test_name (send failed)"
			failed=$((failed + 1))
			failed_tests+=("$test_name")
			continue
		fi

		tx_hash="${tx_hashes[$test_name]}"

		# Check receipt on primary node
		receipt=$(cast receipt "$tx_hash" --rpc-url "$first_rpc_url" --json 2>/dev/null)
		status=$(echo "$receipt" | jq -r '.status // "0x0"')

		if [ "$status" != "0x1" ]; then
			echo "❌ $test_name (tx reverted: ${tx_hash:0:18}...)"
			failed=$((failed + 1))
			failed_tests+=("$test_name")
			continue
		fi

		# Verify on baseline node
		baseline_receipt=$(cast receipt "$tx_hash" --rpc-url "$baseline_rpc_url" --json 2>/dev/null)
		baseline_status=$(echo "$baseline_receipt" | jq -r '.status // empty')

		if [ "$baseline_status" != "0x1" ]; then
			echo "❌ $test_name (not on baseline: ${tx_hash:0:18}...)"
			failed=$((failed + 1))
			failed_tests+=("$test_name")
			continue
		fi

		echo "✅ $test_name"
		passed=$((passed + 1))
	done

	#=========================================================================
	# Part 3: Final sync verification - ensure baseline is in sync with network
	#=========================================================================
	echo ""
	echo "--- Final Sync Verification ---"
	echo "Verifying baseline node ($baseline_service) is in sync with network..."
	echo "This checks that no 'bad block' errors occurred during opcode execution."

	# Wait for blocks to propagate
	echo "Waiting 10 seconds for block propagation..."
	sleep 10

	# Get reference block from first validator
	REFERENCE_NODE="${VALIDATORS[0]}"
	reference_block=$(get_block_number "$REFERENCE_NODE")

	if ! [[ "$reference_block" =~ ^[0-9]+$ ]] || [ "$reference_block" -le 0 ]; then
		echo "❌ Failed to get reference block number"
		return 1
	fi

	# Use a block slightly behind tip for stability
	test_block=$((reference_block - 3))
	if [ "$test_block" -le 0 ]; then
		test_block=1
	fi

	echo "Checking block hash consensus at block $test_block..."

	# Get reference hash
	reference_hash=$(get_block_hash "$REFERENCE_NODE" "$test_block")
	if [ -z "$reference_hash" ]; then
		echo "❌ Failed to get reference hash from $REFERENCE_NODE"
		return 1
	fi
	echo "Reference hash from $REFERENCE_NODE: $reference_hash"

	# Check baseline node has same hash
	baseline_block=$(get_block_number "$baseline_service")
	if ! [[ "$baseline_block" =~ ^[0-9]+$ ]] || [ "$baseline_block" -lt "$test_block" ]; then
		echo "❌ Baseline node is behind network (block: $baseline_block, expected >= $test_block)"
		echo "   This may indicate a 'bad block' error - check baseline node logs!"
		return 1
	fi

	baseline_hash=$(get_block_hash "$baseline_service" "$test_block")
	if [ -z "$baseline_hash" ]; then
		echo "❌ Failed to get block hash from baseline node"
		return 1
	fi

	if [ "$baseline_hash" != "$reference_hash" ]; then
		echo "❌ Block hash MISMATCH!"
		echo "   Reference ($REFERENCE_NODE): $reference_hash"
		echo "   Baseline ($baseline_service): $baseline_hash"
		echo "   This indicates a consensus failure - possible bad opcode implementation!"
		return 1
	fi

	echo "✅ Baseline hash matches: $baseline_hash"

	# Also verify against other validators for comprehensive check
	sync_failures=0
	for validator in "${VALIDATORS[@]:1}"; do # Skip first (already used as reference)
		val_hash=$(get_block_hash "$validator" "$test_block")
		if [ -n "$val_hash" ] && [ "$val_hash" != "$reference_hash" ]; then
			echo "❌ Hash mismatch on $validator: $val_hash"
			sync_failures=$((sync_failures + 1))
		fi
	done

	if [ $sync_failures -gt 0 ]; then
		echo "❌ Detected $sync_failures sync failures across network"
		return 1
	fi

	echo "✅ All nodes in consensus at block $test_block"

	#=========================================================================
	# Final Results
	#=========================================================================
	total=$((passed + failed))
	echo ""
	echo "=== EVM Opcode & Precompile Coverage Results ==="
	echo "Total tests: $total | Passed: $passed | Failed: $failed"
	echo "Network sync status: All nodes in consensus"

	if [ $failed -gt 0 ]; then
		echo ""
		echo "Failed tests:"
		for t in "${failed_tests[@]}"; do
			echo "  - $t"
		done
		echo "❌ EVM opcode coverage test FAILED"
		return 1
	else
		echo ""
		echo "✅ EVM opcode coverage test PASSED"
		echo "   - All $total opcode/precompile tests executed successfully"
		echo "   - All transactions confirmed and verified on baseline node"
		echo "   - Baseline node remains in sync with network (no bad blocks)"
		return 0
	fi
}
