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

# Never leave a background load generator running if the suite exits early.
trap stop_load EXIT

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

  # Follow-model steady state: one owner per height, so nothing is displaced.
  # A displaced record means a preconfirmation was revoked in normal running.
  local displaced
  displaced=$(sum_validator_metric "sequencer_reconcile_displacedrecords")
  if [ "$displaced" -ne 0 ]; then
    echo "Records displaced during steady-state operation (displaced=$displaced, want 0)"
    return 1
  fi

  echo "All ${#VALIDATORS[@]} publishers live; $entries entries published; displaced=0"
}

# Test: start transaction load and confirm it reaches blocks. Windows must
# carry transactions for the later auditor check to mean anything (a revoked
# preconf is a tx dropped from a superseded window) and for the takeover to
# exercise real preconfirmations. Load runs in the background for the rest of
# the suite and is stopped before the audit. When polycli is unavailable the
# load is skipped, not failed — the suite still runs, just without the
# load-dependent coverage.
test_load_flowing() {
  echo ""
  echo "Test: transaction load reaches blocks"
  echo ""

  start_load
  if [ -z "$LOAD_PID" ]; then
    echo "Load not running; skipping verification (load-dependent checks will be vacuous)"
    return 0
  fi

  local start_time=$SECONDS elapsed txc
  while true; do
    elapsed=$((SECONDS - start_time))
    txc=$(get_block_txcount "${VALIDATORS[0]}")

    if [ "${txc:-0}" -gt 0 ]; then
      echo "Load flowing: latest block carries $txc transactions"
      return 0
    fi

    if [ "$elapsed" -gt "$LOAD_VERIFY_TIMEOUT" ]; then
      echo "Load started but no transactions are landing in blocks"
      tail -20 "$LOAD_LOG" 2> /dev/null
      return 1
    fi

    echo "Waiting for load to land (${elapsed}s)"
    sleep "$SLEEP_INTERVAL"
  done
}

# Test: "pending" state stays readable on every validator, producer or not.
# Regression guard: a signer outside the active producer set used to stop
# refreshing its pending snapshot (Prepare failed, commit never ran, its
# pathdb trie layers were GC'd), so eth_call / eth_getBalance against
# "pending" returned "missing trie node / layer stale" on non-producing
# nodes while "latest" stayed fine.
test_pending_state_readable() {
  echo ""
  echo "Test: 'pending' state is readable on all validators (producer and non-producer)"
  echo ""

  local addr='0x0000000000000000000000000000000000000001'
  local probe
  probe='{"jsonrpc":"2.0","method":"eth_getBalance","params":["'"$addr"'","pending"],"id":1}'

  local service resp err result bad=0
  for service in "${VALIDATORS[@]}"; do
    resp=$(rpc_post "$service" "$probe")
    err=$(echo "$resp" | jq -r '.error.message // ""')
    result=$(echo "$resp" | jq -r '.result // ""')

    if [ -n "$err" ]; then
      echo "  $service: pending read FAILED: $err"
      bad=1
    elif [ -z "$result" ]; then
      echo "  $service: pending read returned no result: $resp"
      bad=1
    else
      echo "  $service: pending OK ($result)"
    fi
  done

  if [ "$bad" -ne 0 ]; then
    echo "A validator cannot serve 'pending' state — the non-producer pending-snapshot regression"
    return 1
  fi

  echo "All ${#VALIDATORS[@]} validators serve 'pending' state"
}

# Test: the chain survives losing its active producer. Stopping the
# producer's bor must not wedge sequencing — a backup rotates in and keeps
# sealing. (A store window on a displaced parent used to arm a sticky hold
# that refused the seal barrier indefinitely.) The stopped validator then
# rejoins cleanly. Stopping only the el keeps that node's heimdall voting,
# so the 3/4 quorum needed for downtime rotation holds.
test_producer_takeover() {
  echo ""
  echo "Test: producer takeover keeps the chain live and the publisher rejoins"
  echo ""

  local producer survivor
  producer=$(active_producer)
  if [ -z "$producer" ]; then
    echo "Could not identify the active producer (no validator streaming)"
    return 1
  fi
  survivor=$(other_validator "$producer")
  echo "Active producer: $producer; querying survivor: $survivor"

  local adopt_before supersede_before h0
  adopt_before=$(sum_validator_metric "sequencer_reconcile_adopt")
  supersede_before=$(sum_validator_metric "sequencer_reconcile_supersede")
  h0=$(get_block_number "$survivor")

  stop_validator "$producer"
  echo "Producer stopped at block $h0; waiting for rotation + resumed production..."

  local start_time=$SECONDS elapsed h1 produced
  while true; do
    elapsed=$((SECONDS - start_time))
    h1=$(get_block_number "$survivor")
    produced=$((h1 - h0))

    if [ "$produced" -ge "$TAKEOVER_MIN_BLOCKS" ]; then
      echo "Chain advanced $produced blocks after takeover ($h0 -> $h1) in ${elapsed}s"
      break
    fi

    if [ "$elapsed" -gt "$TAKEOVER_TIMEOUT_SECONDS" ]; then
      echo "Chain did not advance $TAKEOVER_MIN_BLOCKS blocks after takeover (produced=$produced) — sequencing may have wedged"
      grep_validator_logs "Not sealing|sticky" | tail -20
      start_validator "$producer"
      return 1
    fi

    echo "Waiting for takeover: produced=$produced/$TAKEOVER_MIN_BLOCKS (${elapsed}s)"
    sleep "$SLEEP_INTERVAL"
  done

  # Evidence, not asserted: adoption fires only if the dead producer left a
  # dangling (unsealed) window, and a displaced-parent takeover supersedes
  # by design — both depend on timing we do not control here.
  local adopt_after supersede_after
  adopt_after=$(sum_validator_metric "sequencer_reconcile_adopt")
  supersede_after=$(sum_validator_metric "sequencer_reconcile_supersede")
  echo "Evidence: adopt $adopt_before -> $adopt_after, supersede $supersede_before -> $supersede_after"

  start_validator "$producer"
  echo "Producer restarted; waiting for it to rejoin publishing..."

  local rejoin_start=$SECONDS state
  while true; do
    elapsed=$((SECONDS - rejoin_start))
    state=$(get_metric "$producer" "sequencer_publish_state")

    # 1 live and 5 contending are healthy rejoin states; 4 failed is not.
    if [ "${state%.*}" = "1" ] || [ "${state%.*}" = "5" ]; then
      echo "$producer rejoined (publish_state=$state) in ${elapsed}s"
      break
    fi

    if [ "$elapsed" -gt "$REJOIN_TIMEOUT_SECONDS" ]; then
      echo "$producer did not rejoin healthy (publish_state=$state)"
      return 1
    fi

    echo "Waiting for rejoin: publish_state=$state (${elapsed}s)"
    sleep "$SLEEP_INTERVAL"
  done

  local failed
  failed=$(count_validators_with_metric "sequencer_publish_state" "4")
  if [ "$failed" -ne 0 ]; then
    echo "$failed validators in a failed publish state after takeover"
    return 1
  fi

  echo "Takeover verified: chain stayed live, $producer rejoined, 0 failed publishers"
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

# Test: the independent auditor sees no revoked or reordered preconfs over
# the whole run. The auditor is a separate follower of the store log (not
# the producer's self-report), so it catches a producer that supersedes,
# drops, or reorders content even if its own metrics disagree. It classifies
# every superseded generation; a benign one drops nothing and preserves
# order (empty-open churn at restarts/boundaries), a real one drops
# transactions (revoked preconfs) or reorders them.
#
# The suite runs transaction load through the disruptive phases (see
# test_load_flowing), so "dropped" and "reordered" are exercised — a takeover
# that revoked a preconfirmation would leave dropped transactions here.
# Reordering is only fully provoked by independent senders; a single loader's
# nonce order limits it, so treat reordered as best-effort. Also guards
# against a supersession storm (the pre-follow-model churn regression). If
# polycli was unavailable the phases ran empty and this asserts the absence
# of violations rather than provoking them.
test_auditor_no_real_violations() {
  echo ""
  echo "Test: the independent auditor reports no revoked or reordered preconfirmations"
  echo ""

  local logs revocations dropped_lines reorder_lines
  logs=$(kurtosis service logs -a "$ENCLAVE_NAME" "$AUDITOR_SERVICE" 2> /dev/null | grep "auditor: block" || true)

  revocations=$(echo "$logs" | grep -c "superseded" || true)
  # A real revocation drops >=1 preconf: "N dropped" with N>0.
  dropped_lines=$(echo "$logs" | grep -cE ", [1-9][0-9]* dropped" || true)
  reorder_lines=$(echo "$logs" | grep -c "reordered=true" || true)

  echo "Auditor: $revocations supersession(s), $dropped_lines with dropped preconfs, $reorder_lines reordered"

  if [ "$dropped_lines" -ne 0 ] || [ "$reorder_lines" -ne 0 ]; then
    echo "Auditor found real violations (dropped or reordered preconfirmations):"
    echo "$logs" | grep -E ", [1-9][0-9]* dropped|reordered=true" | tail -20
    return 1
  fi

  echo "No revoked or reordered preconfirmations ($revocations benign churn supersession(s))"
}

run_all_tests() {
  local failed=0

  # Clean-chain check first; then bring load up so every later phase (outage,
  # recovery, takeover) runs with transactions in the windows.
  test_publishers_live || failed=1
  if [ $failed -eq 0 ]; then
    test_load_flowing || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_pending_state_readable || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_store_outage_liveness || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_recovery_floors_at_finality || failed=1
  fi
  # Takeover last: it stops a validator and restarts it, so keep it after the
  # outage/recovery sequence that needs every validator up. Run under load so
  # a revoked preconfirmation would leave dropped transactions for the audit.
  if [ $failed -eq 0 ]; then
    test_producer_takeover || failed=1
  fi

  # Stop load, then let the store settle so the auditor has processed the
  # trailing supersessions before we read its evidence.
  stop_load
  sleep "$SLEEP_INTERVAL"

  # Independent audit last: it inspects the auditor's evidence for the whole
  # run (outage, recovery, and takeover included).
  if [ $failed -eq 0 ]; then
    test_auditor_no_real_violations || failed=1
  fi

  echo ""
  if [ $failed -ne 0 ]; then
    echo "Sequence-store e2e tests FAILED"
    exit 1
  fi
  echo "All sequence-store e2e tests passed"
}

run_all_tests
