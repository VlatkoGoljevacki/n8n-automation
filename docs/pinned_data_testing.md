# Pinned Data Testing Plan

**Status**: Planned — implement after the lint pipeline is running.

## Goal

Run deterministic regression tests for n8n workflows by mocking external API and LLM calls with **pinned data** (fixed node outputs). This avoids hitting real services during testing while validating that the workflow logic (Code nodes, If branches, data transforms) behaves correctly.

## How Pinned Data Works in n8n

Any node can have a `pinData` field that overrides its real execution with fixed output:

```json
{
  "name": "Fetch Email Raw",
  "type": "n8n-nodes-base.httpRequest",
  "parameters": { ... },
  "pinData": [
    {
      "json": {
        "id": "AAMk...",
        "subject": "Narudzba 2024-03",
        "from": { "emailAddress": { "address": "pharmacy@example.com" } },
        "hasAttachments": true,
        "attachments": [ ... ]
      }
    }
  ]
}
```

When a node has `pinData`, n8n skips execution and uses the pinned output instead. This is how we mock:
- **HTTP Request nodes** (Graph API, ERP API)
- **OpenAI/LLM nodes** (email classification, data extraction)
- **DataTable nodes** (customer lookups)

## Architecture

```
test-fixtures/
├── medika-preorders/
│   ├── cases/
│   │   ├── 01_standard_xlsx_order.json       # input + expected output
│   │   ├── 02_email_body_order.json
│   │   ├── 03_non_order_email.json
│   │   ├── 04_missing_pharmacy_ids.json
│   │   └── 05_multi_xlsx_rejection.json
│   └── pins/
│       ├── graph_api_email.json              # reusable pin data
│       ├── erp_token.json
│       ├── customer_lookup.json
│       └── ai_classify_order.json

scripts/
└── run-regression-tests.sh                   # test runner
```

### Test Case Format

Each test case JSON defines:

```json
{
  "name": "Standard XLSX order — rule-based parsing",
  "description": "Email with a standard XLSX attachment that rule-based parser can handle",
  "workflow": "01b_process_email.json",
  "pins": {
    "Fetch Email Raw": "pins/graph_api_email.json",
    "WF-00b: Get Graph Token": "pins/erp_token.json",
    "WF-00b: Get ERP Token": "pins/erp_token.json",
    "AI: Classify Email": "pins/ai_classify_order.json",
    "DT: Lookup Delivery Places": "pins/customer_lookup.json",
    "Send Email": { "pinData": [{ "json": { "statusCode": 202 } }] }
  },
  "assertions": [
    {
      "node": "Parse Succeeded?",
      "output": 0,
      "check": "exists"
    },
    {
      "node": "Prepare Order Input",
      "field": "orderLines",
      "check": "length",
      "expected": 5
    },
    {
      "node": "WF-09: Process Order",
      "check": "executed"
    }
  ]
}
```

### Pin file format

Each pin file is a JSON array of items matching n8n's pinData format:

```json
[
  {
    "json": {
      "accessToken": "mock-token-12345",
      "expiresAt": "2099-01-01T00:00:00Z"
    }
  }
]
```

## Test Runner

The test runner script:

1. Reads the test case definition
2. Loads the target workflow JSON
3. Injects `pinData` into the specified nodes
4. Deploys the pinned workflow to the test server (with a temporary name)
5. Triggers execution via the n8n API (`POST /workflows/{id}/run`)
6. Waits for completion, fetches execution data
7. Runs assertions against node outputs
8. Cleans up (deletes the temporary workflow)

```bash
# Run all regression tests
./scripts/run-regression-tests.sh medika-preorders

# Run a single test case
./scripts/run-regression-tests.sh medika-preorders cases/01_standard_xlsx_order.json
```

## What to Pin vs What to Execute

| Node Type | Pin? | Reason |
|-----------|------|--------|
| HTTP Request (external API) | Yes | Don't hit Graph API, ERP |
| OpenAI / LLM nodes | Yes | Deterministic, no cost |
| DataTable nodes | Yes | Don't need real DB |
| Execute Workflow (sub-WF) | Yes | Pin the sub-WF's return value |
| Code nodes | **No** | This is what we're testing |
| If / Switch nodes | **No** | Logic we want to verify |
| Set / Merge nodes | **No** | Data transforms to validate |

## Test Cases to Build

### WF-01b: Process Email (main orchestrator)

| # | Case | Key assertion |
|---|------|--------------|
| 1 | Standard XLSX order | Rule-based parse succeeds, order submitted |
| 2 | Non-standard XLSX (AI fallback) | AI parse path taken, order submitted |
| 3 | Email body order (no attachment) | Body parser path taken, order submitted |
| 4 | Non-order email | Classified as non-order, warning email sent |
| 5 | Multiple XLSX attachments | Rejected with warning email |
| 6 | Parse failure | Warning email sent, moved to error folder |

### WF-03: XLSX Parser

| # | Case | Key assertion |
|---|------|--------------|
| 1 | Standard Croatian headers | `matched=true`, correct column mapping |
| 2 | English headers | `matched=true`, correct mapping |
| 3 | Unknown headers | `matched=false`, falls back to AI |
| 4 | Empty spreadsheet | `matched=false`, error message |
| 5 | Missing quantity column | `matched=false`, falls back to AI |

### WF-04: Data Validator

| # | Case | Key assertion |
|---|------|--------------|
| 1 | All valid lines | `summary.invalid == 0` |
| 2 | Missing pharmacy IDs | Lines flagged as invalid |
| 3 | Unknown pharmacy ID | Warning attached to line |

### WF-09: Process Order

| # | Case | Key assertion |
|---|------|--------------|
| 1 | All customers found | No missing IDs, order proceeds |
| 2 | Missing delivery place | `hasMissing=true`, refresh triggered |

## Workflow for Creating Pin Data

To capture real pin data from a successful execution:

```bash
# Run a real execution, then extract node outputs
./helpers/executions.sh node EXEC_ID "Fetch Email Raw" > test-fixtures/medika-preorders/pins/graph_api_email.json
```

Or manually construct minimal pin data that exercises the code paths you care about.

## Integration with CI

Once test cases are built, add to the GitHub Actions pipeline (see `docs/ci_cd_pipeline.md`):

```yaml
- name: Run regression tests
  env:
    N8N_API_KEY: ${{ secrets.N8N_API_KEY }}
  run: ./scripts/run-regression-tests.sh medika-preorders
```

Tests run after lint, before production promotion.
