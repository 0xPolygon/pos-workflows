#!/bin/bash
set -e

# Standalone EVM opcode and precompile coverage test.
#
# Runs two test suites:
#   1. polycli LoadTester (60 opcodes + 10 precompiles) - arithmetic, logic, context opcodes, etc.
#   2. evm-stress contract (26 actions) - MCOPY, CREATE, CREATE2, CODECOPY, EXTCODECOPY, Point Evaluation, etc.
#
# Usage: ./evm_opcode_test.sh [RPC_URL]
#
# Required:
#   PK          - Private key (env var)
#   RPC_URL     - JSON-RPC endpoint (first CLI arg, or env var)
#
# Optional:
#   GAS_PRICE       - Gas price in wei (default: 30000000000 / 30 gwei)
#   TX_MINE_TIMEOUT - Seconds to wait for mining (default: 120)
#
# Requirements: cast, jq, polycli
# Exit codes: 0 = all pass, 1 = failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/evm_test_helpers.sh"

GAS_PRICE=${GAS_PRICE:-30000000000}
TX_MINE_TIMEOUT=${TX_MINE_TIMEOUT:-120}

declare -A tx_hashes
declare -A tx_status
current_nonce=0

check_prerequisites() {
  if [ -n "$1" ]; then
    RPC_URL="$1"
  fi

  if [ -z "$RPC_URL" ]; then
    echo "Error: RPC_URL is required (pass as first argument or set env var)"
    exit 1
  fi

  if [ -z "$PK" ]; then
    echo "Error: PK environment variable is required"
    exit 1
  fi

  for tool in polycli cast jq; do
    if ! command -v "$tool" &>/dev/null; then
      echo "Error: $tool is required but not found"
      exit 1
    fi
  done

  SENDER_ADDR=$(cast wallet address "$PK")
  echo "RPC URL: $RPC_URL"
  echo "Sender: $SENDER_ADDR"
}

verify_receipts() {
  echo ""
  echo "Verifying transaction receipts..."

  passed=0
  failed=0
  failed_tests=()

  # evm-stress actions
  for action in "${ACTION_CODES[@]}"; do
    local name="${EVM_STRESS_ACTIONS[$action]}"

    if [ "${tx_status[$name]}" = "send_failed" ]; then
      failed=$((failed + 1))
      failed_tests+=("evm-stress/$name:send_failed")
      continue
    fi

    if [ "${tx_status[$name]}" = "timeout" ]; then
      failed=$((failed + 1))
      failed_tests+=("evm-stress/$name:timeout")
      continue
    fi

    tx_hash="${tx_hashes[$name]}"
    receipt=$(timeout 30 cast receipt "$tx_hash" --rpc-url "$RPC_URL" --json 2>/dev/null)
    status=$(echo "$receipt" | jq -r '.status // "0x0"')

    if [ "$status" = "0x1" ]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      failed_tests+=("evm-stress/$name:reverted")
    fi
  done

  # polycli LoadTester opcodes + precompiles
  ALL_LOADTESTER=("${OPCODES[@]}" "${PRECOMPILE_NAMES[@]}")

  for test_name in "${ALL_LOADTESTER[@]}"; do
    if [ "${tx_status[$test_name]}" = "send_failed" ]; then
      failed=$((failed + 1))
      failed_tests+=("loadtester/$test_name:send_failed")
      continue
    fi

    if [ "${tx_status[$test_name]}" = "timeout" ]; then
      failed=$((failed + 1))
      failed_tests+=("loadtester/$test_name:timeout")
      continue
    fi

    tx_hash="${tx_hashes[$test_name]}"
    receipt=$(timeout 30 cast receipt "$tx_hash" --rpc-url "$RPC_URL" --json 2>/dev/null)
    status=$(echo "$receipt" | jq -r '.status // "0x0"')

    if [ "$status" = "0x1" ]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      failed_tests+=("loadtester/$test_name:reverted")
    fi
  done

  total=$((passed + failed))
  echo ""
  echo "Results: $passed/$total passed (26 evm-stress + 70 loadtester)"

  if [ $failed -gt 0 ]; then
    echo "Failed tests:"
    for ft in "${failed_tests[@]}"; do
      echo "  - $ft"
    done
    return 1
  fi

  return 0
}

main() {
  echo "Starting EVM opcode and precompile coverage test..."
  check_prerequisites "$1"

  # Suite 1: polycli LoadTester (arithmetic, logic, context opcodes, etc.)
  # Run first since polycli manages its own nonces internally
  deploy_load_tester
  send_opcode_transactions
  send_precompile_transactions

  # Suite 2: evm-stress (MCOPY, CREATE, CREATE2, CODECOPY, EXTCODECOPY, Point Evaluation, etc.)
  deploy_evm_stress
  send_evm_stress_transactions

  wait_for_mining
  verify_receipts
}

main "$@"
