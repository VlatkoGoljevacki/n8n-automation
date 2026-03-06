#!/usr/bin/env bash
#
# Manage n8n DataTables: list, inspect, drop, recreate.
#
# Usage:
#   ./helpers/datatables.sh list                  # list all DataTables on server
#   ./helpers/datatables.sh rows TABLE_ID [N]     # show first N rows (default 20)
#   ./helpers/datatables.sh count TABLE_ID        # count rows in a table
#   ./helpers/datatables.sh drop TABLE_ID         # delete a table
#   ./helpers/datatables.sh recreate TABLE_NAME   # drop + recreate empty from registry
#   ./helpers/datatables.sh truncate TABLE_NAME   # drop + recreate, then update workflow refs

set -euo pipefail

REGISTRY="datatables/datatables.json"

# Load .env
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    export "$line"
  done < .env
elif [ -f "$(dirname "$0")/../.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    export "$line"
  done < "$(dirname "$0")/../.env"
fi

N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"

if [ -z "$N8N_API_KEY" ]; then
  echo "Error: N8N_API_KEY not set. Add it to .env"
  exit 1
fi

api() {
  local method="${1}"
  local path="${2}"
  shift 2
  curl -s -X "$method" "${N8N_API_URL}/api/v1/${path}" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    -H "Content-Type: application/json" \
    "$@"
}

CMD="${1:-list}"
shift 2>/dev/null || true

case "$CMD" in
  list)
    api GET "data-tables?limit=100" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tables = data.get('data', [])
if not tables:
    print('No DataTables found.')
    sys.exit(0)
print(f'{'ID':<20} {'Name':<25} {'Columns':<8} {'Created'}')
print('-' * 80)
for t in tables:
    cols = len([c for c in t.get('columns', []) if c['name'] != 'id'])
    created = t.get('createdAt', '')[:10]
    print(f'{t[\"id\"]:<20} {t[\"name\"]:<25} {cols:<8} {created}')
print(f'\n{len(tables)} table(s)')
"
    ;;

  rows)
    TABLE_ID="${1:-}"
    LIMIT="${2:-20}"
    if [ -z "$TABLE_ID" ]; then
      echo "Usage: $0 rows TABLE_ID [N]"
      exit 1
    fi
    api GET "data-tables/${TABLE_ID}/rows?limit=${LIMIT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
rows = data.get('data', [])
if not rows:
    print('No rows found.')
    sys.exit(0)
# Get column names from first row, skip 'id'
cols = [k for k in rows[0].keys() if k != 'id']
# Print header
header = '  '.join(f'{c:<20}' for c in cols[:6])
print(header)
print('-' * len(header))
for row in rows:
    vals = '  '.join(f'{str(row.get(c, \"\"))[:20]:<20}' for c in cols[:6])
    print(vals)
print(f'\n{len(rows)} row(s) shown')
"
    ;;

  count)
    TABLE_ID="${1:-}"
    if [ -z "$TABLE_ID" ]; then
      echo "Usage: $0 count TABLE_ID"
      exit 1
    fi
    # Fetch with limit=1 to get total count from response
    api GET "data-tables/${TABLE_ID}/rows?limit=1" | python3 -c "
import sys, json
data = json.load(sys.stdin)
rows = data.get('data', [])
# n8n may not return a total count, so we fetch all with high limit
" 2>/dev/null
    # Fallback: fetch all rows and count
    api GET "data-tables/${TABLE_ID}/rows?limit=10000" | python3 -c "
import sys, json
data = json.load(sys.stdin)
rows = data.get('data', [])
print(f'{len(rows)} row(s)')
"
    ;;

  drop)
    TABLE_ID="${1:-}"
    if [ -z "$TABLE_ID" ]; then
      echo "Usage: $0 drop TABLE_ID"
      exit 1
    fi
    echo -n "Deleting table ${TABLE_ID} ... "
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X DELETE "${N8N_API_URL}/api/v1/data-tables/${TABLE_ID}" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}")
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
      echo "DELETED"
    else
      echo "FAILED (HTTP ${http_code})"
      exit 1
    fi
    ;;

  recreate|truncate)
    TABLE_NAME="${1:-}"
    if [ -z "$TABLE_NAME" ]; then
      echo "Usage: $0 $CMD TABLE_NAME"
      echo "  TABLE_NAME must match an entry in ${REGISTRY}"
      exit 1
    fi

    if [ ! -f "$REGISTRY" ]; then
      echo "Error: Registry not found: ${REGISTRY}"
      exit 1
    fi

    # Look up table in registry
    table_info=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    reg = json.load(f)
for i, t in enumerate(reg.get('datatables', [])):
    if t['name'] == sys.argv[2]:
        print(json.dumps({'index': i, 'id': t.get('id'), 'name': t['name'], 'columns': t.get('columns', [])}))
        sys.exit(0)
print('NOT_FOUND')
" "$REGISTRY" "$TABLE_NAME")

    if [ "$table_info" = "NOT_FOUND" ]; then
      echo "Error: '${TABLE_NAME}' not found in registry."
      echo "Available tables:"
      python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    reg = json.load(f)
for t in reg.get('datatables', []):
    print(f'  - {t[\"name\"]} (id: {t.get(\"id\", \"null\")})')
" "$REGISTRY"
      exit 1
    fi

    old_id=$(echo "$table_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'] or '')")
    columns_json=$(echo "$table_info" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['columns']))")
    reg_index=$(echo "$table_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['index'])")

    # Step 1: Drop existing table
    if [ -n "$old_id" ]; then
      echo -n "Dropping '${TABLE_NAME}' (${old_id}) ... "
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE "${N8N_API_URL}/api/v1/data-tables/${old_id}" \
        -H "X-N8N-API-KEY: ${N8N_API_KEY}")
      if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "DELETED"
      else
        echo "FAILED (HTTP ${http_code})"
        exit 1
      fi
    else
      echo "No existing table to drop (id is null)."
    fi

    # Step 2: Create new table
    echo -n "Creating '${TABLE_NAME}' ... "
    response=$(curl -s -w "\n%{http_code}" \
      -X POST "${N8N_API_URL}/api/v1/data-tables" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${TABLE_NAME}\", \"columns\": ${columns_json}}")

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
      new_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
      echo "CREATED (id: ${new_id})"

      # Step 3: Update registry
      python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    reg = json.load(f)
reg['datatables'][int(sys.argv[2])]['id'] = sys.argv[3]
with open(sys.argv[1], 'w') as f:
    json.dump(reg, f, indent=2, ensure_ascii=False)
    f.write('\n')
" "$REGISTRY" "$reg_index" "$new_id"
      echo "Registry updated."

      # Step 4: Update workflow references
      if [ -n "$old_id" ] && [ "$old_id" != "$new_id" ]; then
        echo -n "Updating workflow references (${old_id} → ${new_id}) ... "
        count=$(grep -rl "$old_id" workflows/ 2>/dev/null | wc -l)
        if [ "$count" -gt 0 ]; then
          grep -rl "$old_id" workflows/ | xargs sed -i "s/${old_id}/${new_id}/g"
          echo "${count} file(s) updated"
        else
          echo "no references found"
        fi
      fi
    else
      echo "FAILED (HTTP ${http_code})"
      echo "  ${body}"
      exit 1
    fi

    echo "Done."
    ;;

  *)
    echo "Unknown command: $CMD"
    echo ""
    echo "Usage:"
    echo "  $0 list                  # list all DataTables"
    echo "  $0 rows TABLE_ID [N]     # show first N rows (default 20)"
    echo "  $0 count TABLE_ID        # count rows"
    echo "  $0 drop TABLE_ID         # delete a table"
    echo "  $0 recreate TABLE_NAME   # drop + recreate empty from registry"
    exit 1
    ;;
esac
