#!/bin/bash
set -e

if [ -z "${ENABLE_PRODUCER_PLANNED_DOWNTIME_TEST:-}" ]; then
	echo "ENABLE_PRODUCER_PLANNED_DOWNTIME_TEST not set, skipping producer planned downtime setup"
	exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Producer planned downtime: scheduling downtime tx..."
(cd "$SCRIPT_DIR" && go run . --mode setup)
echo "Producer planned downtime setup completed"
