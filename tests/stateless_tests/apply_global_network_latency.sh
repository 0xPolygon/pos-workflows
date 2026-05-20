#!/bin/bash
set -e

# Source utility functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/kurtosis_test_utils.sh"

TC_IMAGE="gaiadocker/iproute2:3.3"

echo "Network latency configuration:"
echo "- Duration: $NETWORK_LATENCY_DURATION"
echo "- Interface: $INTERFACE"
echo "- L2-EL delay: ${DELAY_EL}ms, jitter: ${JITTER_EL}ms"
echo "- L2-CL delay: ${DELAY_CL}ms, jitter: ${JITTER_CL}ms"

# Apply tc netem rules to a single container targeting specific IPs
apply_tc_delay() {
  local container_name="$1"
  local delay="$2"
  local jitter="$3"
  local interface="$4"
  shift 4
  local target_ips=("$@")

  # Build chained tc commands
  local tc_cmds="tc qdisc add dev $interface root handle 1: prio priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
  tc_cmds="$tc_cmds && tc qdisc add dev $interface parent 1:1 handle 10: sfq"
  tc_cmds="$tc_cmds && tc qdisc add dev $interface parent 1:2 handle 20: sfq"
  tc_cmds="$tc_cmds && tc qdisc add dev $interface parent 1:3 handle 30: netem delay ${delay}ms ${jitter}ms"

  for ip in "${target_ips[@]}"; do
    tc_cmds="$tc_cmds && tc filter add dev $interface parent 1:0 protocol ip u32 match ip dst ${ip}/32 flowid 1:3"
  done

  echo "  Applying tc rules to $container_name (delay=${delay}ms, jitter=${jitter}ms, targets=${#target_ips[@]})"
  docker run --rm --net "container:$container_name" --cap-add NET_ADMIN --entrypoint sh "$TC_IMAGE" -c "$tc_cmds"
}

# Remove tc rules from a single container
remove_tc_delay() {
  local container_name="$1"
  local interface="$2"
  echo "  Removing tc rules from $container_name"
  docker run --rm --net "container:$container_name" --cap-add NET_ADMIN "$TC_IMAGE" qdisc del dev "$interface" root 2>/dev/null || true
}

# Apply network latency to all containers matching a prefix, wait for duration, then clean up
run_netem() {
  local prefix="$1"
  local delay="$2"
  local jitter="$3"

  local containers=()
  local target_ips=()

  echo "Finding containers with prefix '${prefix}'..."
  for name in $(docker ps --format "{{.Names}}" | grep "^${prefix}"); do
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
    if [[ -n "$ip" ]]; then
      containers+=("$name")
      target_ips+=("$ip")
    fi
  done

  if [[ ${#containers[@]} -eq 0 ]]; then
    echo "No running containers found with prefix '${prefix}'"
    return 1
  fi

  echo "Applying netem for '${prefix}' with delay ${delay}ms and jitter ${jitter}ms to ${#containers[@]} containers"

  # Apply tc rules to each container
  for container_name in "${containers[@]}"; do
    apply_tc_delay "$container_name" "$delay" "$jitter" "$INTERFACE" "${target_ips[@]}"
  done

  echo "Waiting for duration: $NETWORK_LATENCY_DURATION"
  sleep "$NETWORK_LATENCY_DURATION"

  # Clean up tc rules
  echo "Removing netem rules for '${prefix}'..."
  for container_name in "${containers[@]}"; do
    remove_tc_delay "$container_name" "$INTERFACE"
  done
}

# Trap SIGINT (Ctrl+C) to clean up and exit gracefully
cleanup() {
  echo "Ctrl+C pressed. Cleaning up all tc rules..."
  for name in $(docker ps --format "{{.Names}}" | grep -E "^(l2-el|l2-cl)"); do
    remove_tc_delay "$name" "$INTERFACE"
  done
  exit 0
}
trap cleanup SIGINT

# Run netem for each group concurrently with their respective parameters
run_netem "l2-el" "$DELAY_EL" "$JITTER_EL" &
run_netem "l2-cl" "$DELAY_CL" "$JITTER_CL" &

# Wait for both background jobs to finish
wait
