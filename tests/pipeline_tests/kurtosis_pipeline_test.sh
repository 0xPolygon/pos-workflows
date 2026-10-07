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
#
# Two node classes self-gate pipelined SRC off, and this script asserts that
# they do:
#
#   - stateless-sync nodes, which consume a witness rather than computing a
#     root of their own;
#   - witness-PRODUCING nodes, because the SRC witness is derived from a
#     FlatDiff and CommitSnapshot drains the shared, attribution-free reader
#     into it. That record carries the speculative block prefetcher's reads,
#     and how far the prefetcher got before the block finished is wall-clock
#     dependent, so two nodes importing the same block derive witnesses of
#     different sizes -- which WIT/2's cross-peer page-count check treats as
#     a misbehaving peer. See bor
#     core.TestPipelinedSRCDiffCarriesBlockPrefetcherReads.
#
# That leaves participant 6, the plain pipelined rpc node, as the one node
# exercising the pipelined SRC path end to end. When read attribution lands
# on the shared reader, bor drops its guard and the witness nodes below move
# back into the pipelined group.
#
# TRANSITIONAL: bor's workflow pins this repo at main, so a strict `src == 0`
# here would fail every bor PR until the guard is on bor develop. Until then
# the witness nodes report src without asserting on it; the safety property
# (root mismatch) and witness production stay strict throughout. Tighten the
# two marked checks to `-eq 0` once bor #2405 has merged.
set -euo pipefail

# Source utility functions from the stateless suite (service naming, block
# helpers, tool checks).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../stateless_tests/kurtosis_test_utils.sh"

check_required_tools

ENCLAVE_NAME=${ENCLAVE_NAME:-"kurtosis-pipeline-e2e"}
export ENCLAVE_NAME

# Nodes by role (indices fixed by configs/kurtosis-pipeline-e2e.yml).
WITNESS_VALIDATORS=(
  "$SERVICE_PREFIX_VALIDATOR-1-$SERVICE_SUFFIX_VALIDATOR"
  "$SERVICE_PREFIX_VALIDATOR-2-$SERVICE_SUFFIX_VALIDATOR"
  "$SERVICE_PREFIX_VALIDATOR-3-$SERVICE_SUFFIX_VALIDATOR"
)
STATELESS_VALIDATORS=(
  "$SERVICE_PREFIX_VALIDATOR-4-$SERVICE_SUFFIX_VALIDATOR"
  "$SERVICE_PREFIX_VALIDATOR-5-$SERVICE_SUFFIX_VALIDATOR"
)
PIPELINED_PLAIN_RPC="$SERVICE_PREFIX_VALIDATOR-6-$SERVICE_SUFFIX_RPC"
WITNESS_RPC="$SERVICE_PREFIX_VALIDATOR-7-$SERVICE_SUFFIX_RPC"
STATELESS_RPC="$SERVICE_PREFIX_VALIDATOR-8-$SERVICE_SUFFIX_RPC"
BASELINE_NODE="$SERVICE_PREFIX_VALIDATOR-9-$SERVICE_SUFFIX_RPC"
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
# Witness production forces pipelined SRC off, so src goes to 0 per node
# (reported, not asserted -- see TRANSITIONAL above).
# Witnesses must still be produced: the witness counter moves on the import
# path, and a validator that dominates block production imports next to
# nothing (it seals its blocks instead), so assert that one in aggregate.
total_witness=0
for svc in "${WITNESS_VALIDATORS[@]}"; do
  src=$(metric "$svc" chain_imports_pipelined_src_count)
  mismatch=$(metric "$svc" chain_imports_pipelined_root_mismatch)
  witness=$(metric "$svc" chain_witness_size_bytes_count)
  echo "$svc: src=$src mismatch=$mismatch witness=$witness (witness producer — pipeline must self-gate off)"
  total_witness=$((total_witness + ${witness%.*}))
  # TIGHTEN AFTER bor #2405: [ "${src%.*}" -eq 0 ] || fail "$svc: pipeline ran on a witness-producing node (src=$src)"
  [ "${mismatch%.*}" -eq 0 ] || fail "$svc: root mismatch detected ($mismatch)"
done
[ "$total_witness" -gt 0 ] || fail "witness validators: no witnesses produced on any node"

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

# Witness provenance: this node never mines, so every block reaches it by
# import and it must still produce a witness for each. Once the bor guard is
# on develop those come from the inline, non-pipelined path with pipelined
# SRC self-gated off; a node showing both counters moving is running the
# leaky FlatDiff witness path.
src=$(metric "$WITNESS_RPC" chain_imports_pipelined_src_count)
mismatch=$(metric "$WITNESS_RPC" chain_imports_pipelined_root_mismatch)
witness=$(metric "$WITNESS_RPC" chain_witness_size_bytes_count)
echo "$WITNESS_RPC: src=$src mismatch=$mismatch witness=$witness"
[ "${mismatch%.*}" -eq 0 ] || fail "$WITNESS_RPC: root mismatch detected"
# TIGHTEN AFTER bor #2405: [ "${src%.*}" -eq 0 ] || fail "$WITNESS_RPC: pipeline ran on a witness-producing node (src=$src)"
[ "${witness%.*}" -gt 0 ] || fail "$WITNESS_RPC: no witnesses produced"

echo "=== Released-image baseline consensus check ==="
ref_hash=$(get_block_hash "$REFERENCE_NODE" "$TARGET_BLOCK")
base_hash=$(get_block_hash "$BASELINE_NODE" "$TARGET_BLOCK")
echo "block $TARGET_BLOCK: reference=$ref_hash baseline=$base_hash"
if [ -z "$base_hash" ] || [ "$base_hash" = "null" ]; then
  fail "$BASELINE_NODE: could not fetch block $TARGET_BLOCK (baseline lagging or down)"
elif [ "$base_hash" != "$ref_hash" ]; then
  fail "$BASELINE_NODE: hash mismatch vs pipelined reference at block $TARGET_BLOCK"
fi

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures pipeline check(s) failed"
  exit 1
fi
echo "✅ all pipeline checks passed"
