#!/bin/bash
# State sync check: Heimdall and Bor have both processed at least one state sync.

STATE_SYNC_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STATE_SYNC_UTILS_DIR/pos_test_utils.sh"

# Verify state syncs are flowing: Heimdall has recorded at least one event record and
# Bor has committed at least one state sync.
# Requires setup_pos_env() to have been called first.
test_state_syncs() {
  echo ""
  echo "Starting state sync test..."

  local timeout="$POS_TEST_TIMEOUT"
  local interval="$POS_TEST_INTERVAL"

  local heimdall_cmd='curl -s "${L2_CL_API_URL}/clerk/event-records/count" | jq -r ".count"'
  local bor_cmd='cast call --gas-limit 15000000 --rpc-url "${L2_RPC_URL}" "${L2_STATE_RECEIVER_ADDRESS}" "lastStateId()(uint)"'

  echo ""
  echo "Waiting for Heimdall event records >= 1..."
  _assert_cmd_eventually_gte "${heimdall_cmd}" 1 "${timeout}" "${interval}"

  echo ""
  echo "Waiting for Bor lastStateId >= 1..."
  _assert_cmd_eventually_gte "${bor_cmd}" 1 "${timeout}" "${interval}"
}
