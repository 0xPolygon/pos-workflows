#!/bin/bash

# Utility functions for kurtosis sequence-store e2e tests.
# Requires ENCLAVE_NAME from env; curl + jq only (no cast/polycli).

# Test configuration
POST_RIO_BLOCK=${POST_RIO_BLOCK:-140} # rio at 128 + margin
POST_RIO_TIMEOUT_SECONDS=${POST_RIO_TIMEOUT_SECONDS:-1200}
SLEEP_INTERVAL=${SLEEP_INTERVAL:-10}

# Store outage window. Must exceed the publisher's 40-block backfill depth
# cap AND typical milestone lag so the recovery exercises the finality
# floor: at 4s blocks, 300s ~= 75 blocks — the shape proven on devnets.
OUTAGE_SECONDS=${OUTAGE_SECONDS:-300}
# Blocks the chain must produce during the outage (target ~75; slack for a
# loaded runner). Production never waits on the store — a stall is a bug.
MIN_OUTAGE_BLOCKS=${MIN_OUTAGE_BLOCKS:-60}
RECOVERY_SETTLE_SECONDS=${RECOVERY_SETTLE_SECONDS:-150}
RECOVERY_TIMEOUT_SECONDS=${RECOVERY_TIMEOUT_SECONDS:-240}

# Producer takeover. Probe window to spot the active producer, then how long
# to allow for downtime rotation + resumed production, and for the stopped
# validator to rejoin. Rotation needs 3/4 heimdall quorum, which stopping a
# single validator's bor (its heimdall keeps voting) preserves.
PRODUCER_PROBE_SECONDS=${PRODUCER_PROBE_SECONDS:-12}
TAKEOVER_TIMEOUT_SECONDS=${TAKEOVER_TIMEOUT_SECONDS:-180}
TAKEOVER_MIN_BLOCKS=${TAKEOVER_MIN_BLOCKS:-5}
REJOIN_TIMEOUT_SECONDS=${REJOIN_TIMEOUT_SECONDS:-150}

# Service naming (kurtosis-pos launcher conventions)
VALIDATORS_START=${VALIDATORS_START:-1}
VALIDATORS_END=${VALIDATORS_END:-4}
SERVICE_SUFFIX_VALIDATOR=${SERVICE_SUFFIX_VALIDATOR:-"bor-heimdall-v2-validator"}
# Single-instance store services keep the bare names (no -N suffix).
SEQSTORE_SERVICES=${SEQSTORE_SERVICES:-"seqstore-ingress seqstore-gateway"}

VALIDATORS=()

check_required_tools() {
  for tool in kurtosis curl jq; do
    if ! command -v "$tool" &> /dev/null; then
      echo "Error: '$tool' command not found."
      exit 1
    fi
  done
}

setup_service_lists() {
  VALIDATORS=()
  for i in $(seq $VALIDATORS_START $VALIDATORS_END); do
    VALIDATORS+=("l2-el-${i}-${SERVICE_SUFFIX_VALIDATOR}")
  done
  echo "Validators under test: ${VALIDATORS[*]}"
}

get_rpc_url() {
  local service_name=$1
  kurtosis port print "$ENCLAVE_NAME" "$service_name" rpc 2> /dev/null || echo ""
}

get_block_number() {
  local service_name=$1
  local rpc_url
  rpc_url=$(get_rpc_url "$service_name")
  if [ -z "$rpc_url" ]; then
    echo "0"
    return
  fi
  local hex
  hex=$(curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$rpc_url" | jq -r '.result // "0x0"')
  printf '%d\n' "$hex" 2> /dev/null || echo "0"
}

# Read one label-free bor prometheus metric from a service; 0 when absent.
get_metric() {
  local service_name=$1
  local metric=$2
  local addr
  addr=$(kurtosis port print "$ENCLAVE_NAME" "$service_name" metrics 2> /dev/null | sed 's|^http://||')
  if [ -z "$addr" ]; then
    echo "0"
    return
  fi
  curl -s "http://${addr}/debug/metrics/prometheus" |
    awk -v m="$metric" '$1 == m { print $2; found = 1 } END { if (!found) print "0" }'
}

# Sum a metric across all validators.
sum_validator_metric() {
  local metric=$1
  local total=0 v
  for service in "${VALIDATORS[@]}"; do
    v=$(get_metric "$service" "$metric")
    total=$((total + ${v%.*}))
  done
  echo "$total"
}

# Count validators whose metric equals the expected value.
count_validators_with_metric() {
  local metric=$1
  local expected=$2
  local count=0 v
  for service in "${VALIDATORS[@]}"; do
    v=$(get_metric "$service" "$metric")
    if [ "${v%.*}" = "$expected" ]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# One line per validator: how many sequencer_* series its metrics endpoint
# serves, and the publish state. Zero series means the bor image was built
# without the sequencer (wrong branch) or the [sequencer] config did not
# render — a different failure than a publisher in the wrong state.
dump_sequencer_metric_presence() {
  local service addr series state
  for service in "${VALIDATORS[@]}"; do
    addr=$(kurtosis port print "$ENCLAVE_NAME" "$service" metrics 2> /dev/null | sed 's|^http://||')
    series=$(curl -s "http://${addr}/debug/metrics/prometheus" | grep -c "^sequencer_" || true)
    state=$(get_metric "$service" "sequencer_publish_state")
    echo "  $service: sequencer series=$series publish_state=$state"
  done
}

# Grep every validator's full log for a pattern; prints matching lines.
grep_validator_logs() {
  local pattern=$1
  local service
  for service in "${VALIDATORS[@]}"; do
    kurtosis service logs -a "$ENCLAVE_NAME" "$service" 2> /dev/null |
      grep -E "$pattern" | sed "s|^|${service}: |"
  done
}

stop_store() {
  local service
  for service in $SEQSTORE_SERVICES; do
    echo "Stopping $service..."
    kurtosis service stop "$ENCLAVE_NAME" "$service"
  done
}

start_store() {
  local service
  for service in $SEQSTORE_SERVICES; do
    echo "Starting $service..."
    kurtosis service start "$ENCLAVE_NAME" "$service"
  done
}

stop_validator() {
  echo "Stopping validator $1..."
  kurtosis service stop "$ENCLAVE_NAME" "$1"
}

start_validator() {
  echo "Starting validator $1..."
  kurtosis service start "$ENCLAVE_NAME" "$1"
}

# Raw JSON-RPC POST against a service; prints the response body, empty when
# the service has no reachable rpc port (e.g. stopped).
rpc_post() {
  local service_name=$1 payload=$2 rpc_url
  rpc_url=$(get_rpc_url "$service_name")
  if [ -z "$rpc_url" ]; then
    echo ""
    return
  fi
  curl -s -X POST -H 'Content-Type: application/json' -d "$payload" "$rpc_url"
}

# The validator currently producing: the one whose publish_entries advances
# over a short probe window (only the elected producer streams to the
# store). Empty when none is identifiable.
active_producer() {
  local i before after delta best="" bestdelta=0
  declare -a b
  for i in "${!VALIDATORS[@]}"; do
    b[$i]=$(get_metric "${VALIDATORS[$i]}" "sequencer_publish_entries")
  done
  sleep "$PRODUCER_PROBE_SECONDS"
  for i in "${!VALIDATORS[@]}"; do
    after=$(get_metric "${VALIDATORS[$i]}" "sequencer_publish_entries")
    before=${b[$i]}
    delta=$((${after%.*} - ${before%.*}))
    if [ "$delta" -gt "$bestdelta" ]; then
      bestdelta=$delta
      best="${VALIDATORS[$i]}"
    fi
  done
  echo "$best"
}

# First validator whose service name is not $1.
other_validator() {
  local exclude=$1 service
  for service in "${VALIDATORS[@]}"; do
    if [ "$service" != "$exclude" ]; then
      echo "$service"
      return
    fi
  done
}

wait_for_block() {
  local target=$1
  local timeout=$2
  local start_time=$SECONDS elapsed current

  while true; do
    elapsed=$((SECONDS - start_time))
    if [ $elapsed -gt "$timeout" ]; then
      echo "Timeout waiting for block $target (after ${timeout}s)"
      return 1
    fi

    current=$(get_block_number "${VALIDATORS[0]}")
    echo "Current block: $current / $target ($(printf '%02dm:%02ds' $((elapsed / 60)) $((elapsed % 60))))"

    if [ "$current" -ge "$target" ]; then
      return 0
    fi

    sleep "$SLEEP_INTERVAL"
  done
}
