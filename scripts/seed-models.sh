#!/usr/bin/env bash
set -euo pipefail

# Trigger training on all ML modules and reload inference models.
# Run after `tilt up` when all services are healthy.

SERVICES=(
  "m1-health-stress:8001:8002"
  "m2-irrigation-wateruse:8003:8004"
  "m3-soil-degradation:8005:8006"
)

for entry in "${SERVICES[@]}"; do
  IFS=: read -r name train_port infer_port <<< "$entry"

  echo "=== Training $name (port $train_port) ==="
  RUN_ID=$(curl -s -X POST "http://localhost:$train_port/train" \
    -H "Content-Type: application/json" \
    -d '{"epochs": 10}' | python3 -c "import sys,json; print(json.load(sys.stdin)['run_id'])")

  echo "  Run ID: $RUN_ID"

  for i in $(seq 1 30); do
    sleep 2
    STATUS=$(curl -s "http://localhost:$train_port/train/$RUN_ID" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
    echo "  Status: $STATUS"
    if [ "$STATUS" = "completed" ]; then
      break
    elif [ "$STATUS" = "failed" ]; then
      echo "  ERROR: Training failed for $name"
      exit 1
    fi
  done

  echo "  Reloading model on inference (port $infer_port)..."
  curl -s -X POST "http://localhost:$infer_port/reload-model" | python3 -m json.tool
  echo ""
done

echo "All models trained and loaded."
