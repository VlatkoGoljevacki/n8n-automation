#!/usr/bin/env bash
#
# Manage n8n workflows on the server.
#
# Usage:
#   ./helpers/workflows.sh list                  # list ALL workflows with status
#   ./helpers/workflows.sh list PROJECT           # list workflows matching project name
#   ./helpers/workflows.sh delete ID [ID...]      # delete specific workflow(s) by ID
#   ./helpers/workflows.sh delete-project NAME    # delete all workflows matching project name

set -euo pipefail

# Load .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    export "$line"
  done < "${ROOT_DIR}/.env"
fi

N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"

if [ -z "$N8N_API_KEY" ]; then
  echo "Error: N8N_API_KEY not set. Add it to .env"
  exit 1
fi

api() {
  local method="${2:-GET}"
  if [ "$method" = "DELETE" ]; then
    curl -s -o /dev/null -w "%{http_code}" -X DELETE \
      "${N8N_API_URL}/api/v1/$1" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}"
  else
    curl -s "${N8N_API_URL}/api/v1/$1" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}"
  fi
}

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
  list)
    FILTER="${1:-}"
    api "workflows?limit=100" | python3 -c "
import sys, json
filter_str = sys.argv[1].lower() if len(sys.argv) > 1 and sys.argv[1] else ''
data = json.load(sys.stdin)
workflows = sorted(data.get('data', []), key=lambda x: x['name'])
for w in workflows:
    if filter_str and filter_str not in w['name'].lower():
        continue
    active = '\033[32m● active\033[0m' if w.get('active') else '○ inactive'
    archived = ' [ARCHIVED]' if w.get('isArchived') else ''
    tags = ', '.join(t['name'] for t in w.get('tags', []))
    tags_str = f'  ({tags})' if tags else ''
    print(f'  {w[\"id\"]:>20}  {active:22}  {w[\"name\"]}{archived}{tags_str}')
" "$FILTER"
    ;;

  delete)
    if [ $# -eq 0 ]; then
      echo "Usage: workflows.sh delete ID [ID...]"
      exit 1
    fi

    deleted=0
    failed=0
    for wf_id in "$@"; do
      # Get workflow name first
      name=$(api "workflows/${wf_id}" | python3 -c "
import sys, json
try:
    w = json.load(sys.stdin)
    print(w.get('name', 'unknown'))
except:
    print('unknown')
" 2>/dev/null)

      echo -n "  Deleting ${wf_id} (${name}) ... "
      http_code=$(api "workflows/${wf_id}" DELETE)
      if [ "$http_code" = "200" ]; then
        echo "OK"
        deleted=$((deleted + 1))
      else
        echo "FAILED (HTTP $http_code)"
        failed=$((failed + 1))
      fi
    done
    echo ""
    echo "Done: $deleted deleted, $failed failed"
    ;;

  delete-project)
    PROJECT="${1:?Usage: workflows.sh delete-project PROJECT_NAME}"

    echo "Finding workflows matching '${PROJECT}'..."
    ids_and_names=$(api "workflows?limit=100" | python3 -c "
import sys, json
project = sys.argv[1].lower()
data = json.load(sys.stdin)
for w in sorted(data.get('data', []), key=lambda x: x['name']):
    if project in w['name'].lower():
        print(w['id'] + '\t' + w['name'])
" "$PROJECT")

    if [ -z "$ids_and_names" ]; then
      echo "  No workflows found matching '${PROJECT}'"
      exit 0
    fi

    count=$(echo "$ids_and_names" | wc -l)
    echo "Found $count workflow(s):"
    echo "$ids_and_names" | while IFS=$'\t' read -r id name; do
      echo "  $id  $name"
    done

    echo ""
    read -rp "Delete all $count workflow(s)? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
      echo "Aborted."
      exit 0
    fi

    deleted=0
    failed=0
    echo ""
    echo "$ids_and_names" | while IFS=$'\t' read -r id name; do
      echo -n "  Deleting $id ($name) ... "
      http_code=$(api "workflows/${id}" DELETE)
      if [ "$http_code" = "200" ]; then
        echo "OK"
      else
        echo "FAILED (HTTP $http_code)"
      fi
    done
    ;;

  *)
    echo "Usage: workflows.sh {list|delete|delete-project} [args...]"
    echo ""
    echo "Commands:"
    echo "  list [PROJECT]           List all workflows (optionally filter by project)"
    echo "  delete ID [ID...]        Delete specific workflow(s) by ID"
    echo "  delete-project NAME      Delete all workflows matching project name"
    exit 1
    ;;
esac
