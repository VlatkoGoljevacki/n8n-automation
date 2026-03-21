#!/usr/bin/env bash
#
# Inspect n8n workflows and nodes on the server.
#
# Usage:
#   ./helpers/inspect.sh list [FILTER]          # list all workflows (optionally filter by name)
#   ./helpers/inspect.sh nodes WORKFLOW_ID     # list all nodes in a workflow
#   ./helpers/inspect.sh node WORKFLOW_ID NODE # show node parameters
#   ./helpers/inspect.sh connections WF_ID     # show workflow connection graph
#   ./helpers/inspect.sh diff WF_ID FILE      # diff server vs local file

set -euo pipefail

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
  curl -s "${N8N_API_URL}/api/v1/$1" -H "X-N8N-API-KEY: ${N8N_API_KEY}"
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
    print(f'{w[\"id\"]:>20}  {active:12}  {w[\"name\"]}{archived}')
" "$FILTER"
    ;;

  nodes)
    WF_ID="${1:?Usage: inspect.sh nodes WORKFLOW_ID}"
    api "workflows/${WF_ID}" | python3 -c "
import sys, json
w = json.load(sys.stdin)
print(f'Workflow: {w[\"name\"]}')
print(f'Nodes: {len(w[\"nodes\"])}')
print()
for n in w['nodes']:
    t = n['type'].split('.')[-1]
    pos = n.get('position', [0,0])
    cred = list(n.get('credentials', {}).keys())
    cred_str = f'  [{cred[0]}]' if cred else ''
    print(f'  {n[\"name\"]:40}  {t:30}  ({pos[0]},{pos[1]}){cred_str}')
"
    ;;

  node)
    WF_ID="${1:?Usage: inspect.sh node WORKFLOW_ID NODE_NAME}"
    NODE="${2:?Usage: inspect.sh node WORKFLOW_ID NODE_NAME}"
    api "workflows/${WF_ID}" | python3 -c "
import sys, json
NODE = sys.argv[1]
w = json.load(sys.stdin)
found = False
for n in w['nodes']:
    if n['name'] == NODE:
        found = True
        print(f'Name: {n[\"name\"]}')
        print(f'Type: {n[\"type\"]} v{n.get(\"typeVersion\", \"?\")}')
        print(f'ID: {n[\"id\"]}')
        print(f'Position: {n.get(\"position\", [])}')
        if n.get('credentials'):
            print(f'Credentials: {json.dumps(n[\"credentials\"], indent=2)}')
        print(f'Parameters:')
        print(json.dumps(n['parameters'], indent=2, ensure_ascii=False))
        break
if not found:
    print(f'Node \"{NODE}\" not found. Available nodes:')
    for n in w['nodes']:
        print(f'  - {n[\"name\"]}')
" "$NODE"
    ;;

  connections)
    WF_ID="${1:?Usage: inspect.sh connections WORKFLOW_ID}"
    api "workflows/${WF_ID}" | python3 -c "
import sys, json
w = json.load(sys.stdin)
print(f'Workflow: {w[\"name\"]}')
print()
conns = w.get('connections', {})
for src, data in conns.items():
    for output_idx, targets in enumerate(data.get('main', [])):
        label = ''
        if len(data.get('main', [])) > 1:
            label = ' (TRUE)' if output_idx == 0 else ' (FALSE)'
        for t in targets:
            print(f'  {src}{label}  →  {t[\"node\"]}')
"
    ;;

  diff)
    WF_ID="${1:?Usage: inspect.sh diff WORKFLOW_ID LOCAL_FILE}"
    LOCAL="${2:?Usage: inspect.sh diff WORKFLOW_ID LOCAL_FILE}"
    TMPFILE=$(mktemp /tmp/n8n-server-XXXX.json)
    api "workflows/${WF_ID}" | python3 -c "
import sys, json
w = json.load(sys.stdin)
keep = {'name','nodes','connections','settings','tags','active'}
out = {k: v for k, v in w.items() if k in keep}
out['active'] = False
print(json.dumps(out, indent=2, ensure_ascii=False))
" > "$TMPFILE"
    echo "Diff: server (left) vs local (right)"
    echo "---"
    diff --color=auto -u "$TMPFILE" "$LOCAL" || true
    rm -f "$TMPFILE"
    ;;

  *)
    echo "Usage: inspect.sh {list|nodes|node|connections|diff} [args...]"
    echo ""
    echo "Commands:"
    echo "  list [FILTER]            List all workflows (optionally filter by name)"
    echo "  nodes WORKFLOW_ID        List all nodes in a workflow"
    echo "  node WORKFLOW_ID NODE    Show node parameters"
    echo "  connections WORKFLOW_ID  Show workflow connection graph"
    echo "  diff WORKFLOW_ID FILE    Diff server vs local file"
    exit 1
    ;;
esac
