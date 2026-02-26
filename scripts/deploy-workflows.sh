#!/usr/bin/env bash
#
# Deploy workflow JSON files to the n8n instance.
#
# Usage:
#   ./scripts/deploy-workflows.sh                  # deploy all medika_preorder workflows
#   ./scripts/deploy-workflows.sh workflows/medika_preorder_00_error_handler.json  # deploy one
#
# Behavior:
#   - If a workflow with the same name already exists in n8n, it updates it (by injecting the existing ID)
#   - If no match is found, it creates a new workflow
#   - Requires jq for JSON manipulation

set -euo pipefail

CONTAINER_NAME="n8n"
CONTAINER_WORKFLOW_DIR="/home/node/workflows"

# Check dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: sudo pacman -S jq"
  exit 1
fi

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

echo "Found ${#files[@]} workflow file(s) to deploy."
echo ""

if [ ${#files[@]} -eq 0 ]; then
  echo "No workflow files found."
  exit 0
fi

# Export existing workflows to match by name
# n8n exports as newline-delimited JSON objects, so we slurp them into an array
echo "Fetching existing workflows from n8n..."
existing_json=$(docker exec "$CONTAINER_NAME" n8n export:workflow --all --output=/dev/stdout 2>/dev/null | jq -s '.' || echo "[]")

imported=0
updated=0
failed=0

for file in "${files[@]}"; do
  filename=$(basename "$file")
  workflow_name=$(jq -r '.name' "$file")

  echo -n "  $filename ($workflow_name) ... "

  # Check if a workflow with this name already exists (take first match)
  existing_id=$(echo "$existing_json" | jq -r --arg name "$workflow_name" '[.[] | select(.name == $name) | .id] | first // empty' 2>/dev/null || true)

  if [ -n "$existing_id" ]; then
    # Inject the existing ID so n8n updates instead of creating a duplicate
    tmp_file=$(mktemp)
    jq --arg id "$existing_id" '.id = $id' "$file" > "$tmp_file"
    cp "$tmp_file" "workflows/.deploy_tmp_${filename}"
    rm "$tmp_file"

    container_path="$CONTAINER_WORKFLOW_DIR/.deploy_tmp_${filename}"
    if docker exec "$CONTAINER_NAME" n8n import:workflow --input="$container_path" > /dev/null 2>&1; then
      echo "UPDATED (id: $existing_id)"
      ((updated++))
    else
      echo "FAILED"
      ((failed++))
    fi
    rm -f "workflows/.deploy_tmp_${filename}"
  else
    # New workflow — import as-is
    container_path="$CONTAINER_WORKFLOW_DIR/$filename"
    if docker exec "$CONTAINER_NAME" n8n import:workflow --input="$container_path" > /dev/null 2>&1; then
      echo "CREATED"
      ((imported++))
    else
      echo "FAILED"
      ((failed++))
    fi
  fi
done

echo ""
echo "Done: $imported created, $updated updated, $failed failed (${#files[@]} total)"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
