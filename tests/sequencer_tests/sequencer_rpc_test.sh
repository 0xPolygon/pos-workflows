#!/bin/bash
set -e

# Preconfirmation RPC e2e. The functional suite covers the publisher side —
# whether validators write to the store. This covers the consumer side: what
# an RPC client actually sees, and whether it can be trusted.
#
# The central claim under test is that a preconfirmed receipt tells the truth.
# Manual testing checked this over 452k receipts by re-fetching every one from
# the canonical chain afterwards and comparing; this is the same check at a
# size CI can afford.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sequencer_test_utils.sh"

echo "Starting kurtosis sequence-store RPC tests..."

check_required_tools

ENCLAVE_NAME=${ENCLAVE_NAME:-"kurtosis-sequencer-e2e"}
export ENCLAVE_NAME

setup_service_lists

# Never leave a background load generator behind if the suite exits early.
trap stop_load EXIT

# Sample size for the correctness check. Small enough to send and settle in
# CI, large enough that a systematic mismatch shows up rather than hiding in
# one unlucky transaction.
# Load itself comes from the functional suite's start_load (LOAD_RATE), so
# only the sample size is configured here.
PRECONF_TX_COUNT=${PRECONF_TX_COUNT:-120}
PRECONF_SETTLE_SECONDS=${PRECONF_SETTLE_SECONDS:-60}
# Fraction of sampled transactions that must have been served as a
# preconfirmation for the correctness check to mean anything.
PRECONF_MIN_COVERAGE_PCT=${PRECONF_MIN_COVERAGE_PCT:-50}
PRECONF_COLLECT_TIMEOUT=${PRECONF_COLLECT_TIMEOUT:-120}
# Transactions checked per pending-block read, and how many times one receipt
# is polled before giving up on it.
PRECONF_BATCH=${PRECONF_BATCH:-6}
PRECONF_POLL_ATTEMPTS=${PRECONF_POLL_ATTEMPTS:-10}
SENT_HASHES=${SENT_HASHES:-"/tmp/sequencer-preconf-hashes.txt"}

# Multicall3, at its canonical cross-chain address. go-ethereum clients probe
# this during gas estimation, and reading its code at "pending" failed
# intermittently in manual testing — a flake that would surface as random
# estimateGas failures for any geth-based client.
MULTICALL3=${MULTICALL3:-"0xca11bde05977b3631167028862be2a173976ca11"}
PENDING_PROBE_ITERATIONS=${PENDING_PROBE_ITERATIONS:-25}

rpc_call() {
  local service=$1 method=$2 params=$3
  rpc_post "$service" '{"jsonrpc":"2.0","method":"'"$method"'","params":'"$params"',"id":1}'
}

# Test: a preconfirmed receipt is identifiable. There is no block hash to key
# on before canonicalisation, so the receipt carries preconfirmation:true with
# a null blockHash — that pairing is the client's only signal, so it is worth
# asserting directly rather than inferring from timing.
#
# Only transactions caught while still speculative count. One that reached the
# canonical chain before we looked says nothing either way, so it is excluded
# rather than scored as a miss: counting those measures how fast the harness
# polls, not whether the node preconfirms. The damning case is a receipt that
# is speculative and yet unmarked.
test_preconf_receipt_shape() {
  echo ""
  echo "Test: preconfirmed receipts are marked and carry no block hash"
  echo ""

  start_load
  if [ -z "$LOAD_PID" ]; then
    echo "Load not running; cannot observe preconfirmations, skipping"
    return 0
  fi

  : > "$SENT_HASHES"
  local start_time=$SECONDS pending hashes hash
  local preconfirmed=0 late=0 unmarked=0 unserved=0 sampled=0

  while [ "$sampled" -lt "$PRECONF_TX_COUNT" ] && [ $((SECONDS - start_time)) -lt "$PRECONF_COLLECT_TIMEOUT" ]; do
    pending=$(rpc_call "$RPC_NODE" "eth_getBlockByNumber" '["pending",true]')
    # A small slice per read: the pending block holds a backlog, and checking
    # all of it sequentially would age the tail out of its speculative window
    # before we got to it.
    hashes=$(echo "$pending" | jq -r '.result.transactions[]?.hash // empty' | head -"$PRECONF_BATCH")
    if [ -z "$hashes" ]; then
      sleep 1
      continue
    fi

    while read -r hash; do
      [ -n "$hash" ] || continue
      grep -qxF "$hash" "$SENT_HASHES" 2> /dev/null && continue
      echo "$hash" >> "$SENT_HASHES"
      sampled=$((sampled + 1))

      case "$(classify_receipt "$hash")" in
        preconfirmed) preconfirmed=$((preconfirmed + 1)) ;;
        late) late=$((late + 1)) ;;
        unmarked) unmarked=$((unmarked + 1)) ;;
        *) unserved=$((unserved + 1)) ;;
      esac
    done <<< "$hashes"
  done

  echo "sampled=$sampled preconfirmed=$preconfirmed already-canonical=$late unmarked=$unmarked never-served=$unserved"

  # A speculative receipt without the flag would let a client treat
  # unconfirmed state as final, which is the failure that matters most.
  if [ "$unmarked" -ne 0 ]; then
    echo "$unmarked receipt(s) had a null blockHash but no preconfirmation flag"
    return 1
  fi

  local observed=$((preconfirmed + unserved))
  if [ "$observed" -eq 0 ]; then
    echo "Every sampled transaction was already canonical; the window was never observed"
    return 1
  fi

  local pct=$((preconfirmed * 100 / observed))
  if [ "$pct" -lt "$PRECONF_MIN_COVERAGE_PCT" ]; then
    echo "Only ${pct}% of transactions caught pre-canonical were preconfirmed (want >=${PRECONF_MIN_COVERAGE_PCT}%)"
    return 1
  fi
  echo "Preconfirmation coverage ${pct}% of $observed transactions caught while speculative"
}

# One receipt, polled briefly because a transaction enters the pending block
# before its store round trip finishes. Prints exactly one of:
#   preconfirmed - marked, with a null blockHash
#   unmarked     - speculative receipt with no preconfirmation flag
#   late         - already canonical, so the window was missed
#   unserved     - no receipt inside the window
classify_receipt() {
  local hash=$1 attempt=0 resp flag block_hash
  while [ "$attempt" -lt "$PRECONF_POLL_ATTEMPTS" ]; do
    resp=$(rpc_call "$RPC_NODE" "eth_getTransactionReceipt" '["'"$hash"'"]')
    flag=$(echo "$resp" | jq -r '.result.preconfirmation // ""')
    block_hash=$(echo "$resp" | jq -r 'if .result == null then "none" elif .result.blockHash == null then "null" else "set" end')

    if [ "$flag" = "true" ]; then
      if [ "$block_hash" != "null" ]; then
        # Breaks the pairing the client depends on; surfaced by the caller's
        # unmarked/fail path rather than silently accepted.
        echo "unmarked"
        return
      fi
      echo "preconfirmed"
      return
    fi
    if [ "$block_hash" = "set" ]; then
      echo "late"
      return
    fi
    if [ "$block_hash" = "null" ]; then
      echo "unmarked"
      return
    fi
    attempt=$((attempt + 1))
  done
  echo "unserved"
}

# Test: every transaction that was preconfirmed ended up on the canonical
# chain with the same result. This is the claim that matters — a fast answer
# that later turns out wrong is worse than a slow one.
test_preconf_matches_canonical() {
  echo ""
  echo "Test: preconfirmed transactions match the canonical chain"
  echo ""

  if [ ! -s "$SENT_HASHES" ]; then
    echo "No sampled hashes; skipping"
    return 0
  fi

  # Stop adding load first, or the tail of the sample is still in flight.
  stop_load

  echo "Letting the chain settle for ${PRECONF_SETTLE_SECONDS}s"
  sleep "$PRECONF_SETTLE_SECONDS"

  local hash resp status block_hash matched=0 missing=0 mismatched=0
  while read -r hash; do
    [ -n "$hash" ] || continue
    resp=$(rpc_call "$RPC_NODE" "eth_getTransactionReceipt" '["'"$hash"'"]')
    status=$(echo "$resp" | jq -r '.result.status // ""')
    block_hash=$(echo "$resp" | jq -r '.result.blockHash // "null"')

    if [ -z "$status" ]; then
      missing=$((missing + 1))
      echo "  $hash has no receipt at all after settling"
      continue
    fi
    # Canonical now means a real block hash and a success status. A
    # preconfirmation that never canonicalised, or reverted after being
    # served, is the mismatch class this check exists for.
    if [ "$block_hash" = "null" ]; then
      mismatched=$((mismatched + 1))
      echo "  $hash still has no block hash after settling"
      continue
    fi
    if [ "$status" != "0x1" ]; then
      mismatched=$((mismatched + 1))
      echo "  $hash canonicalised with status $status"
      continue
    fi
    matched=$((matched + 1))
  done < "$SENT_HASHES"

  echo "matched=$matched mismatched=$mismatched missing=$missing"
  if [ "$mismatched" -ne 0 ] || [ "$missing" -ne 0 ]; then
    echo "Sampled transactions did not all reach the canonical chain cleanly"
    return 1
  fi
  echo "All $matched sampled transactions canonicalised successfully"
}

# Test: eth_sendRawTransactionSync is registered. It was missing from a
# deployed private RPC during manual testing, which returns -32601 and breaks
# any client built against the sync path. Signing a raw transaction needs
# tooling CI does not install, so this asserts the method is wired rather than
# exercising the full round trip.
test_send_raw_transaction_sync_is_registered() {
  echo ""
  echo "Test: eth_sendRawTransactionSync is a registered method"
  echo ""

  local resp code
  resp=$(rpc_call "$RPC_NODE" "eth_sendRawTransactionSync" '["0x00"]')
  code=$(echo "$resp" | jq -r '.error.code // "none"')

  # -32601 is "method not found". Any other error means the method exists and
  # rejected the deliberately invalid payload, which is what we want to see.
  if [ "$code" = "-32601" ]; then
    echo "eth_sendRawTransactionSync is not registered on $RPC_NODE"
    return 1
  fi
  echo "Method is registered (rejected the invalid payload with code $code)"
}

# Test: reading "pending" state is stable, not intermittent. Reading
# multicall3's code at "pending" failed on some calls and not others in manual
# testing; go-ethereum clients make exactly this call while estimating gas, so
# an intermittent failure here becomes random estimateGas failures.
test_pending_reads_are_stable() {
  echo ""
  echo "Test: pending-state reads are stable over $PENDING_PROBE_ITERATIONS attempts"
  echo ""

  local i resp err failures=0
  for i in $(seq 1 "$PENDING_PROBE_ITERATIONS"); do
    resp=$(rpc_call "$RPC_NODE" "eth_getCode" '["'"$MULTICALL3"'","pending"]')
    err=$(echo "$resp" | jq -r '.error.message // ""')
    if [ -n "$err" ]; then
      failures=$((failures + 1))
      echo "  attempt $i failed: $err"
    fi
  done

  if [ "$failures" -ne 0 ]; then
    echo "$failures/$PENDING_PROBE_ITERATIONS pending reads failed; clients estimating gas would see this"
    return 1
  fi
  echo "All $PENDING_PROBE_ITERATIONS pending reads succeeded"
}

# Test: the invalidation ledger answers, and rejects a reversed range rather
# than returning something meaningless.
test_invalid_preconf_blocks_contract() {
  echo ""
  echo "Test: bor_getInvalidPreconfBlocks honours its contract"
  echo ""

  local head head_hex from_hex resp records err
  head=$(get_block_number "$RPC_NODE")
  head_hex=$(printf '0x%x' "$head")
  from_hex=$(printf '0x%x' $((head > 50 ? head - 50 : 0)))

  resp=$(rpc_call "$RPC_NODE" "bor_getInvalidPreconfBlocks" '["'"$from_hex"'","'"$head_hex"'"]')
  err=$(echo "$resp" | jq -r '.error.message // ""')
  if [ -n "$err" ]; then
    echo "Query over [$from_hex,$head_hex] failed: $err"
    return 1
  fi

  # An array is the contract; the entries are whatever the run produced. Each
  # one must name a block and a reason, or a client cannot act on it.
  records=$(echo "$resp" | jq -r 'if (.result | type) == "array" then "ok" else "bad" end')
  if [ "$records" != "ok" ]; then
    echo "Expected an array, got: $(echo "$resp" | jq -c '.result')"
    return 1
  fi

  local bad
  bad=$(echo "$resp" | jq -r '[.result[] | select((.number == null) or (.reason == null))] | length')
  if [ "${bad:-0}" -ne 0 ]; then
    echo "$bad record(s) missing number or reason: $(echo "$resp" | jq -c '.result')"
    return 1
  fi

  echo "Ledger returned $(echo "$resp" | jq -r '.result | length') record(s) over the last 50 blocks"
  echo "$resp" | jq -c '.result'

  # A reversed range is a caller error and must be reported as one.
  resp=$(rpc_call "$RPC_NODE" "bor_getInvalidPreconfBlocks" '["'"$head_hex"'","'"$from_hex"'"]')
  if [ -z "$(echo "$resp" | jq -r '.error.message // ""')" ]; then
    echo "A reversed range was accepted; expected an error"
    return 1
  fi
  echo "Reversed range rejected"
}

# Test: the audit watermarks distinguish "nothing invalid here" from "this
# window was never compared". Skipped where the method is absent, so this
# lands before the audit ships and goes live on its own once it does.
test_preconf_audit_status() {
  echo ""
  echo "Test: bor_getPreconfAuditStatus reports the audit boundary"
  echo ""

  local resp code audited unaudited
  resp=$(rpc_call "$RPC_NODE" "bor_getPreconfAuditStatus" '[]')
  code=$(echo "$resp" | jq -r '.error.code // "none"')
  if [ "$code" = "-32601" ]; then
    echo "bor_getPreconfAuditStatus not available on this build; skipping"
    return 0
  fi
  if [ "$code" != "none" ]; then
    echo "Unexpected error: $(echo "$resp" | jq -c '.error')"
    return 1
  fi

  audited=$(echo "$resp" | jq -r '.result.auditedThrough // "null"')
  unaudited=$(echo "$resp" | jq -r '.result.unauditedThrough // "null"')
  echo "auditedThrough=$audited unauditedThrough=$unaudited"

  # A consumer that has been following the tip since Rio should have audited
  # something; a null watermark here means the audit never ran.
  if [ "$audited" = "null" ]; then
    echo "No audit watermark on a node that has been following the store"
    return 1
  fi

  # The marks meeting means the whole audited range went uncompared, which is
  # what exceeding store retention looks like. On a short devnet run it means
  # the consumer compared nothing, so it is worth surfacing.
  if [ "$unaudited" != "null" ] && [ "$unaudited" = "$audited" ]; then
    echo "unauditedThrough equals auditedThrough: nothing in the audited range was compared"
    return 1
  fi
}

run_all_tests() {
  local failed=0

  wait_for_block "$POST_RIO_BLOCK" "$POST_RIO_TIMEOUT_SECONDS"

  # Shape first: it sends the sample the canonical check then reuses.
  test_preconf_receipt_shape || failed=1
  if [ $failed -eq 0 ]; then
    test_preconf_matches_canonical || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_send_raw_transaction_sync_is_registered || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_pending_reads_are_stable || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_invalid_preconf_blocks_contract || failed=1
  fi
  if [ $failed -eq 0 ]; then
    test_preconf_audit_status || failed=1
  fi

  echo ""
  if [ $failed -ne 0 ]; then
    echo "Sequence-store RPC tests FAILED"
    exit 1
  fi
  echo "All sequence-store RPC tests passed"
}

run_all_tests
