# CI/CD Pipeline Plan

**Status**: Planned

## Overview

Automate linting, deployment, and promotion of n8n workflows via GitHub Actions.

```
  feature branch          main branch
  ┌────────────┐          ┌────────────┐
  │  push/PR   │          │   merge    │
  └─────┬──────┘          └─────┬──────┘
        │                       │
  ┌─────▼──────┐          ┌─────▼──────┐
  │  Lint only │          │   Lint     │
  │            │          │   Deploy   │ ← test env (optional)
  │  PR check  │          │   Promote  │ ← prod (manual trigger)
  └────────────┘          └────────────┘
```

## Workflows

### 1. PR Check (on pull_request)

Runs on every PR. Fast, no server access needed.

```yaml
# .github/workflows/lint.yml
name: Lint Workflows

on:
  pull_request:
    paths:
      - 'workflows/**'
      - 'scripts/lint-workflows.py'

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Lint workflow files
        run: python3 scripts/lint-workflows.py
```

### 2. Deploy to Test (on push to main)

Deploys test workflows after merge. Requires SSH tunnel or Tailscale/WireGuard to reach the n8n server.

```yaml
# .github/workflows/deploy-test.yml
name: Deploy Test Workflows

on:
  push:
    branches: [main]
    paths:
      - 'workflows/test/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Lint first
        run: python3 scripts/lint-workflows.py

      - name: Set up SSH tunnel
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.DEPLOY_SSH_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          ssh -fN -L 5678:localhost:5678 \
            -i ~/.ssh/deploy_key \
            -o StrictHostKeyChecking=no \
            deploy@${{ secrets.SERVER_IP }}

      - name: Create .env.workflow
        run: |
          cat <<EOF > .env.workflow
          DT_CUSTOMERS_ID=${{ secrets.DT_CUSTOMERS_ID }}
          DT_TOKENS_ID=${{ secrets.DT_TOKENS_ID }}
          MS_FOLDER_PROCESSING_ID=${{ secrets.MS_FOLDER_PROCESSING_ID }}
          MS_FOLDER_PROCESSED_ID=${{ secrets.MS_FOLDER_PROCESSED_ID }}
          MS_FOLDER_ERROR_ID=${{ secrets.MS_FOLDER_ERROR_ID }}
          EOF

      - name: Deploy test workflows
        env:
          N8N_API_KEY: ${{ secrets.N8N_API_KEY }}
        run: ./scripts/deploy-workflows.sh medika-preorders
```

### 3. Promote to Prod (manual trigger)

Production deployment is gated behind a manual workflow_dispatch trigger.

```yaml
# .github/workflows/promote-prod.yml
name: Promote to Production

on:
  workflow_dispatch:
    inputs:
      project:
        description: 'Project to promote'
        required: true
        default: 'medika-preorders'

jobs:
  promote:
    runs-on: ubuntu-latest
    environment: production  # requires approval in GitHub settings
    steps:
      - uses: actions/checkout@v4

      - name: Lint test workflows
        run: python3 scripts/lint-workflows.py ${{ inputs.project }}

      - name: Set up SSH tunnel
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.DEPLOY_SSH_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          ssh -fN -L 5678:localhost:5678 \
            -i ~/.ssh/deploy_key \
            -o StrictHostKeyChecking=no \
            deploy@${{ secrets.SERVER_IP }}

      - name: Create .env.workflow
        run: |
          cat <<EOF > .env.workflow
          DT_CUSTOMERS_ID=${{ secrets.DT_CUSTOMERS_ID }}
          DT_TOKENS_ID=${{ secrets.DT_TOKENS_ID }}
          MS_FOLDER_PROCESSING_ID=${{ secrets.MS_FOLDER_PROCESSING_ID }}
          MS_FOLDER_PROCESSED_ID=${{ secrets.MS_FOLDER_PROCESSED_ID }}
          MS_FOLDER_ERROR_ID=${{ secrets.MS_FOLDER_ERROR_ID }}
          EOF

      - name: Promote and deploy
        env:
          N8N_API_KEY: ${{ secrets.N8N_API_KEY }}
        run: ./scripts/deploy-workflows.sh ${{ inputs.project }} promote --deploy
```

## Prerequisites

### GitHub Secrets

| Secret | Description |
|--------|-------------|
| `DEPLOY_SSH_KEY` | SSH private key for `deploy@server` |
| `SERVER_IP` | Hetzner server IP |
| `N8N_API_KEY` | n8n API key |
| `DT_CUSTOMERS_ID` | Customers DataTable ID |
| `DT_TOKENS_ID` | Tokens DataTable ID |
| `MS_FOLDER_PROCESSING_ID` | Outlook Processing folder ID |
| `MS_FOLDER_PROCESSED_ID` | Outlook Processed folder ID |
| `MS_FOLDER_ERROR_ID` | Outlook Error folder ID |

### GitHub Environment

Create a `production` environment in repo Settings > Environments with:
- Required reviewers (yourself)
- Optional: deployment branch restriction to `main` only

### Server Access from CI

Options for reaching the n8n API from GitHub Actions:

1. **SSH tunnel** (shown above) — simplest, reuses existing setup
2. **Tailscale** — install Tailscale on server and CI runner, connect via private network
3. **WireGuard** — same idea, lighter weight

The SSH tunnel approach is the most consistent with the current setup.

## Rollback

If a deployment breaks something:

```bash
# Pull the last known-good state from server
./scripts/deploy-workflows.sh medika-preorders pull

# Or revert the git commit and redeploy
git revert HEAD
./scripts/deploy-workflows.sh medika-preorders
```

## Future: Pinned Data Tests in CI

Once pinned-data regression tests are set up (see `docs/pinned_data_testing.md`),
add a test step between lint and deploy:

```yaml
- name: Run regression tests
  env:
    N8N_API_KEY: ${{ secrets.N8N_API_KEY }}
  run: ./scripts/run-regression-tests.sh medika-preorders
```
