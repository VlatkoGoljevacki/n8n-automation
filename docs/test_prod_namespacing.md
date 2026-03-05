# Test vs Production Workflow Namespacing

## Overview

A single n8n server runs both test and prod workflows simultaneously. They are separated by:
- **Directory structure**: `workflows/test/` vs `workflows/prod/`
- **Naming convention**: `[project-test]` vs `[project]` namespace prefix
- **Webhook paths**: `test-process-email` vs `process-email`

## Directory Structure

```
workflows/
  test/
    medika-preorders/        ← daily development
      00_error_handler.json
      00b_token_manager.json
      01_orchestrator.json
      ...
  prod/
    medika-preorders/        ← populated by promote command
      00_error_handler.json
      ...
  example_workflow.json      ← reference only
```

## Deploy Script Usage

All commands require a project name as the first argument.

### Daily Development (test env, default)

```bash
# Deploy all test workflows
./scripts/deploy-workflows.sh medika-preorders

# Pull latest from server
./scripts/deploy-workflows.sh medika-preorders pull

# Activate/deactivate
./scripts/deploy-workflows.sh medika-preorders publish
./scripts/deploy-workflows.sh medika-preorders unpublish
```

### Production

```bash
# Deploy prod workflows
./scripts/deploy-workflows.sh medika-preorders --env prod deploy

# Pull prod from server
./scripts/deploy-workflows.sh medika-preorders --env prod pull
```

### Promote Test → Prod

```bash
# Copy + transform files only (review before deploying)
./scripts/deploy-workflows.sh medika-preorders promote

# Copy + transform + deploy in one step
./scripts/deploy-workflows.sh medika-preorders promote --deploy
```

Promote transforms:
- `[medika-preorders-test]` → `[medika-preorders]` in workflow names
- `test-process-email` → `process-email` in webhook paths/URLs

### Single File

```bash
# Auto-detects project and env from path
./scripts/deploy-workflows.sh workflows/test/medika-preorders/01_orchestrator.json
```

## Sub-Workflow ID Remapping

When deploying multiple workflows, a second pass automatically remaps `executeWorkflow` node IDs. This resolves sub-workflow references within the same namespace using the `WF-XX` prefix convention.

For example, when deploying test workflows:
- Node `WF-03: Parse XLSX` → finds `[medika-preorders-test] WF-03: XLSX Parser` on server → patches ID

This happens automatically after every multi-file deploy. No static ID mapping needed.

## Naming Convention

| Environment | Workflow Name | Webhook Path |
|---|---|---|
| Test | `[medika-preorders-test] WF-01: Orchestrator` | `test-process-email` |
| Prod | `[medika-preorders] WF-01: Orchestrator` | `process-email` |

## Workflow

1. Edit workflows in `workflows/test/medika-preorders/`
2. Deploy to test: `./scripts/deploy-workflows.sh medika-preorders`
3. Test on server (test namespace doesn't affect prod)
4. When ready, promote: `./scripts/deploy-workflows.sh medika-preorders promote --deploy`
5. Pull to sync server state: `./scripts/deploy-workflows.sh medika-preorders pull`
