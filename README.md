# Medika Automation

Self-hosted [n8n](https://n8n.io/) automation server for Medika pre-order processing. Runs in Docker, accessed via SSH tunnel (not publicly exposed).

## Prerequisites

- Docker and Docker Compose
- SSH access to the server (see [Hetzner deployment guide](docs/HETZNER-DEPLOYMENT.md))

## Quick Start

```bash
cp .env.example .env
# Fill in secrets (ERP credentials, MS Graph, API keys)
# Test vars use _TEST suffix, prod vars use bare names

docker compose up -d
```

Access via SSH tunnel:

```bash
ssh -L 5678:localhost:5678 deploy@YOUR_SERVER_IP
# Then open http://localhost:5678
```

## Environment Variables

Two kinds of variables, managed in different places:

| Type | Where | Purpose | Example |
|------|-------|---------|---------|
| **Runtime** (`$env.X`) | `.env` → docker-compose → n8n container | Accessed by workflows at runtime | `MEDIKA_ERP_URL_TEST`, `MEDIKA_ERP_URL` |
| **Deploy-time** (`%%X%%`) | `.env.workflow.test` / `.env.workflow.prod` (local only) | Substituted into workflow JSON before deploy | `DT_CUSTOMERS_ID`, `MS_FOLDER_PROCESSING_ID` |

**Runtime vars** — test workflows reference `$env.X_TEST` (e.g. `$env.MEDIKA_ERP_URL_TEST`),
prod workflows reference `$env.X` (e.g. `$env.MEDIKA_ERP_URL`). Both sets are defined in the
server's `.env` and loaded into the n8n container. This allows test and prod workflows to
coexist on the same server with separate credentials and endpoints.

**Deploy-time vars** — `.env.workflow.{test,prod}` files are local only (gitignored).
The deploy script substitutes `%%VAR%%` placeholders before sending JSON to the n8n API.
Set up from the example templates:

```bash
cp .env.workflow.test.example .env.workflow.test
cp .env.workflow.prod.example .env.workflow.prod
# Fill in server-specific IDs (DataTable IDs, MS Graph folder IDs)
```

## Project Structure

```
medika-automation/
├── docker-compose.yml          # local development
├── docker-compose.server.yml   # server (no volume mounts)
├── .env.example                # runtime env var template
├── .env.workflow.test.example  # deploy-time var template (test)
├── .env.workflow.prod.example  # deploy-time var template (prod)
├── workflows/
│   ├── test/
│   │   ├── medika-preorders/   # test workflows
│   │   └── shared/             # cross-project workflows (disk alerts, etc.)
│   └── prod/
│       └── medika-preorders/   # production (populated via promote)
├── scripts/
│   ├── deploy-workflows.sh     # deploy/pull/promote workflows via n8n API
│   ├── lint-workflows.py       # structural checks (runs as pre-deploy gate)
│   └── sync-datatables.sh      # sync DataTable schemas with server
├── helpers/
│   ├── executions.sh           # inspect workflow executions
│   ├── inspect.sh              # inspect workflows and nodes
│   └── datatables.sh           # manage DataTables (list, rows, drop)
├── datatables/
│   └── datatables.json         # DataTable schema registry with server IDs
├── credentials/
│   └── credentials.json        # n8n credential exports (encrypted)
└── docs/                       # detailed guides
```

## Workflow Management

All commands require an active SSH tunnel and `N8N_API_KEY` set in `.env`.

### Deploy workflows to server

```bash
# Deploy all test workflows
./scripts/deploy-workflows.sh medika-preorders

# Deploy a single file
./scripts/deploy-workflows.sh workflows/test/medika-preorders/01_orchestrator.json

# Activate sub-workflows (skips WF-01/01b entry points)
./scripts/deploy-workflows.sh medika-preorders publish

# Activate ALL including entry points (WF-01/01b)
./scripts/deploy-workflows.sh medika-preorders publish --force-activate

# Deactivate all
./scripts/deploy-workflows.sh medika-preorders unpublish
```

### Pull workflows from server

```bash
# Pull test workflows (server -> local files)
./scripts/deploy-workflows.sh medika-preorders pull

# Pull prod
./scripts/deploy-workflows.sh medika-preorders --env prod pull
```

### Promote test to production

```bash
# Copy + transform files only (test -> prod)
./scripts/deploy-workflows.sh medika-preorders promote

# Copy + transform + deploy to server
./scripts/deploy-workflows.sh medika-preorders promote --deploy
```

### Deploy prod workflows

```bash
./scripts/deploy-workflows.sh medika-preorders --env prod deploy
```

## DataTable Management

```bash
# Sync schemas from server to local registry
./scripts/sync-datatables.sh pull

# Create new tables (id: null in registry) on server
./scripts/sync-datatables.sh push

# Show differences
./scripts/sync-datatables.sh diff
```

### Inspect DataTables

```bash
./helpers/datatables.sh list                  # list all tables
./helpers/datatables.sh rows TABLE_ID [N]     # show first N rows
./helpers/datatables.sh count TABLE_ID        # count rows
```

## Debugging

```bash
# List recent executions
./helpers/executions.sh list [N]

# Show failed executions
./helpers/executions.sh errors [N]

# Per-node breakdown of an execution
./helpers/executions.sh detail EXEC_ID

# Inspect a specific node's output (full data, no truncation)
./helpers/executions.sh node EXEC_ID NODE_NAME

# Executions for a specific workflow
./helpers/executions.sh wf WORKFLOW_ID [N]

# Auto-debug last failure
./helpers/executions.sh debug

# List workflows with active/inactive status
./helpers/inspect.sh list

# Show nodes in a workflow
./helpers/inspect.sh nodes WORKFLOW_ID

# Diff server vs local file
./helpers/inspect.sh diff WORKFLOW_ID FILE
```

> **Note:** The `detail`, `node`, and `debug` commands use the n8n API's `includeData=true` parameter to fetch full node-level output. This parameter only works on the single-execution endpoint (`GET /executions/{id}`), not on the list endpoint.

## Common Commands

```bash
docker compose up -d              # start
docker compose down               # stop
docker compose restart            # restart
docker compose logs -f n8n        # logs
docker compose pull && docker compose up -d   # update n8n
```

## Working with Claude Code

This repo is set up for use with [Claude Code](https://claude.com/claude-code). Claude can read/edit workflow JSON files, run the deploy and helper scripts, inspect executions, and debug failures — all through the CLI.

### What Claude can do

- **Edit workflows** — Read and modify workflow JSON files directly (add/remove nodes, change parameters, fix connections)
- **Deploy workflows** — Run `./scripts/deploy-workflows.sh` to push changes to the n8n server
- **Pull workflows** — Sync server state back to local files
- **Promote test to prod** — Run the promote command to copy and transform workflows
- **Inspect executions** — List recent runs, check failures, drill into per-node output
- **Inspect workflows** — List active workflows, view node configs, diff server vs local
- **Manage DataTables** — Sync schemas, list rows, check table state
- **Debug failures** — Run `./helpers/executions.sh debug` to auto-analyze the last failed execution

### Prerequisites

An SSH tunnel must be active for Claude to reach the n8n API:

```bash
ssh -L 5678:localhost:5678 deploy@YOUR_SERVER_IP
```

### Getting oriented

New to the repo? Start here:

```
"Explain the workflow architecture — what does each WF do?"
"Walk me through what happens when a pre-order email arrives"
"What credentials and APIs does this project use?"
"What's the difference between test and prod workflows?"
```

Claude has access to the full implementation plan (`docs/medika_preorder_automation.md`) and can read any workflow JSON to answer questions about the system.

### Example prompts

```
# Workflow development
"Add a 30-second timeout to the Wait node in WF-05"
"Deploy the orchestrator workflow to test"
"Pull all test workflows from the server"
"Promote medika-preorders to prod and deploy"

# Debugging
"What failed in the last execution?"
"Show me the output of the XLSX Parser node in execution 12345"
"List all inactive workflows"
"Why is WF-03 failing on the HTTP Request node?"

# Infrastructure
"Show me the last 5 executions for the orchestrator"
"How many rows are in the Customers DataTable?"
"Diff the local orchestrator file against the server version"
```

### Tips

- Always **pull before editing** to make sure local files match the server
- After Claude edits a workflow JSON, ask it to **deploy** — edits to local files don't affect the running server
- Claude has skills for n8n node configuration, expression syntax, and workflow patterns — invoke with `/n8n-*` commands
- The implementation plan at `docs/medika_preorder_automation.md` has full context on the workflow architecture, API specs, and data formats — point Claude to it for complex tasks

## Deployment

- [Server setup](docs/HETZNER-DEPLOYMENT.md) — Hetzner provisioning, Docker, SSH tunnel
- [Deployment order](docs/deployment_order.md) — Fresh server setup, dependency map, activation order
