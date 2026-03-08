#!/usr/bin/env bash
#
# List mail folders for a Graph API mailbox.
# Gets a fresh token via the n8n token workflow, then queries Graph API.
#
# Usage:
#   ./helpers/mailfolders.sh                    # list folders for test mailbox
#   ./helpers/mailfolders.sh user@domain.com    # list folders for specific mailbox
#
# Requires: SSH tunnel to n8n (localhost:5678) and N8N_API_KEY in .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env
if [ -f "$ROOT_DIR/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    export "$line"
  done < "$ROOT_DIR/.env"
fi

N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"
TOKEN_WF_ID="${TOKEN_WF_ID:-a3WFhbGvOKzV81xE}"

if [ -z "$N8N_API_KEY" ]; then
  echo "Error: N8N_API_KEY not set in .env" >&2
  exit 1
fi

# Step 1: Get a fresh Graph API token from a recent execution
echo "Fetching Graph API token from n8n..." >&2

EXEC_ID=$(curl -sf "$N8N_API_URL/api/v1/executions?workflowId=$TOKEN_WF_ID&limit=1&status=success" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" | node -e '
process.stdin.setEncoding("utf8");
let d = "";
process.stdin.on("data", c => d += c);
process.stdin.on("end", () => {
  const r = JSON.parse(d);
  console.log(r.data[0].id);
});
')

TOKEN=$(curl -sf "$N8N_API_URL/api/v1/executions/$EXEC_ID?includeData=true" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" | node -e '
process.stdin.setEncoding("utf8");
let d = "";
process.stdin.on("data", c => d += c);
process.stdin.on("end", () => {
  const r = JSON.parse(d);
  const runData = r.data.resultData.runData;
  for (const [name, runs] of Object.entries(runData)) {
    const output = runs[runs.length - 1]?.data?.main?.[0]?.[0]?.json;
    if (output?.accessToken) {
      console.log(output.accessToken);
      break;
    }
  }
});
')

if [ -z "$TOKEN" ]; then
  echo "Error: Could not extract Graph API token from execution $EXEC_ID" >&2
  exit 1
fi

# Step 2: Determine mailbox
if [ -n "${1:-}" ]; then
  MAILBOX="$1"
else
  # Auto-detect from a recent orchestrator execution
  MAILBOX=$(curl -sf "$N8N_API_URL/api/v1/executions?limit=10&status=success" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" | node -e '
process.stdin.setEncoding("utf8");
let d = "";
process.stdin.on("data", c => d += c);
process.stdin.on("end", () => {
  const r = JSON.parse(d);
  // Find an orchestrator execution to extract mailbox from odata context
  for (const exec of r.data) {
    process.stderr.write("Checking execution " + exec.id + "...\n");
  }
  // Just output the first execution ID for detailed lookup
  console.log(r.data.map(e => e.id).join(","));
});
' 2>/dev/null)

  # Search through recent executions for mailbox
  FOUND_MAILBOX=""
  IFS=',' read -ra EXEC_IDS <<< "$MAILBOX"
  for eid in "${EXEC_IDS[@]}"; do
    FOUND_MAILBOX=$(curl -sf "$N8N_API_URL/api/v1/executions/$eid?includeData=true" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" | node -e '
process.stdin.setEncoding("utf8");
let d = "";
process.stdin.on("data", c => d += c);
process.stdin.on("end", () => {
  const r = JSON.parse(d);
  const runData = r.data?.resultData?.runData || {};
  for (const [name, runs] of Object.entries(runData)) {
    for (const run of runs) {
      const items = run?.data?.main?.[0] || [];
      for (const item of items) {
        const j = JSON.stringify(item.json || {});
        const match = j.match(/@odata\.context.*?users\('"'"'([^'"'"']+)'"'"'\)/);
        if (match) { console.log(match[1]); process.exit(0); }
      }
    }
  }
});
' 2>/dev/null)
    if [ -n "$FOUND_MAILBOX" ]; then
      # URL-decode %40 → @
      MAILBOX=$(echo "$FOUND_MAILBOX" | sed 's/%40/@/g')
      break
    fi
  done

  if [ -z "$MAILBOX" ] || [[ "$MAILBOX" == *","* ]]; then
    echo "Error: Could not auto-detect mailbox. Pass it as an argument:" >&2
    echo "  $0 user@domain.com" >&2
    exit 1
  fi
fi

echo "Mailbox: $MAILBOX" >&2
echo ""

# Step 3: Fetch and display mail folders
curl -sf "https://graph.microsoft.com/v1.0/users/$MAILBOX/mailFolders?\$top=50" \
  -H "Authorization: Bearer $TOKEN" | node -e '
process.stdin.setEncoding("utf8");
let d = "";
process.stdin.on("data", c => d += c);
process.stdin.on("end", () => {
  const r = JSON.parse(d);
  if (r.error) {
    console.error("Graph API error:", r.error.message);
    process.exit(1);
  }
  const folders = r.value || [];
  // Header
  console.log("FOLDER".padEnd(30) + "  " + "ID");
  console.log("-".repeat(30) + "  " + "-".repeat(80));
  for (const f of folders) {
    console.log(f.displayName.padEnd(30) + "  " + f.id);
  }
  console.log("");
  console.log("# .env.workflow format:");
  const mapping = {
    "Processing": "MS_FOLDER_PROCESSING_ID",
    "Processed": "MS_FOLDER_PROCESSED_ID",
    "Error": "MS_FOLDER_ERROR_ID",
    "Partial": "MS_FOLDER_PARTIAL_ID"
  };
  for (const f of folders) {
    if (mapping[f.displayName]) {
      console.log(mapping[f.displayName] + "=" + f.id);
    }
  }
});
'
