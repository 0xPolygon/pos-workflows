#!/bin/bash
# Plasma bridge test: POL + ERC20 + ERC721 from L1 to L2.

BRIDGE_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BRIDGE_UTILS_DIR/pos_test_utils.sh"

# Uburu state-sync gas oracle (mainnet address). The Uburu StateReceiver gives each
# record at most gasLimit() gas (160000), and minting the child ERC721 needs more,
# so the devnet admin raises it around the deposits and restores it afterwards.
STATE_SYNC_GAS_ORACLE="0x5e3a5eafd4501332c0bc2acfd38df3ebc5152147"
STATE_SYNC_GAS_LIMIT_RAISED=500000

_set_state_sync_gas_limit() {
  cast send --rpc-url "${L2_RPC_URL}" --private-key "${PRIVATE_KEY}" --legacy \
    "${STATE_SYNC_GAS_ORACLE}" "setGasLimit(uint256)" "$1" > /dev/null
}

# Bridge POL, ERC20, and ERC721 from L1 to L2 via the plasma bridge (DepositManager)
# and verify state syncs land on Heimdall + Bor.
# Requires setup_pos_env() to have been called first.
test_bridge_l1_to_l2() {
  local gas_limit rc=0
  gas_limit=$(cast call --rpc-url "${L2_RPC_URL}" "${STATE_SYNC_GAS_ORACLE}" "gasLimit()(uint256)" | awk '{print $1}')
  if [[ ! "${gas_limit}" =~ ^[0-9]+$ ]] || ! _set_state_sync_gas_limit "${STATE_SYNC_GAS_LIMIT_RAISED}"; then
    echo "Failed to raise the state-sync gas limit on ${STATE_SYNC_GAS_ORACLE}"
    return 1
  fi
  _bridge_l1_to_l2 || rc=$?
  _set_state_sync_gas_limit "${gas_limit}" || rc=1
  return "${rc}"
}

_bridge_l1_to_l2() {
  echo ""
  echo "Starting L1->L2 plasma bridge test (POL + ERC20 + ERC721)..."

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
  total_supply=$(cast call --rpc-url "${L1_RPC_URL}" --json "${L1_ERC721_TOKEN_ADDRESS}" "totalSupply()(uint)" | jq --raw-output '(.data? // .)[0]')
  token_id=$((total_supply + 1))

  local address
  address=$(cast wallet address --private-key "${PRIVATE_KEY}")
  local initial_l2_erc721
  initial_l2_erc721=$(cast call --rpc-url "${L2_RPC_URL}" --json "${L2_ERC721_TOKEN_ADDRESS}" "balanceOf(address)(uint)" "${address}" | jq --raw-output '(.data? // .)[0]')

  echo "Minting ERC721 token (id: ${token_id})..."
  cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
    "${L1_ERC721_TOKEN_ADDRESS}" "mint(uint)" "${token_id}"

  # Bridge POL. After the MATIC->POL migration, POL is mapped to the L2 native gas token,
  # so the deposit increases the depositor's L2 native balance.
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
