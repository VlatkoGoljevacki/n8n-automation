#!/usr/bin/env bash
#
# Fetch and inspect n8n workflow executions.
#
# Usage:
#   ./helpers/executions.sh                    # list last 10 executions
#   ./helpers/executions.sh list [N]           # list last N executions (default 10)
#   ./helpers/executions.sh errors [N]         # list last N failed executions
#   ./helpers/executions.sh detail EXEC_ID     # per-node status for an execution
#   ./helpers/executions.sh node EXEC_ID NODE  # output data from a specific node
#   ./helpers/executions.sh debug              # auto-debug last failed execution
#   ./helpers/executions.sh wf WORKFLOW_ID [N] # last N executions for a workflow

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

CMD="${1:-list}"
shift 2>/dev/null || true

case "$CMD" in
  list)
    LIMIT="${1:-10}"
    api "executions?limit=${LIMIT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for e in data.get('data', []):
    status = e['status']
    icon = '✓' if status == 'success' else '✗' if status == 'error' else '⏳'
    wf = e.get('workflowId', '')
    name = e.get('workflowData', {}).get('name', wf)
    time = e.get('stoppedAt', '')[:19].replace('T', ' ')
    mode = e.get('mode', '')
    print(f'{icon} #{e[\"id\"]:>5}  {status:<8}  {time}  {mode:<10}  {name}')
"
    ;;

  errors)
    LIMIT="${1:-5}"
    api "executions?limit=${LIMIT}&status=error" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data.get('data'):
    print('No failed executions found'); sys.exit()
for e in data['data']:
    wf = e.get('workflowId', '')
    name = e.get('workflowData', {}).get('name', wf)
    time = e.get('stoppedAt', '')[:19].replace('T', ' ')
    print(f'✗ #{e[\"id\"]:>5}  {time}  {name}')
"
    ;;

  detail)
    EXEC_ID="${1:?Usage: executions.sh detail EXEC_ID}"
    api "executions/${EXEC_ID}?includeData=true" | python3 -c "
import sys, json
e = json.load(sys.stdin)
rd = e.get('data', {}).get('resultData', {}).get('runData', {})
name = e.get('workflowData', {}).get('name', e.get('workflowId', ''))
print(f'Execution #{e[\"id\"]} — {name} — {e[\"status\"]}')
print(f'Started: {e.get(\"startedAt\", \"\")[:19]}  Finished: {e.get(\"stoppedAt\", \"\")[:19]}')
print()
for node_name, runs in rd.items():
    for run in runs:
        status = run.get('executionStatus', 'unknown')
        icon = '✓' if status == 'success' else '✗'
        main = run.get('data', {}).get('main', [[]])
        out_items = len(main[0]) if main and main[0] else 0
        error = run.get('error', {}).get('message', '') if run.get('error') else ''
        line = f'  {icon} {node_name}: {out_items} item(s)'
        if error:
            line += f'  ← ERROR: {error}'
        print(line)
"
    ;;

  node)
    EXEC_ID="${1:?Usage: executions.sh node EXEC_ID NODE_NAME}"
    NODE="${2:?Usage: executions.sh node EXEC_ID NODE_NAME}"
    api "executions/${EXEC_ID}?includeData=true" | python3 -c "
import sys, json
NODE = sys.argv[1]
e = json.load(sys.stdin)
rd = e.get('data', {}).get('resultData', {}).get('runData', {})
runs = rd.get(NODE, [])
if not runs:
    print(f'Node \"{NODE}\" not found in execution. Available nodes:')
    for n in rd.keys():
        print(f'  - {n}')
    sys.exit(1)
for run in runs:
    main = run.get('data', {}).get('main', [[]])
    for branch_idx, branch in enumerate(main):
        if not branch:
            print(f'Branch {branch_idx}: (empty)')
            continue
        for i, item in enumerate(branch):
            j = item.get('json', {})
            has_binary = bool(item.get('binary'))
            print(f'--- Branch {branch_idx}, Item {i} {\"[+binary]\" if has_binary else \"\"} ---')
            print(json.dumps(j, indent=2, ensure_ascii=False)[:3000])
    error = run.get('error')
    if error:
        print(f'ERROR: {error.get(\"message\", \"\")}')
" "$NODE"
    ;;

  debug)
    api "executions?limit=1&status=error&includeData=true" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data.get('data'):
    print('No failed executions found'); sys.exit()
e = data['data'][0]
name = e.get('workflowData', {}).get('name', e.get('workflowId', ''))
rd = e.get('data', {}).get('resultData', {}).get('runData', {})
print(f'Last failure: #{e[\"id\"]} — {name}')
print(f'Time: {e.get(\"stoppedAt\", \"\")[:19]}')
print()

failed_node = None
for node_name, runs in rd.items():
    for run in runs:
        error = run.get('error')
        if error:
            failed_node = node_name
            print(f'FAILED NODE: {node_name}')
            print(f'  Error: {error.get(\"message\", \"\")}')
            desc = error.get('description', '')
            if desc:
                print(f'  Description: {desc[:500]}')
            # Show input data
            main = run.get('data', {}).get('main', [[]])
            if main and main[0]:
                j = main[0][0].get('json', {})
                print(f'  Input data: {json.dumps(j, ensure_ascii=False)[:1500]}')
            print()

if not failed_node:
    print('No node-level errors found. Execution may have timed out or been cancelled.')
    # Show last node that ran
    nodes = list(rd.keys())
    if nodes:
        last = nodes[-1]
        runs = rd[last]
        for run in runs:
            main = run.get('data', {}).get('main', [[]])
            out = len(main[0]) if main and main[0] else 0
            print(f'Last node: {last} ({out} items)')
"
    ;;

  wf)
    WF_ID="${1:?Usage: executions.sh wf WORKFLOW_ID [N]}"
    LIMIT="${2:-5}"
    api "executions?limit=${LIMIT}&workflowId=${WF_ID}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data.get('data'):
    print('No executions found for this workflow'); sys.exit()
for e in data['data']:
    status = e['status']
    icon = '✓' if status == 'success' else '✗' if status == 'error' else '⏳'
    time = e.get('stoppedAt', '')[:19].replace('T', ' ')
    mode = e.get('mode', '')
    print(f'{icon} #{e[\"id\"]:>5}  {status:<8}  {time}  {mode}')
"
    ;;

  *)
    echo "Usage: executions.sh {list|errors|detail|node|debug|wf} [args...]"
    echo ""
    echo "Commands:"
    echo "  list [N]              List last N executions (default 10)"
    echo "  errors [N]            List last N failed executions"
    echo "  detail EXEC_ID        Per-node status for an execution"
    echo "  node EXEC_ID NODE     Output data from a specific node"
    echo "  debug                 Auto-debug last failed execution"
    echo "  wf WORKFLOW_ID [N]    Last N executions for a workflow"
    exit 1
    ;;
esac
