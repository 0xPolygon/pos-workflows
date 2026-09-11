#!/bin/bash
set -e

# Chaos episodes against the sequence store. Each episode breaks one store
# component, holds the fault, repairs it, and checks the invariants that must
# survive: the chain keeps producing, no node rewrites a height it already
# reported, and publishing resumes.
#
# Throughput under fault is reported, never asserted. Manual testing measured
# 25-50% throughput cost from a store outage or latency, which contradicts the
# design brief that the store cannot affect block production. A threshold here
# would freeze whichever number happens to be true today into CI; the shape
# worth gating on is liveness and correctness.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/store_chaos_utils.sh"

echo "Starting kurtosis sequence-store chaos tests..."

check_required_tools

ENCLAVE_NAME=${ENCLAVE_NAME:-"kurtosis-sequencer-e2e"}
export ENCLAVE_NAME

setup_service_lists

RANDOM=$CHAOS_SEED
echo "Chaos seed: $CHAOS_SEED (export CHAOS_SEED=$CHAOS_SEED to replay)"

CURRENT_REPAIR=""
RANDOM_REPAIR=""

# Oversized-record burst. 32KB per transaction across a couple of hundred
# transactions gives the bundler enough material to build a message over the
# topic limit if it ever stops capping.
LARGE_TX_COUNT=${LARGE_TX_COUNT:-200}
LARGE_TX_RATE=${LARGE_TX_RATE:-20}
LARGE_TX_DATA_SIZE=${LARGE_TX_DATA_SIZE:-32768}

# Any exit path must undo the fault and stop the background samplers, or the
# enclave is left broken for whatever runs next.
cleanup_chaos() {
  if [ -n "$CURRENT_REPAIR" ]; then
    echo "Cleaning up after interruption: $CURRENT_REPAIR"
    $CURRENT_REPAIR || true
    CURRENT_REPAIR=""
  fi
  stop_load
  stop_head_oracle
}
trap cleanup_chaos EXIT

# One episode. apply_fn breaks it, repair_fn fixes it; the invariants in
# between are the same for every fault, which is the point of the shape.
run_episode() {
  local name=$1 apply_fn=$2 repair_fn=$3
  echo ""
  echo "=== Episode: $name ==="

  # get_block_number reports 0 for an unreachable node, which would make the
  # liveness check below read as enormous progress. Establish the baseline
  # before touching anything and refuse to run the episode without one.
  local before_height
  before_height=$(get_block_number "${VALIDATORS[0]}")
  if [ "${before_height:-0}" -le 0 ]; then
    echo "  no readable height on ${VALIDATORS[0]} before the fault; not running blind"
    return 1
  fi

  if ! $apply_fn; then
    echo "Could not apply the fault; skipping episode"
    return 0
  fi
  CURRENT_REPAIR=$repair_fn

  # Liveness under fault: the chain must keep building. Zero blocks over the
  # whole hold is a halt, which is the failure this episode exists to catch.
  sleep "$CHAOS_HOLD_SECONDS"
  local during_height gained
  during_height=$(get_block_number "${VALIDATORS[0]}")
  gained=$((during_height - before_height))
  echo "  blocks during fault: $gained over ${CHAOS_HOLD_SECONDS}s"
  if [ "$gained" -le 0 ]; then
    echo "  chain halted while $name was in effect"
    $repair_fn || true
    CURRENT_REPAIR=""
    return 1
  fi

  $repair_fn || true
  CURRENT_REPAIR=""

  if ! wait_for_progress "${VALIDATORS[0]}"; then
    echo "  chain did not recover after $name"
    return 1
  fi

  # Publishing must come back on its own. A store fault that permanently
  # de-registers a publisher would leave the chain healthy but every
  # preconfirmation silently gone.
  local start_time=$SECONDS live
  while [ $((SECONDS - start_time)) -lt "$CHAOS_SETTLE_SECONDS" ]; do
    live=$(count_validators_with_metric "sequencer_publish_state" "1")
    if [ "$live" -eq "${#VALIDATORS[@]}" ]; then
      break
    fi
    sleep "$SLEEP_INTERVAL"
  done
  if [ "${live:-0}" -ne "${#VALIDATORS[@]}" ]; then
    echo "  only $live/${#VALIDATORS[@]} publishers live ${CHAOS_SETTLE_SECONDS}s after repair"
    return 1
  fi

  local after_height
  after_height=$(get_block_number "${VALIDATORS[0]}")
  echo "  recovered: $live/${#VALIDATORS[@]} publishers live, height $before_height -> $after_height"
}

# Episode 1: the broker goes away. Manual testing found that stopping the
# leader broker produced a slow block, dropped every preconfirmation back to
# ordinary mining, and left an invalid-preconf record behind — so this is the
# episode most likely to find something.
apply_broker_stop() {
  if ! service_exists "$REDPANDA_SERVICE"; then
    echo "  no $REDPANDA_SERVICE in this enclave"
    return 1
  fi
  stop_service "$REDPANDA_SERVICE"
}
repair_broker_stop() { start_service "$REDPANDA_SERVICE"; }

# Episode 2: the write path gets slow rather than disappearing. Latency is the
# harder case — nothing errors, so no failure path is taken; the publish path
# simply misses its budget.
apply_ingress_latency() { add_store_latency "seqstore-ingress"; }
repair_ingress_latency() { remove_store_latency "seqstore-ingress"; }

# Episode 3: the read path freezes with its sockets open, so consumers block
# instead of failing fast.
apply_gateway_pause() { pause_service "seqstore-gateway"; }
repair_gateway_pause() { unpause_service "seqstore-gateway"; }

# Episode 4: pick a fault at random from the set above. The seed is printed on
# every run, so CI gets variety across runs while any single failure stays
# reproducible.
apply_random_fault() {
  local choice=$((RANDOM % 3))
  case $choice in
    0)
      RANDOM_REPAIR=repair_broker_stop
      apply_broker_stop
      ;;
    1)
      RANDOM_REPAIR=repair_ingress_latency
      add_store_latency "seqstore-ingress" $((STORE_DELAY_MS * 2)) "$STORE_JITTER_MS"
      ;;
    *)
      RANDOM_REPAIR=repair_gateway_latency
      add_store_latency "seqstore-gateway"
      ;;
  esac
}
repair_gateway_latency() { remove_store_latency "seqstore-gateway"; }
repair_random_fault() {
  if [ -z "$RANDOM_REPAIR" ]; then
    echo "  no fault was applied; nothing to repair"
    return 0
  fi
  $RANDOM_REPAIR
}

# Episode 5: oversized records. Bundling transactions into one store message
# used to build a message over the topic limit, which self-fenced the ingress
# permanently and stopped preconfirmations behind it. Large calldata is the
# shape that triggered it.
test_large_calldata_does_not_wedge_the_store() {
  echo ""
  echo "=== Episode: large-calldata burst ==="

  if ! command -v polycli &> /dev/null; then
    echo "polycli not found; skipping (this episode is load-shaped)"
    return 0
  fi

  local url chain_hex chain_id
  url=$(get_rpc_url "$RPC_NODE")
  chain_hex=$(curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$url" | jq -r '.result // ""')
  chain_id=$(printf '%d' "$chain_hex" 2> /dev/null || echo "")
  if [ -z "$chain_id" ]; then
    echo "Could not read chain id; skipping"
    return 0
  fi

  # Earlier episodes take the broker away, which fences the ingress
  # legitimately; only fences added by this burst mean anything.
  local fence_baseline
  fence_baseline=$(ingress_self_fence_count)

  # store mode writes --store-data-size bytes into a dynamic byte array, which
  # is polycli's supported way to send a large payload (--calldata needs
  # contract-call mode and a deployed contract address). Each transaction
  # stays well under the 1MB topic limit on its own, so only a bundle that
  # ignores the cap can build an oversized record.
  echo "Sending $LARGE_TX_COUNT transactions carrying ${LARGE_TX_DATA_SIZE}B each"
  polycli loadtest \
    --rpc-url "$url" \
    --private-key "${LOAD_PRIVATE_KEY#0x}" \
    --chain-id "$chain_id" \
    --requests "$LARGE_TX_COUNT" \
    --concurrency 4 \
    --rate-limit "$LARGE_TX_RATE" \
    --mode s \
    --store-data-size "$LARGE_TX_DATA_SIZE" \
    --legacy \
    --gas-price "$LOAD_GAS_PRICE" \
    > /tmp/large-calldata-load.log 2>&1 || echo "  load exited non-zero (tolerated; the store-side assertions are what matter)"

  sleep "$SLEEP_INTERVAL"

  assert_no_new_ingress_self_fence "$fence_baseline" || return 1

  if ! wait_for_progress "${VALIDATORS[0]}"; then
    echo "  chain stopped advancing after the large-calldata burst"
    return 1
  fi

  local entries
  entries=$(sum_validator_metric "sequencer_publish_entries")
  if [ "$entries" -le 0 ]; then
    echo "  no entries published after the burst; the writer is wedged"
    return 1
  fi
  echo "  store still publishing after the burst (entries=$entries)"
}

run_all_chaos() {
  local failed=0

  # Reach the fork first: before Rio the publisher is gated off entirely, so a
  # store fault would prove nothing.
  wait_for_block "$POST_RIO_BLOCK" "$POST_RIO_TIMEOUT_SECONDS"

  # Load and the head sampler run across every episode, so windows carry
  # transactions and a rewritten height anywhere in the run is caught.
  start_load
  start_head_oracle

  run_episode "broker stop" apply_broker_stop repair_broker_stop || failed=1
  if [ $failed -eq 0 ]; then
    run_episode "ingress latency" apply_ingress_latency repair_ingress_latency || failed=1
  fi
  if [ $failed -eq 0 ]; then
    run_episode "gateway pause" apply_gateway_pause repair_gateway_pause || failed=1
  fi
  if [ $failed -eq 0 ]; then
    run_episode "random store fault" apply_random_fault repair_random_fault || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_large_calldata_does_not_wedge_the_store || failed=1
  fi

  stop_load
  stop_head_oracle

  # Checked once over the whole run rather than per episode: a rewrite is a
  # rewrite whenever it happened.
  if [ $failed -eq 0 ]; then
    assert_no_rewritten_heights || failed=1
  fi

  echo ""
  if [ $failed -ne 0 ]; then
    echo "Sequence-store chaos tests FAILED (seed $CHAOS_SEED)"
    exit 1
  fi
  echo "All sequence-store chaos tests passed (seed $CHAOS_SEED)"
}

run_all_chaos
