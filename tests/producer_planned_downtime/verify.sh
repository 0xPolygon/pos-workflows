#!/bin/bash
set -e

if [ -z "${ENABLE_PRODUCER_PLANNED_DOWNTIME_TEST:-}" ]; then
  echo "ENABLE_PRODUCER_PLANNED_DOWNTIME_TEST not set, skipping producer planned downtime verify"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Producer planned downtime: verifying downtime blocks..."
(cd "$SCRIPT_DIR" && go run . --mode verify)
echo "Producer planned downtime verification completed"
