#!/bin/bash
# Pipeline-specific assertions for the pipeline-enabled kurtosis leg
# (POS-3697), consumed by bor's kurtosis-pipeline-e2e.yml workflow with
# configs/kurtosis-pipeline-e2e.yml.
#
# Runs after the stateless suite has passed, so lockstep and hash consensus
# for participants 1-8 are already proven; this script checks the pipeline
# metrics per node role and brings the released-image baseline (participant
# 9, outside the stateless suite's service lists) into the hash-consensus
# check.
set -euo pipefail

# Source utility functions from the stateless suite (service naming, block
# helpers, tool checks).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../stateless_tests/kurtosis_test_utils.sh"

check_required_tools

ENCLAVE_NAME=${ENCLAVE_NAME:-"kurtosis-pipeline-e2e"}
export ENCLAVE_NAME

# Nodes by role (indices fixed by configs/kurtosis-pipeline-e2e.yml).
PIPELINED_WITNESS_VALIDATORS=(
  "$SERVICE_PREFIX_VALIDATOR-1-$SERVICE_SUFFIX_VALIDATOR"
  "$SERVICE_PREFIX_VALIDATOR-2-$SERVICE_SUFFIX_VALIDATOR"
  "$SERVICE_PREFIX_VALIDATOR-3-$SERVICE_SUFFIX_VALIDATOR"
)
STATELESS_VALIDATORS=(
  "$SERVICE_PREFIX_VALIDATOR-4-$SERVICE_SUFFIX_VALIDATOR"
  "$SERVICE_PREFIX_VALIDATOR-5-$SERVICE_SUFFIX_VALIDATOR"
)
PIPELINED_PLAIN_RPC="$SERVICE_PREFIX_VALIDATOR-6-$SERVICE_SUFFIX_RPC"
PIPELINED_WITNESS_RPC="$SERVICE_PREFIX_VALIDATOR-7-$SERVICE_SUFFIX_RPC"
STATELESS_RPC="$SERVICE_PREFIX_VALIDATOR-8-$SERVICE_SUFFIX_RPC"
BASELINE_VALIDATOR="$SERVICE_PREFIX_VALIDATOR-9-$SERVICE_SUFFIX_VALIDATOR"
REFERENCE_NODE="$SERVICE_PREFIX_VALIDATOR-1-$SERVICE_SUFFIX_VALIDATOR"

failures=0
fail() {
  echo "❌ $1"
  failures=$((failures + 1))
}

metric() {
  local service=$1 name=$2
  local url
  url=$(kurtosis port print "$ENCLAVE_NAME" "$service" metrics)
  curl -s -m 10 "$url/debug/metrics/prometheus" | awk -v m="$name" '$1 == m {print $2; found=1} END {if (!found) print 0}'
}

echo "=== Pipeline metrics per node role ==="
for svc in "${PIPELINED_WITNESS_VALIDATORS[@]}"; do
  src=$(metric "$svc" chain_imports_pipelined_src_count)
  mismatch=$(metric "$svc" chain_imports_pipelined_root_mismatch)
  witness=$(metric "$svc" chain_witness_size_bytes_count)
  echo "$svc: src=$src mismatch=$mismatch witness=$witness"
  [ "${src%.*}" -gt 0 ] || fail "$svc: pipeline not active (src=$src)"
  [ "${mismatch%.*}" -eq 0 ] || fail "$svc: root mismatch detected ($mismatch)"
  [ "${witness%.*}" -gt 0 ] || fail "$svc: no witnesses produced"
done

for svc in "${STATELESS_VALIDATORS[@]}" "$STATELESS_RPC"; do
  src=$(metric "$svc" chain_imports_pipelined_src_count)
  echo "$svc: src=$src (stateless — pipeline must self-gate off)"
  [ "${src%.*}" -eq 0 ] || fail "$svc: pipeline ran on a stateless-sync node (src=$src)"
done

src=$(metric "$PIPELINED_PLAIN_RPC" chain_imports_pipelined_src_count)
mismatch=$(metric "$PIPELINED_PLAIN_RPC" chain_imports_pipelined_root_mismatch)
witness=$(metric "$PIPELINED_PLAIN_RPC" chain_witness_size_bytes_count)
echo "$PIPELINED_PLAIN_RPC: src=$src mismatch=$mismatch witness=$witness"
[ "${src%.*}" -gt 0 ] || fail "$PIPELINED_PLAIN_RPC: pipeline not active"
[ "${mismatch%.*}" -eq 0 ] || fail "$PIPELINED_PLAIN_RPC: root mismatch detected"
[ "${witness%.*}" -eq 0 ] || fail "$PIPELINED_PLAIN_RPC: produced witnesses with witness production off"

# Witness provenance: on a non-mining full-sync witness producer, every
# witness must come from the pipelined SRC completion path — the counters
# track each other 1:1 (small tolerance for the in-flight block at sample
# time). This is the assertion that proves stateless nodes are consuming
# pipelined-SRC-produced witnesses rather than inline ones.
src=$(metric "$PIPELINED_WITNESS_RPC" chain_imports_pipelined_src_count)
mismatch=$(metric "$PIPELINED_WITNESS_RPC" chain_imports_pipelined_root_mismatch)
witness=$(metric "$PIPELINED_WITNESS_RPC" chain_witness_size_bytes_count)
echo "$PIPELINED_WITNESS_RPC: src=$src mismatch=$mismatch witness=$witness"
[ "${mismatch%.*}" -eq 0 ] || fail "$PIPELINED_WITNESS_RPC: root mismatch detected"
diff=$((${witness%.*} - ${src%.*}))
[ "${diff#-}" -le 2 ] || fail "$PIPELINED_WITNESS_RPC: witness/src divergence ($witness vs $src) — witnesses not coming from the pipelined SRC path"
[ "${src%.*}" -gt 0 ] || fail "$PIPELINED_WITNESS_RPC: pipeline not active"

echo "=== Released-image baseline consensus check ==="
ref_hash=$(get_block_hash "$REFERENCE_NODE" "$TARGET_BLOCK")
base_hash=$(get_block_hash "$BASELINE_VALIDATOR" "$TARGET_BLOCK")
echo "block $TARGET_BLOCK: reference=$ref_hash baseline=$base_hash"
if [ -z "$base_hash" ] || [ "$base_hash" = "null" ]; then
  fail "$BASELINE_VALIDATOR: could not fetch block $TARGET_BLOCK (baseline lagging or down)"
elif [ "$base_hash" != "$ref_hash" ]; then
  fail "$BASELINE_VALIDATOR: hash mismatch vs pipelined reference at block $TARGET_BLOCK"
fi

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures pipeline check(s) failed"
  exit 1
fi
echo "✅ all pipeline checks passed"
