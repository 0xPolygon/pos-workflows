#!/bin/bash
# Bridge test: MATIC/POL + ERC20 + ERC721 from L1 to L2.

BRIDGE_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BRIDGE_UTILS_DIR/pos_test_utils.sh"

# Bridge MATIC/POL, ERC20, and ERC721 from L1 to L2 and verify state syncs.
# Requires setup_pos_env() to have been called first.
test_bridge_l1_to_l2() {
	echo ""
	echo "Starting L1->L2 bridge test (MATIC/POL + ERC20 + ERC721)..."

	local timeout="$POS_TEST_TIMEOUT"
	local interval="$POS_TEST_INTERVAL"

	# State sync counts before bridging.
	local heimdall_count bor_count
	local heimdall_cmd='curl -s "${L2_CL_API_URL}/clerk/event-records/count" | jq -r ".count"'
	local bor_cmd='cast call --gas-limit 15000000 --rpc-url "${L2_RPC_URL}" "${L2_STATE_RECEIVER_ADDRESS}" "lastStateId()(uint)"'
	heimdall_count=$(eval "${heimdall_cmd}")
	bor_count=$(eval "${bor_cmd}")
	echo "Initial state sync counts: heimdall=${heimdall_count} bor=${bor_count}"

	local bridge_amount
	bridge_amount=$(cast to-unit 1ether wei)

	# Mint ERC721.
	local total_supply token_id
	total_supply=$(cast call --rpc-url "${L1_RPC_URL}" --json "${L1_ERC721_TOKEN_ADDRESS}" "totalSupply()(uint)" | jq --raw-output '.[0]')
	token_id=$((total_supply + 1))

	local address
	address=$(cast wallet address --private-key "${PRIVATE_KEY}")
	local initial_l2_erc721
	initial_l2_erc721=$(cast call --rpc-url "${L2_RPC_URL}" --json "${L2_ERC721_TOKEN_ADDRESS}" "balanceOf(address)(uint)" "${address}" | jq --raw-output '.[0]')

	echo "Minting ERC721 token (id: ${token_id})..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_ERC721_TOKEN_ADDRESS}" "mint(uint)" "${token_id}"

	# Bridge MATIC/POL.
	echo "Bridging MATIC/POL..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_MATIC_TOKEN_ADDRESS}" "approve(address,uint)" "${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "${bridge_amount}"
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "depositERC20(address,uint)" "${L1_MATIC_TOKEN_ADDRESS}" "${bridge_amount}"

	# Bridge ERC20.
	echo "Bridging ERC20..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_ERC20_TOKEN_ADDRESS}" "approve(address,uint)" "${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "${bridge_amount}"
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "depositERC20(address,uint)" "${L1_ERC20_TOKEN_ADDRESS}" "${bridge_amount}"

	# Bridge ERC721.
	echo "Bridging ERC721 (id: ${token_id})..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_ERC721_TOKEN_ADDRESS}" "approve(address,uint)" "${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "${token_id}"
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "depositERC721(address,uint)" "${L1_ERC721_TOKEN_ADDRESS}" "${token_id}"

	# Verify state syncs processed by Heimdall and Bor.
	echo ""
	echo "Waiting for Heimdall event records to increase by 3..."
	_assert_cmd_eventually_gte "${heimdall_cmd}" $((heimdall_count + 3)) "${timeout}" "${interval}"

	echo ""
	echo "Waiting for Bor lastStateId to increase by 3..."
	_assert_cmd_eventually_gte "${bor_cmd}" $((bor_count + 3)) "${timeout}" "${interval}"

	# Verify ERC721 arrived on L2.
	echo ""
	echo "Verifying L2 ERC721 balance increased..."
	_assert_token_balance_gte "${L2_ERC721_TOKEN_ADDRESS}" "${address}" $((initial_l2_erc721 + 1)) "${L2_RPC_URL}" "${timeout}" "${interval}"
}
