#!/bin/bash

set -e

# Configuration
KURTOSIS_CONTAINER="l2-cl-1-heimdall-v2-bor-validator"
KURTOSIS_PORT_ID="http"

TC_IMAGE="gaiadocker/iproute2:3.3"
INTERFACE="eth0"
DELAY_TIME=10000
JITTER=1000
DURATION="15s"

# Get dynamic port from kurtosis
echo "Getting dynamic span API URL from kurtosis..."
SPAN_URL=$(kurtosis port print "$ENCLAVE_NAME" "$KURTOSIS_CONTAINER" "$KURTOSIS_PORT_ID")

if [[ -z "$SPAN_URL" ]]; then
  echo "❌ Failed to get span URL from kurtosis"
  exit 1
fi

echo "Using span API at: $SPAN_URL"
SPAN_API="${SPAN_URL}/bor/spans"

# Get latest span ID
echo "Fetching latest span..."
LATEST_SPAN_JSON=$(curl -s "${SPAN_API}/latest")
LATEST_SPAN_ID=$(echo "$LATEST_SPAN_JSON" | jq -r '.span.id')

if [[ -z "$LATEST_SPAN_ID" || "$LATEST_SPAN_ID" == "null" ]]; then
  echo "❌ Failed to fetch latest span ID"
  exit 1
fi

CURRENT_SPAN_ID=$((LATEST_SPAN_ID - 1))
echo "Latest span ID: $LATEST_SPAN_ID"
echo "Using current span ID: $CURRENT_SPAN_ID"

# Get current span
echo "Fetching current span (ID $CURRENT_SPAN_ID)..."
CURRENT_SPAN_JSON=$(curl -s "${SPAN_API}/${CURRENT_SPAN_ID}")

if [[ -z "$CURRENT_SPAN_JSON" || "$CURRENT_SPAN_JSON" == "null" ]]; then
  echo "❌ Failed to fetch current span"
  exit 1
fi

# Extract signer and validator ID
SIGNER=$(echo "$CURRENT_SPAN_JSON" | jq -r '.span.selected_producers[0].signer')
VALIDATOR_ID=$(echo "$CURRENT_SPAN_JSON" | jq -r \
  --arg signer "$SIGNER" '.span.validator_set.validators[] | select(.signer | ascii_downcase == ($signer | ascii_downcase)) | .val_id')

echo "$CURRENT_SPAN_JSON" | jq '{span: {id: .span.id, start_block: .span.start_block, end_block: .span.end_block, selected_producers: .span.selected_producers}}'

if [[ -z "$VALIDATOR_ID" ]]; then
  echo "❌ Failed to find validator ID for signer $SIGNER"
  exit 1
fi

echo "Current producer signer address: $SIGNER"
echo "Corresponding validator ID: $VALIDATOR_ID"

# Find container name
PREFIX="l2-el-${VALIDATOR_ID}-bor-heimdall-v2-validator--"
echo "Looking for container with prefix: $PREFIX"

CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep "^${PREFIX}")

if [[ -z "$CONTAINER_NAME" ]]; then
  echo "❌ No running container found for validator ID $VALIDATOR_ID"
  exit 1
fi

echo "Found container: $CONTAINER_NAME"

# Build target IPs for l2-el containers
TARGET_IPS=()
echo "Finding IPs for containers with prefix 'l2-el'..."
for name in $(docker ps --format "{{.Names}}" | grep "^l2-el"); do
  echo "  Checking container: $name"
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
  if [[ -n "$ip" ]]; then
    TARGET_IPS+=("$ip")
    echo "    ✓ Adding target: $name ($ip)"
  else
    echo "    ✗ No IP found for: $name"
    echo "    Debug - docker inspect output:"
    docker inspect -f '{{json .NetworkSettings.Networks}}' "$name" | jq .
  fi
done

if [[ ${#TARGET_IPS[@]} -eq 0 ]]; then
  echo "❌ No l2-el containers found to target"
  exit 1
fi

# Build tc commands
TC_CMDS="tc qdisc add dev $INTERFACE root handle 1: prio priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
TC_CMDS="$TC_CMDS && tc qdisc add dev $INTERFACE parent 1:1 handle 10: sfq"
TC_CMDS="$TC_CMDS && tc qdisc add dev $INTERFACE parent 1:2 handle 20: sfq"
TC_CMDS="$TC_CMDS && tc qdisc add dev $INTERFACE parent 1:3 handle 30: netem delay ${DELAY_TIME}ms ${JITTER}ms"

for ip in "${TARGET_IPS[@]}"; do
  TC_CMDS="$TC_CMDS && tc filter add dev $INTERFACE parent 1:0 protocol ip u32 match ip dst ${ip}/32 flowid 1:3"
done

echo "Applying ${DELAY_TIME}ms network delay for ${DURATION} to l2-el containers only..."
echo "Command: docker run --rm --net container:$CONTAINER_NAME --cap-add NET_ADMIN --entrypoint sh $TC_IMAGE -c \"$TC_CMDS\""

date +"%Y-%m-%d %H:%M:%S"

# Apply tc rules
docker run --rm --net "container:$CONTAINER_NAME" --cap-add NET_ADMIN --entrypoint sh "$TC_IMAGE" -c "$TC_CMDS"

echo "tc rules applied, waiting for duration: $DURATION"
sleep "$DURATION"

# Clean up tc rules
echo "Removing tc rules from $CONTAINER_NAME..."
docker run --rm --net "container:$CONTAINER_NAME" --cap-add NET_ADMIN "$TC_IMAGE" qdisc del dev "$INTERFACE" root 2>/dev/null || true

echo "✅ Delay command applied and cleaned up for container: $CONTAINER_NAME (targeting l2-el containers only)"
