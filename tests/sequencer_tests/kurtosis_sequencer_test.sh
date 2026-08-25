#!/bin/bash
set -e

# Sequence-store & publisher e2e: publishers come live after Rio, block
# production survives a store outage untouched, and recovery backfills
# floored at milestone finality (jumping the finalized gap) instead of
# re-publishing the whole outage window.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sequencer_test_utils.sh"

echo "Starting kurtosis sequence-store e2e tests..."

check_required_tools

ENCLAVE_NAME=${ENCLAVE_NAME:-"kurtosis-sequencer-e2e"}
export ENCLAVE_NAME

setup_service_lists

# Test 1: publishers are live once Rio activates.
# publish_state: 0 off, 1 live, 2 degraded, 3 resyncing, 4 failed, 5 contending.
test_publishers_live() {
  echo ""
  echo "Test 1: All validators publish to the store once Rio activates"
  echo ""

  wait_for_block "$POST_RIO_BLOCK" "$POST_RIO_TIMEOUT_SECONDS"

  local live
  live=$(count_validators_with_metric "sequencer_publish_state" "1")
  if [ "$live" -ne "${#VALIDATORS[@]}" ]; then
    echo "Only $live/${#VALIDATORS[@]} validators report sequencer_publish_state=1"
    dump_sequencer_metric_presence
    grep_validator_logs "sequencer|Sequencer" | tail -20
    return 1
  fi

  local entries
  entries=$(sum_validator_metric "sequencer_publish_entries")
  if [ "$entries" -le 0 ]; then
    echo "No entries published; the active producer is not streaming"
    return 1
  fi

  echo "All ${#VALIDATORS[@]} publishers live; $entries entries published"
}

# Test 2: block production never waits on the store. Stop the store for
# OUTAGE_SECONDS and require normal cadence throughout.
OUTAGE_START_BLOCK=0
test_store_outage_liveness() {
  echo ""
  echo "Test 2: Block production is stall-free through a ${OUTAGE_SECONDS}s store outage"
  echo ""

  stop_store

  OUTAGE_START_BLOCK=$(get_block_number "${VALIDATORS[0]}")
  echo "Outage begins at block $OUTAGE_START_BLOCK"
  sleep "$OUTAGE_SECONDS"

  local h1 produced
  h1=$(get_block_number "${VALIDATORS[0]}")
  produced=$((h1 - OUTAGE_START_BLOCK))
  echo "Produced $produced blocks during the outage (minimum $MIN_OUTAGE_BLOCKS)"

  if [ "$produced" -lt "$MIN_OUTAGE_BLOCKS" ]; then
    echo "Production stalled during the store outage"
    return 1
  fi

  local degraded
  degraded=$(count_validators_with_metric "sequencer_publish_state" "2")
  echo "$degraded validators report degraded (expected: the active producer at least)"
}

# Test 3: recovery floors the backfill at milestone finality. The finalized
# outage window is jumped (counted forward jump, logged floor), nothing is
# superseded, and publishing resumes.
test_recovery_floors_at_finality() {
  echo ""
  echo "Test 3: Recovery jumps the finalized gap and resumes publishing"
  echo ""

  start_store
  echo "Store restarted; settling for ${RECOVERY_SETTLE_SECONDS}s..."
  sleep "$RECOVERY_SETTLE_SECONDS"

  local start_time=$SECONDS elapsed jumps floor_lines live
  while true; do
    elapsed=$((SECONDS - start_time))
    if [ $elapsed -gt "$RECOVERY_TIMEOUT_SECONDS" ]; then
      echo "Timeout waiting for the floored backfill (after ${RECOVERY_TIMEOUT_SECONDS}s)"
      grep_validator_logs "Sequencer backfill|jumping finalized" | tail -20
      return 1
    fi

    jumps=$(sum_validator_metric "sequencer_reconcile_forwardjump")
    floor_lines=$(grep_validator_logs "Sequencer backfill jumping finalized heights" | wc -l | tr -d ' ')

    if [ "$jumps" -ge 1 ] && [ "$floor_lines" -ge 1 ]; then
      break
    fi

    echo "Waiting for recovery: forwardjump=$jumps floor-logs=$floor_lines"
    sleep "$SLEEP_INTERVAL"
  done

  echo "Milestone floor engaged:"
  grep_validator_logs "Sequencer backfill jumping finalized heights" | tail -4

  # The floor is a jump, never a supersession: any supersede here means the
  # chain and the store disagree.
  local supersedes
  supersedes=$(sum_validator_metric "sequencer_reconcile_supersede")
  if [ "$supersedes" -ne 0 ]; then
    echo "Recovery superseded store content (supersede=$supersedes, want 0)"
    return 1
  fi

  live=$(count_validators_with_metric "sequencer_publish_state" "1")
  if [ "$live" -ne "${#VALIDATORS[@]}" ]; then
    echo "Only $live/${#VALIDATORS[@]} publishers live after recovery"
    return 1
  fi

  # Publishing resumes: entries keep advancing after the recovery.
  local before after
  before=$(sum_validator_metric "sequencer_publish_entries")
  sleep 20
  after=$(sum_validator_metric "sequencer_publish_entries")
  if [ "$after" -le "$before" ]; then
    echo "Publishing did not resume after recovery ($before -> $after entries)"
    return 1
  fi

  echo "Recovery verified: forwardjump=$jumps supersede=0 publishers=$live entries $before -> $after"
}

run_all_tests() {
  local failed=0

  test_publishers_live || failed=1
  if [ $failed -eq 0 ]; then
    test_store_outage_liveness || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_recovery_floors_at_finality || failed=1
  fi

  echo ""
  if [ $failed -ne 0 ]; then
    echo "Sequence-store e2e tests FAILED"
    exit 1
  fi
  echo "All sequence-store e2e tests passed"
}

run_all_tests
