#!/usr/bin/env bash
#
# Deploy/pull workflow JSON files to/from the n8n instance via REST API.
#
# Usage:
#   ./scripts/deploy-workflows.sh                  # deploy all medika_preorder workflows
#   ./scripts/deploy-workflows.sh workflows/foo.json  # deploy one
#   ./scripts/deploy-workflows.sh pull              # pull all medika_preorder workflows
#   ./scripts/deploy-workflows.sh pull workflows/foo.json  # pull one
#
# Requires:
#   - jq, python3
#   - N8N_API_KEY env var (or set in .env) — generate in n8n Settings > API
#   - N8N_API_URL env var (default: http://localhost:5678)
#
# Behavior:
#   - deploy: If a workflow with the same name already exists, updates it (PUT).
#             If no match, creates a new workflow (POST).
#   - pull:   Fetches the workflow from n8n and writes it to the local JSON file,
#             preserving UI-configured values (credentials, folder IDs, etc.).

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

# ── Pull mode ────────────────────────────────────────────────────────
if [ "${1:-}" = "pull" ]; then
  shift
  if [ $# -gt 0 ]; then
    files=("$@")
  else
    files=(workflows/medika_preorder_*.json)
  fi

  echo "Pulling ${#files[@]} workflow(s) from n8n..."
  echo ""

  # Build name→id map
  existing_map=$(curl -s "${N8N_API_URL}/api/v1/workflows?limit=100" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for w in data.get('data', []):
    print(w['id'] + '\t' + w['name'])
" 2>/dev/null || true)

  pulled=0
  for file in "${files[@]}"; do
    filename=$(basename "$file")
    workflow_name=$(jq -r '.name' "$file")
    echo -n "  $filename ($workflow_name) ... "

    existing_id=$(echo "$existing_map" | awk -F'\t' -v name="$workflow_name" '$2 == name { print $1; exit }')

    if [ -z "$existing_id" ]; then
      echo "NOT FOUND in n8n (skipped)"
      continue
    fi

    # Fetch full workflow and clean up API-only fields
    curl -s "${N8N_API_URL}/api/v1/workflows/${existing_id}" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" | \
      python3 -c "
import sys, json
w = json.load(sys.stdin)
# Keep only fields we track in git
keep = {'name','nodes','connections','settings','tags','active'}
out = {k: v for k, v in w.items() if k in keep}
# Normalize: always set active=false in repo (activation is a runtime concern)
out['active'] = False
print(json.dumps(out, indent=2, ensure_ascii=False))
" > "$file"

    echo "PULLED (id: $existing_id)"
    pulled=$((pulled + 1))
  done

  echo ""
  echo "Done: $pulled pulled."
  exit 0
fi

# ── Deploy mode ──────────────────────────────────────────────────────
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
    # Fetch current server version, merge positions/credentials into local, then deploy
    http_code=$(curl -s "${N8N_API_URL}/api/v1/workflows/${existing_id}" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" | \
      python3 -c "
import sys, json

server = json.load(sys.stdin)
with open(sys.argv[1]) as f:
    local = json.load(f)

# Build lookup from server nodes by name
server_nodes = {n['name']: n for n in server.get('nodes', [])}

# Merge server-side properties into local nodes
for node in local.get('nodes', []):
    sn = server_nodes.get(node['name'])
    if sn:
        if 'position' in sn:
            node['position'] = sn['position']
        if 'credentials' in sn:
            node['credentials'] = sn['credentials']
        if 'webhookId' in sn:
            node['webhookId'] = sn['webhookId']

for key in ('active','id','versionId','tags','meta','updatedAt','createdAt'):
    local.pop(key, None)

json.dump(local, sys.stdout, ensure_ascii=False)
" "$file" | \
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
