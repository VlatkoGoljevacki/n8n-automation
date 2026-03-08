# Workflow Deployment Order

Reference for deploying to a fresh n8n server or redeploying from scratch.

Principle: **everything we can automate, we automate.** Create resources via
script/API, pull IDs from server, populate config files from pulled IDs.
Only manual step: entering secret values (API keys, passwords) in the n8n UI.

## Fresh Server Setup

Run these steps in order. Each step depends on the previous one.

### Step 1. n8n running and accessible

```bash
ssh -L 5678:localhost:5678 deploy@SERVER
# Verify:
curl -s http://localhost:5678/healthz
```

### Step 2. `.env` configured

Local `.env` must have:
- `N8N_API_KEY` — matching the server's API key (generate in n8n UI: Settings > API)
- All runtime secrets (ERP, Graph, OpenAI)

### Step 3. Create DataTables

Create on server, pull IDs back, populate `.env.workflow.test`.

```bash
# Null out IDs (fresh server has no tables)
python3 -c "
import json
with open('datatables/datatables.json') as f:
    data = json.load(f)
for dt in data['datatables']:
    dt['id'] = None
with open('datatables/datatables.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"

# Create on server
./scripts/sync-datatables.sh push

# Pull back to get server-assigned IDs
./scripts/sync-datatables.sh pull
```

Required tables:

| Table | Used by |
|-------|---------|
| Tokens | WF-00b (Token Manager) |
| Customers | WF-07 (Refresh Customers), WF-09 (Process Order) |

### Step 4. Create credentials

Create via API, then fill in secret values manually in n8n UI.

```bash
source .env

# OpenAI credential (used by WF-01b, WF-03, WF-08)
curl -s -X POST "http://localhost:5678/api/v1/credentials" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "OpenAi account",
    "type": "openAiApi",
    "data": {
      "apiKey": "sk-placeholder",
      "organizationId": "",
      "headerName": "",
      "headerValue": ""
    }
  }'
```

Then in the n8n UI: **Credentials > OpenAi account > replace placeholder API key**.

### Step 5. Configure `.env.workflow.test`

```bash
cp .env.workflow.test.example .env.workflow.test
```

Fill in from pulled IDs:

| Variable | Source |
|----------|--------|
| `DT_CUSTOMERS_ID` | `datatables/datatables.json` → Customers → id |
| `DT_TOKENS_ID` | `datatables/datatables.json` → Tokens → id |
| `MS_FOLDER_PROCESSING_ID` | Graph Explorer: `GET /users/{mailbox}/mailFolders` |
| `MS_FOLDER_PROCESSED_ID` | Same |
| `MS_FOLDER_ERROR_ID` | Same |

Or automate the DataTable IDs:

```bash
python3 -c "
import json
with open('datatables/datatables.json') as f:
    dts = {t['name']: t['id'] for t in json.load(f)['datatables']}
with open('.env.workflow.test') as f:
    content = f.read()
content = content.replace('DT_CUSTOMERS_ID=', f'DT_CUSTOMERS_ID={dts[\"Customers\"]}')
content = content.replace('DT_TOKENS_ID=', f'DT_TOKENS_ID={dts[\"Tokens\"]}')
with open('.env.workflow.test', 'w') as f:
    f.write(content)
print('Updated DT IDs in .env.workflow.test')
"
```

### Step 6. Deploy workflows

```bash
./scripts/deploy-workflows.sh medika-preorders
```

This runs:
1. **Lint check** — aborts if any errors
2. **Pass 1** — creates/updates all workflows (alphabetical by filename)
3. **Pass 2** — remaps `executeWorkflow` node IDs to match server-assigned IDs

### Step 7. Activate workflows

Activation order matters — sub-workflows must be active before the workflows
that call them.

**IMPORTANT: NEVER auto-activate WF-01 (Orchestrator) or WF-01b (Process Email).**
These are the entry points that trigger real processing (polling the mailbox,
handling emails). Always activate them manually after verifying everything
else works.

```bash
# Activate sub-workflows only (safe — they don't trigger on their own)
./scripts/deploy-workflows.sh medika-preorders publish

# WF-01 and WF-01b are SKIPPED by default (webhook/scheduleTrigger).
# After verifying the deployment, activate them explicitly:
./scripts/deploy-workflows.sh medika-preorders publish --force-activate
```

The publish command sorts workflows by trigger type: sub-workflows first,
then webhook, then scheduleTrigger last — ensuring dependencies are active
before the workflows that call them.

Activation order (bottom-up by dependency):

| Order | Workflow | Trigger type | Auto-activate? |
|-------|----------|-------------|----------------|
| 1 | WF-00b: Token Manager | executeWorkflowTrigger | Yes |
| 2 | WF-03: XLSX Parser | executeWorkflowTrigger | Yes |
| 3 | WF-04: Data Validator | executeWorkflowTrigger | Yes |
| 4 | WF-05: Send Order Notification | executeWorkflowTrigger | Yes |
| 5 | WF-06: Order Submitter | executeWorkflowTrigger | Yes |
| 6 | WF-07: Refresh Customers | executeWorkflowTrigger | Yes |
| 7 | WF-08: Email Body Parser | executeWorkflowTrigger | Yes |
| 8 | WF-09: Process Order | executeWorkflowTrigger | Yes |
| 9 | WF-01b: Process Email | webhook | **MANUAL** |
| 10 | WF-01: Orchestrator | scheduleTrigger | **MANUAL — activate last** |

Note: n8n requires sub-workflows to be active when called with
`callerPolicy: workflowsFromSameOwner`. If a sub-workflow is inactive,
the calling workflow will fail at the `executeWorkflow` node.

## Dependency Map

```
WF-01: Orchestrator (scheduleTrigger)
 └─ WF-00b: Token Manager
 └─ WF-01b: Process Email (webhook, called via HTTP)
      ├─ WF-00b: Token Manager
      ├─ WF-03: XLSX Parser
      ├─ WF-08: Email Body Parser
      └─ WF-09: Process Order
           ├─ WF-00b: Token Manager
           ├─ WF-04: Data Validator
           ├─ WF-05: Send Order Notification
           │    └─ WF-00b: Token Manager
           ├─ WF-06: Order Submitter
           │    └─ WF-00b: Token Manager
           └─ WF-07: Refresh Customer Registry
```

### What the remapping fixes

`executeWorkflow` nodes store a server-specific workflow ID. When deploying
to a new server, these IDs are wrong. Pass 2 fetches the name-to-ID map from
the server and patches each `executeWorkflow` node to point to the correct
workflow by matching the `WF-XX:` prefix in the node name against the
`[namespace] WF-XX:` pattern in workflow names.

### Credentials

| Credential | Type | Used by | Created via |
|------------|------|---------|-------------|
| OpenAi account | openAiApi | WF-01b, WF-03, WF-08 | API (step 4) |

After creating via API, fill in actual secret values in n8n UI.

## Post-Deployment Verification

```bash
# Verify all workflows exist
./helpers/inspect.sh list

# Trigger a manual test (if WF-01b is active)
# Send a test email to the monitored mailbox, then check:
./helpers/executions.sh list 5
```

## Redeployment (existing server)

When redeploying to a server that already has workflows:

```bash
# Pull latest from server first (preserves credentials, positions)
./scripts/deploy-workflows.sh medika-preorders pull

# Make changes locally, then deploy
./scripts/deploy-workflows.sh medika-preorders

# Or deploy a single file
./scripts/deploy-workflows.sh workflows/test/medika-preorders/03_xlsx_parser.json
```

No need to recreate DataTables or credentials — they persist in n8n's database.

## Production Deployment

```bash
# Promote test -> prod (transforms namespace, webhook paths, env vars)
./scripts/deploy-workflows.sh medika-preorders promote --deploy

# Or promote files only, then deploy separately
./scripts/deploy-workflows.sh medika-preorders promote
./scripts/deploy-workflows.sh medika-preorders --env prod deploy
./scripts/deploy-workflows.sh medika-preorders --env prod publish
```
