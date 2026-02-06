#!/bin/bash
set -e

# Validator lifecycle tests: add, stake update, delegate, undelegate, remove.
# Requires ENCLAVE_NAME env var.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pos_test_utils.sh"

generate_new_keypair() {
	local mnemonic private_key address public_key
	mnemonic=$(cast wallet new-mnemonic --json | jq --raw-output '.mnemonic')
	private_key=$(cast wallet derive-private-key "${mnemonic}" 0)
	address=$(cast wallet address "${private_key}")
	public_key=$(cast wallet public-key --raw-private-key "${private_key}")
	echo "${address} ${public_key} ${private_key}"
}

test_add_validator() {
	echo ""
	echo "Starting add validator test..."

	local validator_count_cmd='curl -s "${L2_CL_API_URL}/stake/validators-set" | jq --raw-output ".validator_set.validators | length"'

	local initial_count
	initial_count=$(eval "${validator_count_cmd}")
	echo "Initial validator count: ${initial_count}"

	echo "Generating new validator keypair..."
	local validator_address validator_public_key validator_private_key
	read validator_address validator_public_key validator_private_key < <(generate_new_keypair)
	echo "Address: ${validator_address}"
	echo "Public key: ${validator_public_key}"

	echo "Funding validator with ETH..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" --value 1ether "${validator_address}"

	echo "Funding validator with MATIC/POL..."
	local deposit_amount heimdall_fee_amount funding_amount
	deposit_amount=$(cast to-unit 1ether wei)
	heimdall_fee_amount=$(cast to-unit 1ether wei)
	funding_amount=$((deposit_amount + heimdall_fee_amount))

	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_MATIC_TOKEN_ADDRESS}" "transfer(address,uint)" "${validator_address}" "${funding_amount}"

	echo "Approving StakeManagerProxy..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${validator_private_key}" \
		"${L1_MATIC_TOKEN_ADDRESS}" "approve(address,uint)" "${L1_STAKE_MANAGER_PROXY_ADDRESS}" "${funding_amount}"

	echo "Staking for new validator..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${validator_private_key}" \
		"${L1_STAKE_MANAGER_PROXY_ADDRESS}" "stakeForPOL(address,uint,uint,bool,bytes)" \
		"${validator_address}" "${deposit_amount}" "${heimdall_fee_amount}" "false" "${validator_public_key}"

	echo "Waiting for validator count to increase..."
	_assert_cmd_eventually_equal "${validator_count_cmd}" $((initial_count + 1)) 180

	echo "✅ Add validator test passed"
}

test_update_validator_stake() {
	echo ""
	echo "Starting update validator stake test..."

	local validator_private_key=${VALIDATOR_PRIVATE_KEY:-"0x2a4ae8c4c250917781d38d95dafbb0abe87ae2c9aea02ed7c7524685358e49c2"}
	local validator_id=${VALIDATOR_ID:-"1"}
	local validator_power_cmd='curl -s "${L2_CL_API_URL}/stake/validator/'"${validator_id}"'" | jq --raw-output ".validator.voting_power"'

	local validator_address
	validator_address=$(cast wallet address --private-key "${validator_private_key}")
	echo "Validator ${validator_id} address: ${validator_address}"

	local initial_power
	initial_power=$(eval "${validator_power_cmd}")
	echo "Initial voting power: ${initial_power}"

	local stake_amount
	stake_amount=$(cast to-unit 1ether wei)

	echo "Funding validator with MATIC/POL..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_MATIC_TOKEN_ADDRESS}" "transfer(address,uint)" "${validator_address}" "${stake_amount}"

	echo "Approving StakeManagerProxy..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${validator_private_key}" \
		"${L1_MATIC_TOKEN_ADDRESS}" "approve(address,uint)" "${L1_STAKE_MANAGER_PROXY_ADDRESS}" "${stake_amount}"

	echo "Restaking..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${validator_private_key}" \
		"${L1_STAKE_MANAGER_PROXY_ADDRESS}" "restakePOL(uint,uint,bool)" "${validator_id}" "${stake_amount}" "false"

	local power_update
	power_update=$(cast to-unit "${stake_amount}"wei ether)
	echo "Waiting for voting power to increase by ${power_update}..."
	_assert_cmd_eventually_equal "${validator_power_cmd}" $((initial_power + power_update)) 180

	echo "✅ Update validator stake test passed"
}

test_delegate() {
	echo ""
	echo "Starting delegate test..."

	local validator_id=${VALIDATOR_ID:-"1"}
	local delegator_private_key="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
	local delegator_address="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
	echo "Validator ID: ${validator_id}"
	echo "Delegator: ${delegator_address}"

	# Get ValidatorShare contract.
	local validator_share_address
	validator_share_address=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${L1_STAKING_INFO_ADDRESS}" "getValidatorContractAddress(uint)(address)" "${validator_id}")
	echo "ValidatorShare: ${validator_share_address}"

	# Check delegation enabled.
	local accepts_delegation
	accepts_delegation=$(cast call --rpc-url "${L1_RPC_URL}" "${validator_share_address}" "delegation()(bool)")
	if [[ "${accepts_delegation}" != "true" ]]; then
		echo "⚠️  Validator does not accept delegation, skipping"
		return 0
	fi

	# Initial stakes.
	local initial_total_stake initial_delegator_stake
	initial_total_stake=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${L1_STAKING_INFO_ADDRESS}" "totalValidatorStake(uint)(uint)" "${validator_id}" | cut -d' ' -f1)
	initial_delegator_stake=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${validator_share_address}" "getTotalStake(address)(uint,uint)" "${delegator_address}" | head -1 | cut -d' ' -f1)
	echo "Initial total stake: ${initial_total_stake}"
	echo "Initial delegator stake: ${initial_delegator_stake}"

	local delegation_amount
	delegation_amount=$(cast to-unit 1ether wei)

	echo "Funding delegator with ETH..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" --value 1ether "${delegator_address}"

	echo "Funding delegator with MATIC/POL..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${PRIVATE_KEY}" \
		"${L1_MATIC_TOKEN_ADDRESS}" "transfer(address,uint)" "${delegator_address}" "${delegation_amount}"

	echo "Approving StakeManager..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${delegator_private_key}" \
		"${L1_MATIC_TOKEN_ADDRESS}" "approve(address,uint)" "${L1_STAKE_MANAGER_PROXY_ADDRESS}" "${delegation_amount}"

	echo "Delegating ${delegation_amount} wei to validator ${validator_id}..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${delegator_private_key}" \
		"${validator_share_address}" "buyVoucherPOL(uint,uint)" "${delegation_amount}" "0"

	# Verify L1 stakes.
	local final_total_stake final_delegator_stake
	final_total_stake=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${L1_STAKING_INFO_ADDRESS}" "totalValidatorStake(uint)(uint)" "${validator_id}" | cut -d' ' -f1)
	final_delegator_stake=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${validator_share_address}" "getTotalStake(address)(uint,uint)" "${delegator_address}" | head -1 | cut -d' ' -f1)

	echo "Final total stake: ${final_total_stake} (expected $((initial_total_stake + delegation_amount)))"
	echo "Final delegator stake: ${final_delegator_stake} (expected $((initial_delegator_stake + delegation_amount)))"
	[[ "${final_total_stake}" -eq $((initial_total_stake + delegation_amount)) ]]
	[[ "${final_delegator_stake}" -eq $((initial_delegator_stake + delegation_amount)) ]]

	# Verify L2 voting power.
	local validator_power_cmd='curl -s "${L2_CL_API_URL}/stake/validator/'"${validator_id}"'" | jq --raw-output ".validator.voting_power"'
	local expected_power
	expected_power=$(cast to-unit "${final_total_stake}" ether | cut -d'.' -f1)
	echo "Waiting for L2 voting power to reach ${expected_power}..."
	_assert_cmd_eventually_equal "${validator_power_cmd}" "${expected_power}" 180

	echo "✅ Delegate test passed"
}

test_undelegate() {
	echo ""
	echo "Starting undelegate test..."

	local validator_id=${VALIDATOR_ID:-"1"}
	local delegator_private_key="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
	local delegator_address="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
	echo "Validator ID: ${validator_id}"
	echo "Delegator: ${delegator_address}"

	# Get ValidatorShare contract.
	local validator_share_address
	validator_share_address=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${L1_STAKING_INFO_ADDRESS}" "getValidatorContractAddress(uint)(address)" "${validator_id}")
	echo "ValidatorShare: ${validator_share_address}"

	# Check current stake.
	local current_delegator_stake
	current_delegator_stake=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${validator_share_address}" "getTotalStake(address)(uint,uint)" "${delegator_address}" | head -1 | cut -d' ' -f1)
	echo "Current delegator stake: ${current_delegator_stake}"

	if [[ "${current_delegator_stake}" == "0" ]]; then
		echo "⚠️  No stake to undelegate, skipping (run delegate test first)"
		return 0
	fi

	local initial_total_stake
	initial_total_stake=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${L1_STAKING_INFO_ADDRESS}" "totalValidatorStake(uint)(uint)" "${validator_id}" | cut -d' ' -f1)
	echo "Initial total stake: ${initial_total_stake}"

	local undelegation_amount
	undelegation_amount=$(cast to-unit 1ether wei)

	local current_unbond_nonce
	current_unbond_nonce=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${validator_share_address}" "unbondNonces(address)(uint)" "${delegator_address}")
	echo "Current unbond nonce: ${current_unbond_nonce}"

	echo "Undelegating ${undelegation_amount} wei from validator ${validator_id}..."
	local max_shares
	max_shares=$(cast --max-uint)
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${delegator_private_key}" \
		"${validator_share_address}" "sellVoucher_newPOL(uint,uint)" "${undelegation_amount}" "${max_shares}"

	# Verify L1 stakes.
	local new_total_stake new_delegator_stake final_unbond_nonce
	new_total_stake=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${L1_STAKING_INFO_ADDRESS}" "totalValidatorStake(uint)(uint)" "${validator_id}" | cut -d' ' -f1)
	new_delegator_stake=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${validator_share_address}" "getTotalStake(address)(uint,uint)" "${delegator_address}" | head -1 | cut -d' ' -f1)
	final_unbond_nonce=$(cast call --rpc-url "${L1_RPC_URL}" \
		"${validator_share_address}" "unbondNonces(address)(uint)" "${delegator_address}")

	echo "New total stake: ${new_total_stake} (expected $((initial_total_stake - undelegation_amount)))"
	echo "New delegator stake: ${new_delegator_stake} (expected $((current_delegator_stake - undelegation_amount)))"
	echo "Unbond nonce: ${final_unbond_nonce} (expected $((current_unbond_nonce + 1)))"
	[[ "${new_total_stake}" -eq $((initial_total_stake - undelegation_amount)) ]]
	[[ "${new_delegator_stake}" -eq $((current_delegator_stake - undelegation_amount)) ]]
	[[ "${final_unbond_nonce}" -eq $((current_unbond_nonce + 1)) ]]

	# Verify L2 voting power.
	local validator_power_cmd='curl -s "${L2_CL_API_URL}/stake/validator/'"${validator_id}"'" | jq --raw-output ".validator.voting_power"'
	local expected_power
	expected_power=$(cast to-unit "${new_total_stake}" ether | cut -d'.' -f1)
	echo "Waiting for L2 voting power to reach ${expected_power}..."
	_assert_cmd_eventually_equal "${validator_power_cmd}" "${expected_power}" 180

	echo "✅ Undelegate test passed"
}

test_remove_validator() {
	echo ""
	echo "Starting remove validator test..."

	local validator_private_key=${VALIDATOR_PRIVATE_KEY:-"0x2a4ae8c4c250917781d38d95dafbb0abe87ae2c9aea02ed7c7524685358e49c2"}
	local validator_id=${VALIDATOR_ID:-"1"}
	local validator_count_cmd='curl -s "${L2_CL_API_URL}/stake/validators-set" | jq --raw-output ".validator_set.validators | length"'

	local initial_count
	initial_count=$(eval "${validator_count_cmd}")
	echo "Initial validator count: ${initial_count}"

	echo "Unstaking validator ${validator_id}..."
	cast send --rpc-url "${L1_RPC_URL}" --private-key "${validator_private_key}" \
		"${L1_STAKE_MANAGER_PROXY_ADDRESS}" "unstakePOL(uint)" "${validator_id}"

	echo "Waiting for validator count to decrease..."
	_assert_cmd_eventually_equal "${validator_count_cmd}" $((initial_count - 1)) 180

	echo "✅ Remove validator test passed"
}

main() {
	echo "Starting validator tests"
	echo ""

	setup_pos_env
	echo ""

	test_add_validator
	echo ""

	test_update_validator_stake
	echo ""

	test_delegate
	echo ""

	test_undelegate
	echo ""

	test_remove_validator
	echo ""

	echo "✅ All validator tests passed"
}

main "$@"
