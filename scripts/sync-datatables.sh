#!/usr/bin/env bash
#
# Sync DataTable schemas between local registry and n8n server.
#
# Usage:
#   ./scripts/sync-datatables.sh pull   # Fetch all DataTables from server → update local registry
#   ./scripts/sync-datatables.sh push   # Create new DataTables (id: null) on server → write back IDs
#   ./scripts/sync-datatables.sh diff   # Show differences between local registry and server
#
# Safeguards:
#   - push only creates new tables (where id is null). Never deletes or modifies existing.
#   - Deleting or renaming existing tables must be done manually in the n8n UI.
#   - pull is always safe — read-only from server, write to local file.

set -euo pipefail

REGISTRY="datatables/datatables.json"

# Load .env if present
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
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

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required."
  exit 1
fi

if [ -z "$N8N_API_KEY" ]; then
  echo "Error: N8N_API_KEY is not set."
  exit 1
fi

if [ ! -f "$REGISTRY" ]; then
  echo "Error: Registry file not found: $REGISTRY"
  exit 1
fi

COMMAND="${1:-}"
if [ -z "$COMMAND" ]; then
  echo "Usage: $0 <pull|push|diff>"
  exit 1
fi

# ── Helper: fetch all DataTables from server ───────────────────────
fetch_server_datatables() {
  curl -s "${N8N_API_URL}/api/v1/data-tables?limit=100" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}"
}

# ── Pull: fetch from server → update local registry ───────────────
if [ "$COMMAND" = "pull" ]; then
  echo "Pulling DataTable schemas from n8n..."

  server_response=$(fetch_server_datatables)

  python3 -c "
import json, sys

server = json.loads(sys.argv[1])
with open(sys.argv[2]) as f:
    local = json.load(f)

server_tables = server.get('data', [])
local_tables = local.get('datatables', [])

# Build server lookup by name
server_by_name = {}
for t in server_tables:
    server_by_name[t['name']] = t

# Build local lookup by name
local_by_name = {t['name']: t for t in local_tables}

updated = 0
added = 0

# Update existing local entries with server IDs and columns
for lt in local_tables:
    st = server_by_name.get(lt['name'])
    if st:
        old_id = lt.get('id')
        lt['id'] = st['id']
        # Update columns from server
        if 'columns' in st:
            lt['columns'] = [
                {'name': c['name'], 'type': c.get('type', 'string')}
                for c in st['columns']
                if c['name'] != 'id'  # skip auto-generated id column
            ]
        if old_id != st['id']:
            updated += 1

# Add server tables not in local registry
for name, st in server_by_name.items():
    if name not in local_by_name:
        cols = []
        if 'columns' in st:
            cols = [
                {'name': c['name'], 'type': c.get('type', 'string')}
                for c in st['columns']
                if c['name'] != 'id'
            ]
        local_tables.append({
            'id': st['id'],
            'name': name,
            'columns': cols
        })
        added += 1

local['datatables'] = local_tables

with open(sys.argv[2], 'w') as f:
    json.dump(local, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f'  {updated} updated, {added} added, {len(local_tables)} total.')
" "$server_response" "$REGISTRY"

  echo "Done."
  exit 0
fi

# ── Push: create new DataTables (id: null) on server ───────────────
if [ "$COMMAND" = "push" ]; then
  echo "Pushing new DataTables to n8n..."

  # Find entries with null id
  null_entries=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    local = json.load(f)
for i, t in enumerate(local.get('datatables', [])):
    if t.get('id') is None:
        print(f\"{i}\t{t['name']}\")
" "$REGISTRY")

  if [ -z "$null_entries" ]; then
    echo "  No new DataTables to create (all have IDs)."
    exit 0
  fi

  created=0
  failed=0

  while IFS=$'\t' read -r idx name; do
    echo -n "  Creating '$name' ... "

    # Build column definitions
    columns_json=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    local = json.load(f)
t = local['datatables'][int(sys.argv[2])]
cols = [{'name': c['name'], 'type': c.get('type', 'string')} for c in t.get('columns', [])]
print(json.dumps(cols))
" "$REGISTRY" "$idx")

    # Create DataTable via API
    response=$(curl -s -w "\n%{http_code}" \
      -X POST "${N8N_API_URL}/api/v1/data-tables" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"$name\", \"columns\": $columns_json}")

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
      new_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
      echo "CREATED (id: $new_id)"

      # Write back the ID to the registry
      python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    local = json.load(f)
local['datatables'][int(sys.argv[2])]['id'] = sys.argv[3]
with open(sys.argv[1], 'w') as f:
    json.dump(local, f, indent=2, ensure_ascii=False)
    f.write('\n')
" "$REGISTRY" "$idx" "$new_id"

      created=$((created + 1))
    else
      echo "FAILED (HTTP $http_code)"
      echo "    $body"
      failed=$((failed + 1))
    fi
  done <<< "$null_entries"

  echo ""
  echo "Done: $created created, $failed failed."

  if [ "$failed" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

# ── Diff: compare local registry vs server ─────────────────────────
if [ "$COMMAND" = "diff" ]; then
  echo "Comparing local registry with n8n server..."
  echo ""

  server_response=$(fetch_server_datatables)

  python3 -c "
import json, sys

server = json.loads(sys.argv[1])
with open(sys.argv[2]) as f:
    local = json.load(f)

server_tables = {t['name']: t for t in server.get('data', [])}
local_tables = {t['name']: t for t in local.get('datatables', [])}

all_names = sorted(set(list(server_tables.keys()) + list(local_tables.keys())))

for name in all_names:
    in_local = name in local_tables
    in_server = name in server_tables

    if in_local and not in_server:
        lt = local_tables[name]
        if lt.get('id') is None:
            print(f'  + {name} (local only, pending create)')
        else:
            print(f'  ! {name} (local has id={lt[\"id\"]}, but NOT on server)')
    elif in_server and not in_local:
        st = server_tables[name]
        print(f'  - {name} (server only, id={st[\"id\"]})')
    else:
        lt = local_tables[name]
        st = server_tables[name]

        issues = []

        # Check ID match
        if lt.get('id') is None:
            issues.append(f'local id=null, server id={st[\"id\"]}')
        elif lt['id'] != st['id']:
            issues.append(f'id mismatch: local={lt[\"id\"]}, server={st[\"id\"]}')

        # Check columns
        local_cols = set(c['name'] for c in lt.get('columns', []))
        server_cols = set(
            c['name'] for c in st.get('columns', [])
            if c['name'] != 'id'
        )
        missing_on_server = local_cols - server_cols
        missing_in_local = server_cols - local_cols

        if missing_on_server:
            issues.append(f'columns missing on server: {sorted(missing_on_server)}')
        if missing_in_local:
            issues.append(f'columns missing in local: {sorted(missing_in_local)}')

        if issues:
            print(f'  ~ {name}')
            for issue in issues:
                print(f'      {issue}')
        else:
            print(f'  = {name} (in sync)')

print()
" "$server_response" "$REGISTRY"

  echo "Done."
  exit 0
fi

echo "Error: Unknown command: $COMMAND"
echo "Usage: $0 <pull|push|diff>"
exit 1
