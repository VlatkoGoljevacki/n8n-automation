#!/usr/bin/env bash
#
# Deploy workflow JSON files to the n8n instance via CLI import.
#
# Usage:
#   ./scripts/deploy-workflows.sh                  # deploy all medika_preorder workflows
#   ./scripts/deploy-workflows.sh workflows/medika_preorder_00_error_handler.json  # deploy one
#
# The n8n import command updates existing workflows (matched by ID inside the JSON)
# or creates new ones if the ID doesn't exist yet.

set -euo pipefail

CONTAINER_NAME="n8n"
CONTAINER_WORKFLOW_DIR="/home/node/workflows"

# Check container is running
if ! docker inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Error: Container '$CONTAINER_NAME' is not running."
  echo "Start it with: docker compose up -d"
  exit 1
fi

# Determine which files to deploy
if [ $# -gt 0 ]; then
  files=("$@")
else
  files=(workflows/medika_preorder_*.json)
fi

if [ ${#files[@]} -eq 0 ]; then
  echo "No workflow files found to deploy."
  exit 0
fi

imported=0
failed=0

for file in "${files[@]}"; do
  filename=$(basename "$file")
  container_path="$CONTAINER_WORKFLOW_DIR/$filename"

  echo -n "Importing $filename ... "

  if docker exec "$CONTAINER_NAME" n8n import:workflow --input="$container_path" 2>&1; then
    echo "OK"
    ((imported++))
  else
    echo "FAILED"
    ((failed++))
  fi
done

echo ""
echo "Done: $imported imported, $failed failed (out of ${#files[@]} total)"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
