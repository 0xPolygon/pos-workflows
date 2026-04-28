#!/bin/bash
# Bridge tests: plasma bridge (MATIC/POL/ERC20/ERC721) and pos-bridge (ETH/ERC20).

BRIDGE_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BRIDGE_UTILS_DIR/pos_test_utils.sh"

# Bridge MATIC, POL, ERC20, and ERC721 from L1 to L2 via the plasma bridge (DepositManager)
# and verify state syncs land on Heimdall + Bor.
# Requires setup_pos_env() to have been called first.
test_bridge_l1_to_l2() {
	echo ""
	echo "Starting L1->L2 plasma bridge test (MATIC + POL + ERC20 + ERC721)..."

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

	# Bridge MATIC.
	echo "Bridging MATIC..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_MATIC_TOKEN_ADDRESS}" "approve(address,uint)" "${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "${bridge_amount}"
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "depositERC20(address,uint)" "${L1_MATIC_TOKEN_ADDRESS}" "${bridge_amount}"

	# Bridge POL. After the MATIC->POL migration, POL is mapped to the L2 native gas token,
	# so the deposit increases the depositor's L2 native balance just like MATIC does.
	echo "Bridging POL..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_POL_TOKEN_ADDRESS}" "approve(address,uint)" "${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "${bridge_amount}"
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}" "depositERC20(address,uint)" "${L1_POL_TOKEN_ADDRESS}" "${bridge_amount}"

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
	echo "Waiting for Heimdall event records to increase by 4..."
	_assert_cmd_eventually_gte "${heimdall_cmd}" $((heimdall_count + 4)) "${timeout}" "${interval}"

	echo ""
	echo "Waiting for Bor lastStateId to increase by 4..."
	_assert_cmd_eventually_gte "${bor_cmd}" $((bor_count + 4)) "${timeout}" "${interval}"

	# Verify ERC721 arrived on L2.
	echo ""
	echo "Verifying L2 ERC721 balance increased..."
	_assert_token_balance_gte "${L2_ERC721_TOKEN_ADDRESS}" "${address}" $((initial_l2_erc721 + 1)) "${L2_RPC_URL}" "${timeout}" "${interval}"
}

# Bridge ETH and ERC20 from L1 to L2 via the pos-bridge (RootChainManager + ChildChainManager)
# and verify state syncs and L2 balances. Mirrors the mainnet pos-portal flow.
# Requires setup_pos_env() to have been called first.
test_pos_bridge_l1_to_l2() {
	echo ""
	echo "Starting L1->L2 pos-bridge test (ETH + ERC20)..."

	local timeout="$POS_TEST_TIMEOUT"
	local interval="$POS_TEST_INTERVAL"

	local heimdall_count bor_count
	local heimdall_cmd='curl -s "${L2_CL_API_URL}/clerk/event-records/count" | jq -r ".count"'
	local bor_cmd='cast call --gas-limit 15000000 --rpc-url "${L2_RPC_URL}" "${L2_STATE_RECEIVER_ADDRESS}" "lastStateId()(uint)"'
	heimdall_count=$(eval "${heimdall_cmd}")
	bor_count=$(eval "${bor_cmd}")
	echo "Initial state sync counts: heimdall=${heimdall_count} bor=${bor_count}"

	local bridge_amount address
	bridge_amount=$(cast to-unit 1ether wei)
	address=$(cast wallet address --private-key "${PRIVATE_KEY}")

	local initial_l2_weth initial_l2_dummy_erc20
	initial_l2_weth=$(cast call --rpc-url "${L2_RPC_URL}" --json "${L2_MATIC_WETH}" "balanceOf(address)(uint)" "${address}" | jq --raw-output '.[0]')
	initial_l2_dummy_erc20=$(cast call --rpc-url "${L2_RPC_URL}" --json "${L2_DUMMY_ERC20}" "balanceOf(address)(uint)" "${address}" | jq --raw-output '.[0]')
	echo "Initial L2 MaticWETH: ${initial_l2_weth}"
	echo "Initial L2 DummyERC20: ${initial_l2_dummy_erc20}"

	# Bridge ETH via RootChainManager.depositEtherFor — the EtherPredicate locks ETH on L1
	# and ChildChainManager mints MaticWETH on L2 to the depositor.
	echo "Bridging ETH via RootChainManager.depositEtherFor..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" --value "${bridge_amount}" \
		"${L1_ROOT_CHAIN_MANAGER_PROXY}" "depositEtherFor(address)" "${address}"

	# Bridge DummyERC20 via RootChainManager.depositFor. depositData for ERC20 is abi.encode(amount).
	echo "Minting DummyERC20 to deployer..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_DUMMY_ERC20}" "mint(uint256)" "${bridge_amount}"

	echo "Approving ERC20Predicate to spend DummyERC20..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_DUMMY_ERC20}" "approve(address,uint)" "${L1_ERC20_BRIDGE_PREDICATE_PROXY}" "${bridge_amount}"

	local deposit_data
	deposit_data=$(cast abi-encode "f(uint256)" "${bridge_amount}")
	echo "Bridging DummyERC20 via RootChainManager.depositFor..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_ROOT_CHAIN_MANAGER_PROXY}" "depositFor(address,address,bytes)" \
		"${address}" "${L1_DUMMY_ERC20}" "${deposit_data}"

	# Each pos-bridge deposit triggers one state sync (RootChainManager -> ChildChainManager).
	echo ""
	echo "Waiting for Heimdall event records to increase by 2..."
	_assert_cmd_eventually_gte "${heimdall_cmd}" $((heimdall_count + 2)) "${timeout}" "${interval}"

	echo ""
	echo "Waiting for Bor lastStateId to increase by 2..."
	_assert_cmd_eventually_gte "${bor_cmd}" $((bor_count + 2)) "${timeout}" "${interval}"

	echo ""
	echo "Verifying L2 MaticWETH balance increased by ${bridge_amount}..."
	_assert_token_balance_gte "${L2_MATIC_WETH}" "${address}" "$(echo "${initial_l2_weth} + ${bridge_amount}" | bc)" "${L2_RPC_URL}" "${timeout}" "${interval}"

	echo ""
	echo "Verifying L2 DummyERC20 balance increased by ${bridge_amount}..."
	_assert_token_balance_gte "${L2_DUMMY_ERC20}" "${address}" "$(echo "${initial_l2_dummy_erc20} + ${bridge_amount}" | bc)" "${L2_RPC_URL}" "${timeout}" "${interval}"
}
