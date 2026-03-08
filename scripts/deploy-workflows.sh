#!/usr/bin/env bash
#
# Deploy/pull workflow JSON files to/from the n8n instance via REST API.
#
# Usage:
#   PROJECT=medika-preorders
#
#   ./scripts/deploy-workflows.sh $PROJECT                     # deploy all test workflows
#   ./scripts/deploy-workflows.sh $PROJECT pull                # pull test from server
#   ./scripts/deploy-workflows.sh $PROJECT publish             # activate test workflows
#   ./scripts/deploy-workflows.sh $PROJECT unpublish           # deactivate test workflows
#
#   ./scripts/deploy-workflows.sh $PROJECT --env prod deploy   # deploy prod workflows
#   ./scripts/deploy-workflows.sh $PROJECT --env prod pull     # pull prod from server
#
#   ./scripts/deploy-workflows.sh $PROJECT promote             # copy + transform files only
#   ./scripts/deploy-workflows.sh $PROJECT promote --deploy    # copy + transform + deploy
#
#   ./scripts/deploy-workflows.sh workflows/test/medika-preorders/01_orchestrator.json  # single file
#
# Requires:
#   - jq, python3
#   - N8N_API_KEY env var (or set in .env) — generate in n8n Settings > API
#   - N8N_API_URL env var (default: http://localhost:5678)
#
# Behavior:
#   - deploy: If a workflow with the same name already exists, updates it (PUT).
#             If no match, creates a new workflow (POST).
#             Pass 2 remaps sub-workflow IDs within the same namespace.
#   - pull:   Fetches the workflow from n8n and writes it to the local JSON file,
#             preserving UI-configured values (credentials, folder IDs, etc.).
#   - promote: Copies test → prod, transforms namespace and webhook paths.

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

# ── Workflow variable substitution ───────────────────────────────
# Replaces %%VAR%% placeholders with values from .env.workflow.{ENV} (deploy)
# and reverses the substitution on pull.
# Uses $ENV to select .env.workflow.test or .env.workflow.prod.
# Falls back to .env.workflow for backwards compatibility.
apply_workflow_vars() {
  local vars_file=".env.workflow.${ENV}"
  [ ! -f "$vars_file" ] && vars_file=".env.workflow"
  python3 -c "
import sys
vars = {}
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            key, _, value = line.partition('=')
            key, value = key.strip(), value.strip()
            if key and value:
                vars[key] = value
except FileNotFoundError:
    pass
content = sys.stdin.read()
for key, value in vars.items():
    content = content.replace('%%' + key + '%%', value)
sys.stdout.write(content)
" "$vars_file"
}

reverse_workflow_vars() {
  local vars_file=".env.workflow.${ENV}"
  [ ! -f "$vars_file" ] && vars_file=".env.workflow"
  python3 -c "
import sys
vars = {}
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            key, _, value = line.partition('=')
            key, value = key.strip(), value.strip()
            if key and value:
                vars[key] = value
except FileNotFoundError:
    pass
content = sys.stdin.read()
# Sort by value length descending to avoid partial replacements
for key, value in sorted(vars.items(), key=lambda x: len(x[1]), reverse=True):
    content = content.replace(value, '%%' + key + '%%')
sys.stdout.write(content)
" "$vars_file"
}

# ── Argument parsing ───────────────────────────────────────────────
ENV="test"
PROJECT=""
COMMAND="deploy"
SINGLE_FILE=""
PROMOTE_DEPLOY=false
FORCE_ACTIVATE=false

# Smart detection: if first arg is a file path, extract project and env
if [ $# -gt 0 ] && [[ "$1" == */* ]] && [[ "$1" == *.json ]]; then
  SINGLE_FILE="$1"
  shift
  # Extract env and project from path: workflows/{env}/{project}/file.json
  if [[ "$SINGLE_FILE" =~ workflows/([^/]+)/([^/]+)/ ]]; then
    ENV="${BASH_REMATCH[1]}"
    PROJECT="${BASH_REMATCH[2]}"
  else
    echo "Error: Cannot determine env/project from path: $SINGLE_FILE"
    echo "Expected: workflows/{env}/{project}/file.json"
    exit 1
  fi
else
  # First positional arg = project name (required)
  if [ $# -eq 0 ]; then
    echo "Usage: $0 <project> [--env test|prod] [command] [options]"
    echo ""
    echo "Commands: deploy (default), pull, publish, unpublish, promote"
    echo ""
    echo "Examples:"
    echo "  $0 medika-preorders                     # deploy test workflows"
    echo "  $0 medika-preorders pull                # pull test from server"
    echo "  $0 medika-preorders --env prod deploy   # deploy prod workflows"
    echo "  $0 medika-preorders promote             # test → prod (files only)"
    echo "  $0 medika-preorders promote --deploy    # test → prod + deploy"
    exit 1
  fi

  PROJECT="$1"
  shift

  # Parse remaining args
  while [ $# -gt 0 ]; do
    case "$1" in
      --env)
        ENV="${2:-test}"
        shift 2
        ;;
      --deploy)
        PROMOTE_DEPLOY=true
        shift
        ;;
      --force-activate)
        FORCE_ACTIVATE=true
        shift
        ;;
      deploy|pull|publish|unpublish|promote)
        COMMAND="$1"
        shift
        ;;
      *)
        echo "Error: Unknown argument: $1"
        exit 1
        ;;
    esac
  done
fi

WORKFLOW_DIR="workflows/${ENV}/${PROJECT}"

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

# ── Pre-deploy gates (lint + tests) ──────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ "$COMMAND" = "deploy" ] || [ "$COMMAND" = "promote" ]; then
  echo "Running lint checks..."
  if [ -n "$SINGLE_FILE" ]; then
    lint_target="$SINGLE_FILE"
  else
    lint_target="$PROJECT --env $ENV"
  fi
  if ! python3 "${SCRIPT_DIR}/lint-workflows.py" $lint_target; then
    echo ""
    echo "Deploy aborted: lint checks failed. Fix errors above before deploying."
    exit 1
  fi
  echo ""

  # Run tests if test files exist
  test_files=("${ROOT_DIR}"/tests/test_*.mjs)
  if [ -e "${test_files[0]}" ]; then
    echo "Running tests..."
    if ! node --test "${ROOT_DIR}"/tests/test_*.mjs; then
      echo ""
      echo "Deploy aborted: tests failed. Fix errors above before deploying."
      exit 1
    fi
    echo ""
  fi
fi

# Promote doesn't need API connectivity
if [ "$COMMAND" != "promote" ] || [ "$PROMOTE_DEPLOY" = true ]; then
  # Verify API connectivity
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    "${N8N_API_URL}/api/v1/workflows?limit=1" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}")

  if [ "$http_code" != "200" ]; then
    echo "Error: Cannot reach n8n API at ${N8N_API_URL} (HTTP $http_code)"
    echo "Check N8N_API_URL and N8N_API_KEY."
    exit 1
  fi
fi

# ── Helper: build name→id map from server ──────────────────────────
fetch_name_id_map() {
  curl -s "${N8N_API_URL}/api/v1/workflows?limit=100" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for w in data.get('data', []):
    if w.get('isArchived'):
        continue
    print(w['id'] + '\t' + w['name'])
" 2>/dev/null || true
}

# ── Helper: build name→id→active map from server ──────────────────
fetch_name_id_active_map() {
  curl -s "${N8N_API_URL}/api/v1/workflows?limit=100" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for w in data.get('data', []):
    if w.get('isArchived'):
        continue
    print(w['id'] + '\t' + w['name'] + '\t' + str(w.get('active', False)))
" 2>/dev/null || true
}

# ── Helper: resolve file list ─────────────────────────────────────
resolve_files() {
  if [ -n "$SINGLE_FILE" ]; then
    echo "$SINGLE_FILE"
  else
    local dir="$1"
    if [ ! -d "$dir" ]; then
      echo "Error: Directory not found: $dir" >&2
      exit 1
    fi
    # Sort for consistent ordering
    find "$dir" -maxdepth 1 -name '*.json' -type f | sort
  fi
}

# ── Helper: two-pass sub-workflow ID remapping ─────────────────────
remap_subworkflow_ids() {
  local namespace="$1"
  shift
  local files=("$@")

  echo ""
  echo "Pass 2: Remapping sub-workflow IDs for namespace [${namespace}]..."

  # Refresh name→id map from server
  local name_id_map
  name_id_map=$(fetch_name_id_map)

  local remapped=0
  local skipped=0

  for file in "${files[@]}"; do
    local filename
    filename=$(basename "$file")

    # Check if this workflow has any executeWorkflow nodes (not triggers)
    local has_execute
    has_execute=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    wf = json.load(f)
for n in wf.get('nodes', []):
    if n['type'] == 'n8n-nodes-base.executeWorkflow':
        print('yes')
        sys.exit(0)
print('no')
" "$file")

    if [ "$has_execute" = "no" ]; then
      continue
    fi

    local workflow_name
    workflow_name=$(jq -r '.name' "$file")

    # Find this workflow's server ID
    local wf_id
    wf_id=$(echo "$name_id_map" | awk -F'\t' -v name="$workflow_name" '$2 == name { print $1; exit }')

    if [ -z "$wf_id" ]; then
      echo "  $filename — not found on server (skip remap)"
      skipped=$((skipped + 1))
      continue
    fi

    # Remap executeWorkflow node IDs using the server's name→id map
    local patched_json
    patched_json=$(python3 -c "
import json, sys, re

name_id_map = {}
for line in sys.argv[2].strip().split('\n'):
    if '\t' in line:
        wid, wname = line.split('\t', 1)
        name_id_map[wname] = wid

namespace = sys.argv[3]

# Fetch current workflow from server to get latest state
import urllib.request
url = sys.argv[4] + '/api/v1/workflows/' + sys.argv[5]
req = urllib.request.Request(url, headers={'X-N8N-API-KEY': sys.argv[6]})
with urllib.request.urlopen(req) as resp:
    wf = json.load(resp)

changes = 0
for node in wf.get('nodes', []):
    if node['type'] != 'n8n-nodes-base.executeWorkflow':
        continue

    node_name = node['name']
    # Extract WF-XX prefix from node name (e.g., 'WF-03: Parse XLSX' → 'WF-03')
    match = re.match(r'(WF-\d+\w*)', node_name)
    if not match:
        continue
    wf_prefix = match.group(1)

    # Find server workflow matching [{namespace}] WF-XX: ...
    target_id = None
    for sname, sid in name_id_map.items():
        if '[' + namespace + ']' in sname and sname.split(']')[-1].strip().startswith(wf_prefix + ':'):
            target_id = sid
            break

    if not target_id:
        continue

    params = node.get('parameters', {})
    wid = params.get('workflowId', {})
    if isinstance(wid, dict) and wid.get('value') != target_id:
        wid['value'] = target_id
        changes += 1

if changes > 0:
    # Keep only fields the PUT endpoint accepts
    keep = {'name','nodes','connections','settings'}
    out = {k: v for k, v in wf.items() if k in keep}
    json.dump(out, sys.stdout, ensure_ascii=False)
else:
    print('NO_CHANGES')
" "$file" "$name_id_map" "$namespace" "$N8N_API_URL" "$wf_id" "$N8N_API_KEY")

    if [ "$patched_json" = "NO_CHANGES" ]; then
      echo "  $filename — IDs already correct"
      skipped=$((skipped + 1))
      continue
    fi

    # PUT the patched workflow back
    local http_code
    http_code=$(echo "$patched_json" | \
      curl -s -o /dev/null -w "%{http_code}" \
      -X PUT "${N8N_API_URL}/api/v1/workflows/${wf_id}" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      -d @-)

    if [ "$http_code" = "200" ]; then
      echo "  $filename — REMAPPED (id: $wf_id)"
      remapped=$((remapped + 1))
    else
      echo "  $filename — REMAP FAILED (HTTP $http_code)"
    fi
  done

  echo "  Remap done: $remapped remapped, $skipped unchanged."
}

# ── Determine namespace from env ───────────────────────────────────
if [ "$ENV" = "test" ]; then
  NAMESPACE="${PROJECT}-test"
else
  NAMESPACE="${PROJECT}"
fi

# ── Promote mode ───────────────────────────────────────────────────
if [ "$COMMAND" = "promote" ]; then
  SRC_DIR="workflows/test/${PROJECT}"
  DST_DIR="workflows/prod/${PROJECT}"

  if [ ! -d "$SRC_DIR" ]; then
    echo "Error: Source directory not found: $SRC_DIR"
    exit 1
  fi

  mkdir -p "$DST_DIR"

  echo "Promoting ${PROJECT}: test → prod"
  echo "  Source: $SRC_DIR"
  echo "  Dest:   $DST_DIR"
  echo ""

  promoted=0
  for src_file in "$SRC_DIR"/*.json; do
    filename=$(basename "$src_file")
    dst_file="${DST_DIR}/${filename}"

    python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    wf = json.load(f)

# Transform namespace: [project-test] → [project]
test_ns = sys.argv[2]
prod_ns = sys.argv[3]
wf['name'] = wf['name'].replace('[' + test_ns + ']', '[' + prod_ns + ']')

# Transform webhook paths: test-process-email → process-email
for node in wf.get('nodes', []):
    params = node.get('parameters', {})

    # Webhook node path
    path = params.get('path', '')
    if isinstance(path, str) and path.startswith('test-'):
        params['path'] = path[5:]  # strip 'test-' prefix

    # HTTP Request URL
    url = params.get('url', '')
    if isinstance(url, str) and 'webhook/test-' in url:
        params['url'] = url.replace('webhook/test-', 'webhook/')

# Transform test env vars to prod: \$env.X_TEST → \$env.X
content = json.dumps(wf, ensure_ascii=False)
for var in ['MEDIKA_ERP_URL', 'MEDIKA_ERP_USERNAME', 'MEDIKA_ERP_PASSWORD',
            'MS_GRAPH_MAILBOX_READ', 'MS_GRAPH_MAILBOX_SEND']:
    content = content.replace('\$env.' + var + '_TEST', '\$env.' + var)
wf = json.loads(content)

with open(sys.argv[4], 'w') as f:
    json.dump(wf, f, indent=2, ensure_ascii=False)
    f.write('\n')
" "$src_file" "${PROJECT}-test" "${PROJECT}" "$dst_file"

    prod_name=$(jq -r '.name' "$dst_file")
    echo "  $filename → $prod_name"
    promoted=$((promoted + 1))
  done

  echo ""
  echo "Done: $promoted file(s) promoted."

  if [ "$PROMOTE_DEPLOY" = true ]; then
    echo ""
    echo "Deploying prod workflows..."
    # Re-exec with prod env
    exec "$0" "$PROJECT" --env prod deploy
  fi

  exit 0
fi

# ── Resolve files for remaining commands ───────────────────────────
mapfile -t files < <(resolve_files "$WORKFLOW_DIR")

if [ ${#files[@]} -eq 0 ]; then
  echo "No workflow files found in ${WORKFLOW_DIR}."
  exit 0
fi

# ── Pull mode ────────────────────────────────────────────────────
if [ "$COMMAND" = "pull" ]; then
  echo "Pulling ${#files[@]} workflow(s) from n8n [${ENV}]..."
  echo ""

  existing_map=$(fetch_name_id_map)

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
" | reverse_workflow_vars > "$file"

    echo "PULLED (id: $existing_id)"
    pulled=$((pulled + 1))
  done

  echo ""
  echo "Done: $pulled pulled."
  exit 0
fi

# ── Publish/Unpublish mode ───────────────────────────────────────
if [ "$COMMAND" = "publish" ] || [ "$COMMAND" = "unpublish" ]; then
  if [ "$COMMAND" = "publish" ]; then
    verb="Activating"
    past="activated"
  else
    verb="Deactivating"
    past="deactivated"
  fi

  # Sort files by trigger type: sub-workflows first, then webhook, then scheduleTrigger.
  # This ensures dependencies are active before the workflows that call them.
  if [ "$COMMAND" = "publish" ]; then
    sorted_files=()
    for priority in sub webhook scheduleTrigger; do
      for file in "${files[@]}"; do
        trigger=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    wf = json.load(f)
for n in wf.get('nodes', []):
    t = n['type']
    if t in ('n8n-nodes-base.webhook', 'n8n-nodes-base.scheduleTrigger'):
        print(t.split('.')[-1])
        break
else:
    print('sub')
" "$file")
        if [ "$trigger" = "$priority" ]; then
          sorted_files+=("$file")
        fi
      done
    done
    files=("${sorted_files[@]}")
  fi

  echo "${verb} ${#files[@]} workflow(s) [${ENV}]..."
  echo ""

  existing_map=$(fetch_name_id_active_map)

  changed=0
  skipped=0
  failed=0
  for file in "${files[@]}"; do
    filename=$(basename "$file")
    workflow_name=$(jq -r '.name' "$file")
    echo -n "  $filename ($workflow_name) ... "

    existing_id=$(echo "$existing_map" | awk -F'\t' -v name="$workflow_name" '$2 == name { print $1; exit }')

    if [ -z "$existing_id" ]; then
      echo "NOT FOUND in n8n (skipped)"
      skipped=$((skipped + 1))
      continue
    fi

    # Never auto-activate entry-point workflows unless --force-activate is set
    if [ "$COMMAND" = "publish" ] && [ "$FORCE_ACTIVATE" = false ]; then
      wf_trigger=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    wf = json.load(f)
for n in wf.get('nodes', []):
    t = n['type']
    if t in ('n8n-nodes-base.webhook', 'n8n-nodes-base.scheduleTrigger'):
        print(t.split('.')[-1])
        break
else:
    print('sub')
" "$file")
      if [ "$wf_trigger" != "sub" ]; then
        echo "SKIPPED (${wf_trigger} — use --force-activate)"
        skipped=$((skipped + 1))
        continue
      fi
    fi

    # Check current state
    current_active=$(echo "$existing_map" | awk -F'\t' -v name="$workflow_name" '$2 == name { print $3; exit }')
    if [ "$COMMAND" = "publish" ] && [ "$current_active" = "True" ]; then
      echo "already active"
      skipped=$((skipped + 1))
      continue
    elif [ "$COMMAND" = "unpublish" ] && [ "$current_active" = "False" ]; then
      echo "already inactive"
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$COMMAND" = "publish" ]; then
      endpoint="activate"
    else
      endpoint="deactivate"
    fi
    response_body=$(curl -s -w "\n%{http_code}" \
      -X POST "${N8N_API_URL}/api/v1/workflows/${existing_id}/${endpoint}" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}")
    http_code=$(echo "$response_body" | tail -1)

    # n8n may return non-200 even on success (e.g. webhook workflows).
    # Fallback: check response body for actual active state.
    if [ "$http_code" = "200" ]; then
      echo "${past} (id: $existing_id)"
      changed=$((changed + 1))
    elif [ "$COMMAND" = "publish" ] && python3 -c "
import sys, json
data = sys.stdin.read().rsplit('\n', 1)
d = json.loads(data[0])
sys.exit(0 if d.get('active') else 1)
" <<< "$response_body" 2>/dev/null; then
      echo "${past} (id: $existing_id)"
      changed=$((changed + 1))
    else
      echo "FAILED (HTTP $http_code)"
      failed=$((failed + 1))
    fi
  done

  echo ""
  echo "Done: $changed ${past}, $skipped skipped, $failed failed (${#files[@]} total)"

  if [ "$failed" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

# ── Deploy mode ──────────────────────────────────────────────────

# Fetch existing workflows to match by name
# Use python to extract name→id mapping because the n8n API response may
# contain unescaped control characters in jsCode that break jq
existing_map=$(fetch_name_id_map)

echo "Deploying ${#files[@]} workflow(s) from ${WORKFLOW_DIR} [${ENV}]..."
echo ""

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
import sys, json, re

server = json.load(sys.stdin)
with open(sys.argv[1]) as f:
    local = json.load(f)

namespace = sys.argv[2]
name_id_raw = sys.argv[3]

# Build name→id map from existing workflows
name_id_map = {}
for line in name_id_raw.strip().split('\n'):
    if '\t' in line:
        wid, wname = line.split('\t', 1)
        name_id_map[wname] = wid

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

# Remap sub-workflow IDs inline
for node in local.get('nodes', []):
    if node['type'] != 'n8n-nodes-base.executeWorkflow':
        continue
    match = re.match(r'(WF-\d+\w*)', node['name'])
    if not match:
        continue
    wf_prefix = match.group(1)
    for sname, sid in name_id_map.items():
        if '[' + namespace + ']' in sname and sname.split(']')[-1].strip().startswith(wf_prefix + ':'):
            params = node.get('parameters', {})
            wid = params.get('workflowId', {})
            if isinstance(wid, dict):
                wid['value'] = sid
            break

for key in ('active','id','versionId','tags','meta','updatedAt','createdAt'):
    local.pop(key, None)

json.dump(local, sys.stdout, ensure_ascii=False)
" "$file" "$NAMESPACE" "$existing_map" | apply_workflow_vars | \
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
      apply_workflow_vars | \
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

# ── Pass 2: Sub-workflow ID remapping (needed after POST/create) ───
if [ "$created" -gt 0 ] && [ ${#files[@]} -gt 1 ]; then
  remap_subworkflow_ids "$NAMESPACE" "${files[@]}"
fi

if [ "$failed" -gt 0 ]; then
  exit 1
fi
