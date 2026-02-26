#!/usr/bin/env bash
#
# Deploy workflow JSON files to the n8n instance via REST API.
#
# Usage:
#   ./scripts/deploy-workflows.sh                  # deploy all medika_preorder workflows
#   ./scripts/deploy-workflows.sh workflows/medika_preorder_00_error_handler.json  # deploy one
#
# Requires:
#   - jq
#   - N8N_API_KEY env var (or set in .env) — generate in n8n Settings > API
#   - N8N_API_URL env var (default: http://localhost:5678)
#
# Behavior:
#   - If a workflow with the same name already exists, it updates it (PUT)
#   - If no match is found, it creates a new workflow (POST)

set -euo pipefail

# Load .env if present (for N8N_API_KEY)
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    export "$line"
  done < .env
fi

N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"

# Check dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: sudo pacman -S jq"
  exit 1
fi

if [ -z "$N8N_API_KEY" ]; then
  echo "Error: N8N_API_KEY is not set."
  echo "Generate one in n8n: Settings > API, then add N8N_API_KEY to .env"
  exit 1
fi

# Verify API connectivity
http_code=$(curl -s -o /dev/null -w "%{http_code}" \
  "${N8N_API_URL}/api/v1/workflows?limit=1" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}")

if [ "$http_code" != "200" ]; then
  echo "Error: Cannot reach n8n API at ${N8N_API_URL} (HTTP $http_code)"
  echo "Check N8N_API_URL and N8N_API_KEY."
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

# Fetch existing workflows to match by name
# Use python to extract name→id mapping because the n8n API response may
# contain unescaped control characters in jsCode that break jq
existing_map=$(curl -s "${N8N_API_URL}/api/v1/workflows?limit=100" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for w in data.get('data', []):
    print(w['id'] + '\t' + w['name'])
" 2>/dev/null || true)

created=0
updated=0
failed=0

for file in "${files[@]}"; do
  filename=$(basename "$file")
  workflow_name=$(jq -r '.name' "$file")

  echo -n "  $filename ($workflow_name) ... "

  # Check if a workflow with this name already exists (first match)
  existing_id=$(echo "$existing_map" | awk -F'\t' -v name="$workflow_name" '$2 == name { print $1; exit }')

  if [ -n "$existing_id" ]; then
    # Update existing workflow (PUT) — pipe jq directly to curl to preserve JSON integrity
    http_code=$(jq 'del(.active, .id, .versionId, .tags, .meta, .updatedAt, .createdAt)' "$file" | \
      curl -s -o /dev/null -w "%{http_code}" \
      -X PUT "${N8N_API_URL}/api/v1/workflows/${existing_id}" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      -d @-)

    if [ "$http_code" = "200" ]; then
      echo "UPDATED (id: $existing_id)"
      updated=$((updated + 1))
    else
      echo "FAILED (HTTP $http_code)"
      failed=$((failed + 1))
    fi
  else
    # Create new workflow (POST) — pipe jq directly to curl to preserve JSON integrity
    http_code=$(jq 'del(.active, .id, .versionId, .tags, .meta, .updatedAt, .createdAt)' "$file" | \
      curl -s -o /dev/null -w "%{http_code}" \
      -X POST "${N8N_API_URL}/api/v1/workflows" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      -d @-)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
      echo "CREATED"
      created=$((created + 1))
    else
      echo "FAILED (HTTP $http_code)"
      failed=$((failed + 1))
    fi
  fi
done

echo ""
echo "Done: $created created, $updated updated, $failed failed (${#files[@]} total)"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
