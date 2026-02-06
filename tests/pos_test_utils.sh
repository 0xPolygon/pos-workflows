#!/bin/bash
# Common PoS test utilities: env setup + assertion helpers.
# Requires ENCLAVE_NAME from env.

POS_TEST_TIMEOUT=${POS_TEST_TIMEOUT:-180}
POS_TEST_INTERVAL=${POS_TEST_INTERVAL:-10}
PRIVATE_KEY=${PRIVATE_KEY:-"0xd40311b5a5ca5eaeb48dfba5403bde4993ece8eccf4190e98e19fcd4754260ea"}

# Resolve L1/L2 RPC URLs and contract addresses from kurtosis enclave.
setup_pos_env() {
	if [[ -z "${ENCLAVE_NAME:-}" ]]; then
		echo "Error: ENCLAVE_NAME env var is required"
		return 1
	fi

	export PRIVATE_KEY
	echo "PRIVATE_KEY=${PRIVATE_KEY}"

	export ENCLAVE_NAME
	echo "ENCLAVE_NAME=${ENCLAVE_NAME}"

	# L1 and L2 RPC and API URLs.
	export L1_RPC_URL=${L1_RPC_URL:-"http://$(kurtosis port print "${ENCLAVE_NAME}" el-1-geth-lighthouse rpc)"}
	echo "L1_RPC_URL=${L1_RPC_URL}"

	export L2_RPC_URL=${L2_RPC_URL:-$(kurtosis port print "${ENCLAVE_NAME}" "l2-el-1-bor-heimdall-v2-validator" rpc)}
	export L2_CL_API_URL=${L2_CL_API_URL:-$(kurtosis port print "${ENCLAVE_NAME}" "l2-cl-1-heimdall-v2-bor-validator" http)}

	echo "L2_RPC_URL=${L2_RPC_URL}"
	echo "L2_CL_API_URL=${L2_CL_API_URL}"

	if [[ -z "${L1_GOVERNANCE_PROXY_ADDRESS:-}" ]] ||
		[[ -z "${L1_DEPOSIT_MANAGER_PROXY_ADDRESS:-}" ]] ||
		[[ -z "${L1_STAKE_MANAGER_PROXY_ADDRESS:-}" ]] ||
		[[ -z "${L1_STAKING_INFO_ADDRESS:-}" ]] ||
		[[ -z "${L1_MATIC_TOKEN_ADDRESS:-}" ]] ||
		[[ -z "${L1_ERC20_TOKEN_ADDRESS:-}" ]] ||
		[[ -z "${L1_ERC721_TOKEN_ADDRESS:-}" ]] ||
		[[ -z "${L2_STATE_RECEIVER_ADDRESS:-}" ]] ||
		[[ -z "${L2_ERC20_TOKEN_ADDRESS:-}" ]] ||
		[[ -z "${L2_ERC721_TOKEN_ADDRESS:-}" ]]; then
		local matic_contract_addresses
		matic_contract_addresses=$(kurtosis files inspect "${ENCLAVE_NAME}" matic-contract-addresses contractAddresses.json | jq)

		# L1 contract addresses.
		export L1_GOVERNANCE_PROXY_ADDRESS=${L1_GOVERNANCE_PROXY_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.root.GovernanceProxy')}
		echo "L1_GOVERNANCE_PROXY_ADDRESS=${L1_GOVERNANCE_PROXY_ADDRESS}"

		export L1_DEPOSIT_MANAGER_PROXY_ADDRESS=${L1_DEPOSIT_MANAGER_PROXY_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.root.DepositManagerProxy')}
		echo "L1_DEPOSIT_MANAGER_PROXY_ADDRESS=${L1_DEPOSIT_MANAGER_PROXY_ADDRESS}"

		export L1_STAKE_MANAGER_PROXY_ADDRESS=${L1_STAKE_MANAGER_PROXY_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.root.StakeManagerProxy')}
		echo "L1_STAKE_MANAGER_PROXY_ADDRESS=${L1_STAKE_MANAGER_PROXY_ADDRESS}"

		export L1_STAKING_INFO_ADDRESS=${L1_STAKING_INFO_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.root.StakingInfo')}
		echo "L1_STAKING_INFO_ADDRESS=${L1_STAKING_INFO_ADDRESS}"

		export L1_MATIC_TOKEN_ADDRESS=${L1_MATIC_TOKEN_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.root.tokens.MaticToken')}
		echo "L1_MATIC_TOKEN_ADDRESS=${L1_MATIC_TOKEN_ADDRESS}"

		export L1_ERC20_TOKEN_ADDRESS=${L1_ERC20_TOKEN_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.root.tokens.TestToken')}
		echo "L1_ERC20_TOKEN_ADDRESS=${L1_ERC20_TOKEN_ADDRESS}"

		export L1_ERC721_TOKEN_ADDRESS=${L1_ERC721_TOKEN_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.root.tokens.RootERC721')}
		echo "L1_ERC721_TOKEN_ADDRESS=${L1_ERC721_TOKEN_ADDRESS}"

		# L2 contract addresses.
		export L2_STATE_RECEIVER_ADDRESS=${L2_STATE_RECEIVER_ADDRESS:-$(kurtosis files inspect "${ENCLAVE_NAME}" l2-el-genesis genesis.json | jq --raw-output '.config.bor.stateReceiverContract')}
		echo "L2_STATE_RECEIVER_ADDRESS=${L2_STATE_RECEIVER_ADDRESS}"

		export L2_ERC20_TOKEN_ADDRESS=${L2_ERC20_TOKEN_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.child.tokens.TestToken')}
		echo "L2_ERC20_TOKEN_ADDRESS=${L2_ERC20_TOKEN_ADDRESS}"

		export L2_ERC721_TOKEN_ADDRESS=${L2_ERC721_TOKEN_ADDRESS:-$(echo "${matic_contract_addresses}" | jq --raw-output '.child.tokens.RootERC721')}
		echo "L2_ERC721_TOKEN_ADDRESS=${L2_ERC721_TOKEN_ADDRESS}"
	fi
}

# Poll until command result >= target, or timeout.
_assert_cmd_eventually_gte() {
	local command="$1"
	local target="$2"
	local timeout="${3:-$POS_TEST_TIMEOUT}"
	local interval="${4:-$POS_TEST_INTERVAL}"

	local end_time=$(($(date +%s) + timeout))
	while true; do
		if [ "$(date +%s)" -ge "$end_time" ]; then
			echo "Timeout reached waiting for >= ${target}"
			return 1
		fi
		local result
		result=$(eval "${command}")
		echo "[$(date '+%H:%M:%S')] result=${result} target=${target}"
		if [ "${result}" -ge "${target}" ]; then
			return 0
		fi
		sleep "${interval}"
	done
}

# Poll until command result == target, or timeout.
_assert_cmd_eventually_equal() {
	local command="$1"
	local target="$2"
	local timeout="${3:-$POS_TEST_TIMEOUT}"
	local interval="${4:-$POS_TEST_INTERVAL}"

	local end_time=$(($(date +%s) + timeout))
	while true; do
		if [ "$(date +%s)" -ge "$end_time" ]; then
			echo "Timeout reached waiting for == ${target}"
			return 1
		fi
		local result
		result=$(eval "${command}")
		echo "[$(date '+%H:%M:%S')] result=${result} target=${target}"
		if [[ "${result}" == "${target}" ]]; then
			return 0
		fi
		sleep "${interval}"
	done
}

# Poll until token balance >= target.
_assert_token_balance_gte() {
	local contract="$1" address="$2" target="$3" rpc_url="$4"
	local timeout="${5:-$POS_TEST_TIMEOUT}" interval="${6:-$POS_TEST_INTERVAL}"

	local end_time=$(($(date +%s) + timeout))
	while true; do
		if [ "$(date +%s)" -ge "$end_time" ]; then
			echo "Timeout reached waiting for balance >= ${target}"
			return 1
		fi
		local balance
		balance=$(cast call --json --rpc-url "${rpc_url}" "${contract}" "balanceOf(address)(uint)" "${address}" | jq --raw-output '.[0]')
		echo "[$(date '+%H:%M:%S')] balance=${balance} target=${target}"
		if [ "${balance}" -ge "${target}" ]; then
			return 0
		fi
		sleep "${interval}"
	done
}
