#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

ENCLAVE_NAME="${ENCLAVE_NAME:-pos}"
PRIVATE_KEY="${PRIVATE_KEY:-0xd40311b5a5ca5eaeb48dfba5403bde4993ece8eccf4190e98e19fcd4754260ea}"

# Thresholds
SYNC_DELTA_MAX=5
MILESTONE_TARGET_INCREASE=10
MILESTONE_TIMEOUT=300
CHECKPOINT_TIMEOUT=600
STATE_SYNC_TIMEOUT=300
BLOCK_ADVANCE_WAIT=60

log_header "Post-Upgrade Health Check"
log_info "Enclave: $ENCLAVE_NAME"

failures=0

log_header "Check 1: Block Production"
rpc_url=$(get_first_el_rpc_url)
if [[ -z "$rpc_url" ]]; then
	log_fail "Could not find any EL container"
	exit 1
fi

block_before=$(get_block_number "$rpc_url")
log_info "Block number: $block_before — waiting ${BLOCK_ADVANCE_WAIT}s..."
sleep "$BLOCK_ADVANCE_WAIT"
block_after=$(get_block_number "$rpc_url")

if [[ "$block_after" =~ ^[0-9]+$ ]] && [[ "$block_after" -gt "$block_before" ]]; then
	log_pass "Blocks advancing: $block_before -> $block_after (+$((block_after - block_before)))"
else
	log_fail "Blocks not advancing: before=$block_before after=$block_after"
	failures=$((failures + 1))
fi

log_header "Check 2: Node Sync"
min_block=999999999
max_block=0
el_containers=$(get_el_containers)
node_count=0

while IFS= read -r container; do
	[[ -z "$container" ]] && continue
	url=$(get_el_rpc_url "$container")
	bn=$(get_block_number "$url")
	if ! [[ "$bn" =~ ^[0-9]+$ ]]; then
		log_error "$container: failed to get block number"
		continue
	fi
	log_info "$container: block $bn"
	node_count=$((node_count + 1))
	[[ "$bn" -lt "$min_block" ]] && min_block=$bn
	[[ "$bn" -gt "$max_block" ]] && max_block=$bn
done <<<"$el_containers"

delta=$((max_block - min_block))
if [[ "$node_count" -gt 0 ]] && [[ "$delta" -le "$SYNC_DELTA_MAX" ]]; then
	log_pass "All $node_count nodes synced (delta=$delta, max allowed=$SYNC_DELTA_MAX)"
else
	log_fail "Node sync delta=$delta exceeds max=$SYNC_DELTA_MAX (min=$min_block max=$max_block)"
	failures=$((failures + 1))
fi

log_header "Check 3: Milestones"
cl_api_url=$(get_first_cl_api_url)
if [[ -z "$cl_api_url" ]]; then
	log_fail "Could not find any CL container"
	exit 1
fi

initial_milestones=$(curl -s "${cl_api_url}/milestones/count" | jq -r '.count // 0')
[[ "$initial_milestones" == "null" || -z "$initial_milestones" ]] && initial_milestones=0
milestone_target=$((initial_milestones + MILESTONE_TARGET_INCREASE))
log_info "Initial milestone count: $initial_milestones, target: $milestone_target"

milestone_cmd='curl -s "'"${cl_api_url}"'/milestones/count" | jq -r ".count // 0"'
if poll_until_gte "$milestone_cmd" "$milestone_target" "$MILESTONE_TIMEOUT" 5; then
	log_pass "Milestones reached $milestone_target (+$MILESTONE_TARGET_INCREASE)"
else
	log_fail "Milestones did not reach $milestone_target within ${MILESTONE_TIMEOUT}s"
	failures=$((failures + 1))
fi

log_header "Check 4: Checkpoints"
initial_checkpoint=$(curl -s "${cl_api_url}/checkpoints/latest" | jq -r '.checkpoint.id // 0')
[[ "$initial_checkpoint" == "null" || -z "$initial_checkpoint" ]] && initial_checkpoint=0
checkpoint_target=$((initial_checkpoint + 1))
log_info "Initial checkpoint ID: $initial_checkpoint, waiting for: $checkpoint_target"

checkpoint_cmd='curl -s "'"${cl_api_url}"'/checkpoints/latest" | jq -r ".checkpoint.id // 0"'
if poll_until_gte "$checkpoint_cmd" "$checkpoint_target" "$CHECKPOINT_TIMEOUT" 5; then
	log_pass "New checkpoint created (>= $checkpoint_target)"
else
	log_fail "No new checkpoint within ${CHECKPOINT_TIMEOUT}s"
	failures=$((failures + 1))
fi

log_header "Check 5: State Syncs (L1->L2 Bridge)"

# Get L1 RPC (still kurtosis-managed) and contract addresses.
l1_rpc_url=$(get_l1_rpc_url)
el_rpc_url=$(get_first_el_rpc_url)
contract_addresses=$(get_contract_addresses)

matic_token=$(echo "$contract_addresses" | jq -r '.root.tokens.MaticToken')
erc20_token=$(echo "$contract_addresses" | jq -r '.root.tokens.TestToken')
erc721_token=$(echo "$contract_addresses" | jq -r '.root.tokens.RootERC721')
deposit_manager=$(echo "$contract_addresses" | jq -r '.root.DepositManagerProxy')
state_receiver=$(kurtosis files inspect "$ENCLAVE_NAME" l2-el-genesis genesis.json 2>/dev/null | jq -r '.config.bor.stateReceiverContract')
l2_erc721_token=$(echo "$contract_addresses" | jq -r '.child.tokens.RootERC721')

log_info "L1 RPC: $l1_rpc_url"
log_info "MATIC token: $matic_token"
log_info "ERC20 token: $erc20_token"
log_info "ERC721 token: $erc721_token"
log_info "Deposit manager: $deposit_manager"
log_info "State receiver: $state_receiver"
log_info "L2 ERC721 token: $l2_erc721_token"

# Record initial state sync counts on heimdall and bor.
heimdall_count=$(curl -s "${cl_api_url}/clerk/event-records/count" | jq -r '.count // 0')
[[ "$heimdall_count" == "null" || -z "$heimdall_count" ]] && heimdall_count=0
bor_count=$(cast call --gas-limit 15000000 --rpc-url "$el_rpc_url" "$state_receiver" "lastStateId()(uint)" 2>/dev/null || echo "0")
log_info "Initial state sync counts: heimdall=${heimdall_count} bor=${bor_count}"

bridge_amount=$(cast to-unit 1ether wei)
address=$(cast wallet address --private-key "$PRIVATE_KEY")

# Record initial L2 ERC721 balance.
initial_l2_erc721=$(cast call --rpc-url "$el_rpc_url" --json "$l2_erc721_token" "balanceOf(address)(uint)" "$address" | jq --raw-output '.[0]')
log_info "Initial L2 ERC721 balance: $initial_l2_erc721"

# Mint ERC721.
total_supply=$(cast call --rpc-url "$l1_rpc_url" --json "$erc721_token" "totalSupply()(uint)" | jq --raw-output '.[0]')
token_id=$((total_supply + 1))
log_info "Minting ERC721 token (id: ${token_id})..."
cast send --rpc-url "$l1_rpc_url" --private-key "$PRIVATE_KEY" \
	"$erc721_token" "mint(uint)" "$token_id" >/dev/null

# Bridge MATIC/POL.
log_info "Bridging MATIC/POL..."
cast send --rpc-url "$l1_rpc_url" --private-key "$PRIVATE_KEY" \
	"$matic_token" "approve(address,uint)" "$deposit_manager" "$bridge_amount" >/dev/null
cast send --rpc-url "$l1_rpc_url" --private-key "$PRIVATE_KEY" \
	"$deposit_manager" "depositERC20(address,uint)" "$matic_token" "$bridge_amount" >/dev/null

# Bridge ERC20.
log_info "Bridging ERC20..."
cast send --rpc-url "$l1_rpc_url" --private-key "$PRIVATE_KEY" \
	"$erc20_token" "approve(address,uint)" "$deposit_manager" "$bridge_amount" >/dev/null
cast send --rpc-url "$l1_rpc_url" --private-key "$PRIVATE_KEY" \
	"$deposit_manager" "depositERC20(address,uint)" "$erc20_token" "$bridge_amount" >/dev/null

# Bridge ERC721.
log_info "Bridging ERC721 (id: ${token_id})..."
cast send --rpc-url "$l1_rpc_url" --private-key "$PRIVATE_KEY" \
	"$erc721_token" "approve(address,uint)" "$deposit_manager" "$token_id" >/dev/null
cast send --rpc-url "$l1_rpc_url" --private-key "$PRIVATE_KEY" \
	"$deposit_manager" "depositERC721(address,uint)" "$erc721_token" "$token_id" >/dev/null

# Verify heimdall event records increase by 3.
heimdall_target=$((heimdall_count + 3))
log_info "Waiting for heimdall event records >= $heimdall_target (+3)..."
heimdall_cmd='curl -s "'"${cl_api_url}"'/clerk/event-records/count" | jq -r ".count // 0"'
if poll_until_gte "$heimdall_cmd" "$heimdall_target" "$STATE_SYNC_TIMEOUT" 5; then
	log_pass "Heimdall event records reached $heimdall_target (+3)"
else
	log_fail "Heimdall event records did not reach $heimdall_target within ${STATE_SYNC_TIMEOUT}s"
	failures=$((failures + 1))
fi

# Verify bor lastStateId increases by 3.
bor_target=$((bor_count + 3))
log_info "Waiting for bor lastStateId >= $bor_target (+3)..."
bor_cmd='cast call --gas-limit 15000000 --rpc-url "'"${el_rpc_url}"'" "'"${state_receiver}"'" "lastStateId()(uint)"'
if poll_until_gte "$bor_cmd" "$bor_target" "$STATE_SYNC_TIMEOUT" 5; then
	log_pass "Bor lastStateId reached $bor_target (+3)"
else
	log_fail "Bor lastStateId did not reach $bor_target within ${STATE_SYNC_TIMEOUT}s"
	failures=$((failures + 1))
fi

# Verify ERC721 arrived on L2.
log_info "Verifying L2 ERC721 balance increased..."
erc721_target=$((initial_l2_erc721 + 1))
erc721_cmd='cast call --rpc-url "'"${el_rpc_url}"'" --json "'"${l2_erc721_token}"'" "balanceOf(address)(uint)" "'"${address}"'" | jq --raw-output '\''.[0]'\'''
if poll_until_gte "$erc721_cmd" "$erc721_target" "$STATE_SYNC_TIMEOUT" 5; then
	log_pass "L2 ERC721 balance increased (>= $erc721_target)"
else
	log_fail "L2 ERC721 balance did not increase within ${STATE_SYNC_TIMEOUT}s"
	failures=$((failures + 1))
fi

log_header "Check 6: Final Sync Verification"
min_block=999999999
max_block=0
node_count=0

while IFS= read -r container; do
	[[ -z "$container" ]] && continue
	url=$(get_el_rpc_url "$container")
	bn=$(get_block_number "$url")
	if ! [[ "$bn" =~ ^[0-9]+$ ]]; then
		log_error "$container: failed to get block number"
		continue
	fi
	log_info "$container: block $bn"
	node_count=$((node_count + 1))
	[[ "$bn" -lt "$min_block" ]] && min_block=$bn
	[[ "$bn" -gt "$max_block" ]] && max_block=$bn
done <<<"$el_containers"

delta=$((max_block - min_block))
if [[ "$node_count" -gt 0 ]] && [[ "$delta" -le "$SYNC_DELTA_MAX" ]]; then
	log_pass "Final sync OK: $node_count nodes (delta=$delta)"
else
	log_fail "Final sync delta=$delta exceeds max=$SYNC_DELTA_MAX"
	failures=$((failures + 1))
fi

log_header "Health Check Summary"
if [[ "$failures" -eq 0 ]]; then
	log_info "All checks passed."
	exit 0
else
	log_error "$failures check(s) failed."
	exit 1
fi
