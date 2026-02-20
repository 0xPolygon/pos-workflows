#!/bin/bash
# Self-contained utilities for post-upgrade health checks.
# After run.sh, L2 containers are raw docker containers (not kurtosis-managed),
# so we discover RPC/API URLs via docker network IPs instead of kurtosis port print.
# L1 is still kurtosis-managed.

ENCLAVE_NAME="${ENCLAVE_NAME:-pos}"

log_info() {
	echo "[INFO] [$(date '+%H:%M:%S')] $*"
}

log_error() {
	echo "[ERROR] [$(date '+%H:%M:%S')] $*" >&2
}

log_pass() {
	echo "[PASS] $*"
}

log_fail() {
	echo "[FAIL] $*" >&2
}

log_header() {
	echo ""
	echo "# $*"
	echo ""
}

# Get the docker network IP for a container in the kurtosis enclave.
get_container_ip() {
	local container="$1"
	docker inspect -f '{{(index .NetworkSettings.Networks "kt-'"$ENCLAVE_NAME"'").IPAddress}}' "$container" 2>/dev/null
}

# List all L2 EL container names (bor/erigon).
get_el_containers() {
	docker ps --filter "network=kt-$ENCLAVE_NAME" --format '{{.Names}}' |
		grep 'l2-el' |
		sort -V
}

# List all L2 CL container names (heimdall), excluding rabbitmq sidecars.
get_cl_containers() {
	docker ps --filter "network=kt-$ENCLAVE_NAME" --format '{{.Names}}' |
		grep 'l2-cl' |
		grep -v 'rabbitmq' |
		sort -V
}

# Get RPC URL (port 8545) for an L2 EL container via published port.
get_el_rpc_url() {
	local container="$1"
	local host_port
	host_port=$(docker port "$container" 8545 2>/dev/null | head -1 | sed 's/0.0.0.0/127.0.0.1/')
	if [[ -z "$host_port" ]]; then
		return 1
	fi
	echo "http://$host_port"
}

# Get HTTP API URL (port 1317) for an L2 CL container via published port.
get_cl_api_url() {
	local container="$1"
	local host_port
	host_port=$(docker port "$container" 1317 2>/dev/null | head -1 | sed 's/0.0.0.0/127.0.0.1/')
	if [[ -z "$host_port" ]]; then
		return 1
	fi
	echo "http://$host_port"
}

# Get the first available CL API URL.
get_first_cl_api_url() {
	local container
	container=$(get_cl_containers | head -n 1)
	if [[ -z "$container" ]]; then
		log_error "No CL containers found"
		return 1
	fi
	get_cl_api_url "$container"
}

# Get the first available EL RPC URL.
get_first_el_rpc_url() {
	local container
	container=$(get_el_containers | head -n 1)
	if [[ -z "$container" ]]; then
		log_error "No EL containers found"
		return 1
	fi
	get_el_rpc_url "$container"
}

# Get block number from an EL RPC URL.
get_block_number() {
	local rpc_url="$1"
	cast bn --rpc-url "$rpc_url" 2>/dev/null
}

# Get L1 RPC URL (still kurtosis-managed).
get_l1_rpc_url() {
	echo "http://$(kurtosis port print "$ENCLAVE_NAME" el-1-geth-lighthouse rpc 2>/dev/null)"
}

# Get contract addresses from kurtosis file artifacts.
get_contract_addresses() {
	kurtosis files inspect "$ENCLAVE_NAME" matic-contract-addresses contractAddresses.json 2>/dev/null
}

# Poll until a command's numeric output >= target, or timeout.
# Usage: poll_until_gte "command_string" target timeout_secs interval_secs
poll_until_gte() {
	local cmd="$1"
	local target="$2"
	local timeout="${3:-300}"
	local interval="${4:-5}"

	local end_time=$(($(date +%s) + timeout))
	while true; do
		if [[ $(date +%s) -ge $end_time ]]; then
			log_error "Timeout after ${timeout}s waiting for value >= ${target}"
			return 1
		fi
		local result
		result=$(eval "$cmd" 2>/dev/null)
		log_info "current=$result target=$target"
		if [[ "$result" =~ ^[0-9]+$ ]] && [[ "$result" -ge "$target" ]]; then
			return 0
		fi
		sleep "$interval"
	done
}
