#!/bin/bash

# Fault injection and invariant checking for the sequence store, layered on
# sequencer_test_utils.sh. Additive by design: nothing here edits the
# functional suite's helpers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sequencer_test_utils.sh"

# The broker is the store's durability layer and the one store service the
# functional suite never touches. Stopping its leader is what turned
# preconfirmations back into ordinary mining during manual testing, so it is
# the highest-signal fault available.
REDPANDA_SERVICE=${REDPANDA_SERVICE:-"seqstore-redpanda"}

# Same image the stateless suite uses for tc, so CI pulls nothing new.
TC_IMAGE=${TC_IMAGE:-"gaiadocker/iproute2:3.3"}
TC_INTERFACE=${TC_INTERFACE:-"eth0"}

# One episode: hold the fault, then let the chain settle before asserting.
# Both are deliberately short — the point is whether the invariants hold, not
# how long a devnet can survive.
CHAOS_HOLD_SECONDS=${CHAOS_HOLD_SECONDS:-45}
CHAOS_SETTLE_SECONDS=${CHAOS_SETTLE_SECONDS:-60}
CHAOS_RECOVER_TIMEOUT=${CHAOS_RECOVER_TIMEOUT:-180}

# Store-side latency. 150ms is a WAN-ish round trip: enough to push the
# publish path well past its budget without being a de-facto outage.
STORE_DELAY_MS=${STORE_DELAY_MS:-150}
STORE_JITTER_MS=${STORE_JITTER_MS:-40}

# Head sampler cadence. Manual testing used 1Hz across nine nodes; the same
# rate here is cheap and catches a rewritten height between two blocks.
ORACLE_INTERVAL=${ORACLE_INTERVAL:-1}
ORACLE_LOG=${ORACLE_LOG:-"/tmp/sequencer-head-oracle.log"}
ORACLE_PID=""

# Printed on every run so a failure can be replayed exactly.
CHAOS_SEED=${CHAOS_SEED:-$RANDOM}

# Resolve a kurtosis service to its docker container. Kurtosis names
# containers "<service>--<uuid>", so the service name is a prefix.
container_for_service() {
  docker ps --format '{{.Names}}' | grep "^$1--" | head -1
}

service_exists() {
  kurtosis service inspect "$ENCLAVE_NAME" "$1" > /dev/null 2>&1
}

stop_service() {
  echo "  fault: stopping $1"
  kurtosis service stop "$ENCLAVE_NAME" "$1" > /dev/null
}

start_service() {
  echo "  repair: starting $1"
  kurtosis service start "$ENCLAVE_NAME" "$1" > /dev/null
}

# Pausing freezes the process without closing its sockets, so peers see a
# black hole rather than a refused connection — a different failure mode from
# a stop, and the one that produced the worst behaviour in manual testing.
pause_service() {
  local container
  container=$(container_for_service "$1")
  if [ -z "$container" ]; then
    echo "  no container for $1; cannot pause"
    return 1
  fi
  echo "  fault: pausing $1 ($container)"
  docker pause "$container" > /dev/null
}

unpause_service() {
  local container
  container=$(container_for_service "$1")
  if [ -z "$container" ]; then
    return 0
  fi
  echo "  repair: unpausing $1"
  docker unpause "$container" > /dev/null || true
}

# Delay everything leaving a store container. Applied on the store side
# rather than on bor so the publish path pays the latency without slowing
# bor's peer-to-peer traffic, which would confound the block-production
# reading.
add_store_latency() {
  local service=$1 delay=${2:-$STORE_DELAY_MS} jitter=${3:-$STORE_JITTER_MS} container
  container=$(container_for_service "$service")
  if [ -z "$container" ]; then
    echo "  no container for $service; cannot add latency"
    return 1
  fi

  echo "  fault: ${delay}ms±${jitter}ms egress latency on $service"
  docker run --rm --net "container:$container" --cap-add NET_ADMIN \
    --entrypoint sh "$TC_IMAGE" -c \
    "tc qdisc add dev $TC_INTERFACE root netem delay ${delay}ms ${jitter}ms" > /dev/null
}

remove_store_latency() {
  local service=$1 container
  container=$(container_for_service "$service")
  if [ -z "$container" ]; then
    return 0
  fi
  echo "  repair: clearing latency on $service"
  docker run --rm --net "container:$container" --cap-add NET_ADMIN \
    "$TC_IMAGE" qdisc del dev "$TC_INTERFACE" root > /dev/null 2>&1 || true
}

# Sample every bor node's head at a fixed rate. Each line is
# "<service> <height> <hash>"; assert_no_rewritten_heights reads it back.
start_head_oracle() {
  : > "$ORACLE_LOG"
  local services=("${VALIDATORS[@]}" "$RPC_NODE")

  (
    while true; do
      local service resp height hash
      for service in "${services[@]}"; do
        resp=$(rpc_post "$service" '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
        height=$(echo "$resp" | jq -r '.result.number // ""')
        hash=$(echo "$resp" | jq -r '.result.hash // ""')
        if [ -n "$height" ] && [ -n "$hash" ]; then
          echo "$service $height $hash" >> "$ORACLE_LOG"
        fi
      done
      sleep "$ORACLE_INTERVAL"
    done
  ) &
  ORACLE_PID=$!
  echo "Head oracle sampling every ${ORACLE_INTERVAL}s (pid $ORACLE_PID)"
}

stop_head_oracle() {
  if [ -n "$ORACLE_PID" ] && kill -0 "$ORACLE_PID" 2> /dev/null; then
    kill "$ORACLE_PID" 2> /dev/null || true
    wait "$ORACLE_PID" 2> /dev/null || true
  fi
  ORACLE_PID=""
}

# The invariant that matters for a store fault: a node may fall behind, but it
# must never report one hash for a height and later a different one. The store
# is not supposed to be able to reorganise the chain, so any rewrite here is a
# real finding rather than expected reorg noise.
assert_no_rewritten_heights() {
  local samples rewrites
  samples=$(wc -l < "$ORACLE_LOG" | tr -d ' ')
  if [ "${samples:-0}" -eq 0 ]; then
    echo "Oracle recorded nothing; the invariant was not actually checked"
    return 1
  fi

  # One line per (service, height) that was ever seen with two hashes.
  rewrites=$(sort -u "$ORACLE_LOG" | awk '{print $1, $2}' | sort | uniq -d)
  if [ -n "$rewrites" ]; then
    echo "Nodes rewrote heights they had already reported:"
    echo "$rewrites" | while read -r service height; do
      echo "  $service height $height:"
      grep "^$service $height " "$ORACLE_LOG" | awk '{print "    " $3}' | sort -u
    done
    return 1
  fi

  echo "No node rewrote a height it had reported ($samples samples)"
}

wait_for_progress() {
  local service=$1 timeout=${2:-$CHAOS_RECOVER_TIMEOUT} start_time=$SECONDS baseline current
  baseline=$(get_block_number "$service")

  while [ $((SECONDS - start_time)) -lt "$timeout" ]; do
    current=$(get_block_number "$service")
    if [ "${current:-0}" -gt "${baseline:-0}" ]; then
      echo "  $service advanced $baseline -> $current"
      return 0
    fi
    sleep "$SLEEP_INTERVAL"
  done

  echo "  $service made no progress in ${timeout}s (stuck at $baseline)"
  return 1
}

# Count transactions addressed to one sink across a height range. The burst
# episode uses this to prove its load actually reached the chain: polycli can
# fail every submission (a fee cap, a bad mode) and still exit in a way the
# episode tolerates, which would leave the assertions passing over an empty
# window.
count_txs_to_sink() {
  local sink=$1 from=$2 through=$3 height total=0 hex n
  sink=$(echo "$sink" | tr '[:upper:]' '[:lower:]')

  for ((height = from; height <= through; height++)); do
    hex=$(printf '0x%x' "$height")
    # rpc_post, not the rpc suite's rpc_call wrapper: that one is local to
    # sequencer_rpc_test.sh and is not in scope here.
    n=$(rpc_post "$RPC_NODE" '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["'"$hex"'",true],"id":1}' |
      jq -r --arg sink "$sink" '[.result.transactions[]? | select((.to // "") | ascii_downcase == $sink)] | length')
    total=$((total + ${n:-0}))
  done

  echo "$total"
}

# Ingress self-fencing on an oversized record wedged the writer during manual
# testing and stopped every preconfirmation behind it.
ingress_self_fence_count() {
  kurtosis service logs "$ENCLAVE_NAME" "seqstore-ingress" 2>&1 | grep -c "self-fenced" || true
}

# Compared against a baseline rather than zero: taking the broker away is
# expected to fence the ingress, so only fences that appear during the window
# under test are a finding.
assert_no_new_ingress_self_fence() {
  local baseline=$1 now
  now=$(ingress_self_fence_count)
  if [ "${now:-0}" -gt "${baseline:-0}" ]; then
    echo "Ingress self-fenced $((now - baseline)) more time(s) during this window; the writer wedged"
    kurtosis service logs "$ENCLAVE_NAME" "seqstore-ingress" 2>&1 | grep "self-fenced" | tail -5
    return 1
  fi
  echo "No new ingress self-fence (baseline $baseline)"
}
