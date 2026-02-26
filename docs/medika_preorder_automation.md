# Medika Pre-Order Email Automation — Implementation Plan

## Context

Medika (pharmaceutical distributor) needs to automate processing of pre-order emails sent to `prednarudzbe@medika.hr`. Pharmacies send XLSX attachments with drug orders in non-standardized formats. The system must validate senders, parse XLSX files, validate drug codes against a registry, get manual approval, and submit orders via API.

**Architecture decision**: Start as a monolith (n8n only) with n8n Variables, DataTables, and execution history handling config/state/audit. Extract a microservice only if/when: (a) sender/pharmacy config needs a shared UI across systems, or (b) audit needs independent querying at scale. No forced microservice architecture.

**Deployment**: Shared n8n instance (existing Docker stack). All Medika pre-order resources are namespaced with `medika-preorders` prefix to keep them isolated from other workflows. Split to a dedicated instance if execution queue contention or different upgrade cycles become an issue.

**Namespace convention** (`medika-preorders`):
- Workflow names: `[medika-preorders] WF-00: Error Handler`, `[medika-preorders] WF-01: Orchestrator`, etc.
- n8n Variables: `MEDIKA_PREORDERS_POLL_INTERVAL`, `MEDIKA_PREORDERS_APPROVAL_EMAIL`, etc.
- n8n DataTables: `medika_preorders_approved_senders`, `medika_preorders_audit_log`
- Workflow tags in n8n UI: `medika-preorders`
- Credential names: `Medika Preorders - Microsoft Outlook`, `Medika Preorders - SMTP`
- Docs: `docs/medika_preorder_automation.md` (this file)
- Workflow files: `workflows/medika_preorder_*.json`

---

## Workflow Architecture

7 workflows total — 1 error handler + 1 orchestrator + 5 sub-workflows:

```
WF-00: Error Handler         (Error Trigger → email notification → audit log)
WF-01: Orchestrator           (Microsoft Outlook Trigger → calls WF-02..06 in sequence)
WF-02: Sender Validation      (validate sender email → check pharmacy auth)
WF-03: XLSX Parser            (multi-sheet parsing, rule-based column detection + AI fallback)
WF-04: Article Validator      (drug code/name lookup against registry API)
WF-05: Approval Gate          (email + Wait form → manual approve/reject)
WF-06: Order Submitter        (POST to Medika Order API)
```

### Data Flow

```
[Outlook Trigger] → [Sender Validation] → [XLSX Parser] → [Article Validator]
       ↓                                                        ↓
  audit: RECEIVED                                    audit: VALIDATED
                                                            ↓
                                              [Approval Gate (HITL)]
                                                            ↓
                                               [Order Submitter] → audit: COMPLETED
```

Each sub-workflow has "Continue On Fail" enabled at the orchestrator level, so failures are handled gracefully (log + notify) rather than crashing the pipeline.

---

## WF-00: Error Handler

- **Trigger**: Error Trigger node (auto-invoked on unhandled failure in any workflow)
- **Action**: Format error context → send email notification to `$vars.ERROR_NOTIFY_EMAIL` with execution link → log to audit
- **Config**: Every other workflow references WF-00 as its Error Workflow (Settings > Error Workflow)

## WF-01: Orchestrator

- **Trigger**: Microsoft Outlook Trigger (poll every N minutes, filter by `prednarudzbe@medika.hr` inbox/alias, unread only, download attachments)
  - Uses Microsoft Graph API via n8n's built-in Microsoft Outlook node
  - Requires Azure AD app registration with `Mail.Read` permission (delegated or application)
  - Swappable to IMAP or Gmail Trigger if provider changes — only the trigger node changes
- **Init**: Set node loads config from `$vars.*` (toggle for HTML body parsing, API URLs, notification emails)
- **Flow**:
  1. Audit log: `ORDER_RECEIVED`
  2. Check attachments exist (IF node on binary keys)
  3. Call WF-02 (sender validation) — if invalid, log + notify + stop
  4. Call WF-03 (XLSX parser) — once per attachment
  5. Split results by pharmacy (SplitInBatches)
  6. Call WF-04 (article validation) per batch
  7. Call WF-05 (approval gate) — execution pauses here
  8. If approved: call WF-06 (submit order)
  9. Audit log: `COMPLETED` or `REJECTED`
  10. Move/categorize email in Outlook: `PROCESSED` / `FAILED` (via Microsoft Outlook node "Update" or "Move" operation)

## WF-02: Sender Validation

- **Input**: `senderEmail`, `emailSubject`
- **Phase 1 (monolith)**: Code node checks against an n8n DataTable of approved senders + pharmacy mappings. DataTable columns: `email`, `domain`, `pharmacy_ids`, `sender_name`, `active`
- **Phase 1+** (if external API exists): HTTP Request to sender validation API with 3 retries
- **Output**: `{ valid, senderEmail, senderName, authorizedPharmacyIds }`
- **On invalid**: returns `{ valid: false, reason: "..." }` — orchestrator handles notification

**Why DataTable first**: No point building a microservice just for a lookup table. n8n DataTables are editable from the UI, no deployment needed. Migrate to API when the sender list is shared across systems.

## WF-03: XLSX Parser (most complex)

- **Input**: Binary XLSX attachment(s), config flags
- **Process per attachment**:
  1. Validate MIME type (`.xlsx` / `.xls`)
  2. Code node: list all sheet names using `xlsx` library (available in n8n Code nodes)
  3. Per sheet (SplitInBatches):
     - Parse raw rows via `xlsx.utils.sheet_to_json(sheet, { header: 1 })`
     - **Rule-based column detection** (see below)
     - If detection fails → **AI fallback** (see below)
     - Normalize to canonical format
  4. If `PARSE_HTML_BODY` is true: parse HTML tables from body with same detection logic
  5. Merge all results, grouped by pharmacy

### Rule-Based Column Detection

Scan first 10 rows for a "header row" where 2+ cells match known patterns:

```
KNOWN_HEADERS = {
  drugCode:     ['sifra', 'šifra', 'code', 'artikl_sifra', 'drug_code', 'product_code'],
  articleName:  ['naziv', 'name', 'artikl', 'proizvod', 'naziv_artikla', 'opis'],
  quantity:     ['kolicina', 'količina', 'qty', 'kom', 'amount', 'naručeno'],
  pharmacyId:   ['ljekarna_id', 'pharmacy_id', 'kupac', 'id_ljekarne'],
  pharmacyName: ['ljekarna', 'naziv_ljekarne', 'kupac_naziv'],
  unit:         ['jedinica', 'mjera', 'jm'],
  notes:        ['napomena', 'komentar', 'notes']
}
```

Minimum viable match: at least one drug identifier (code OR name) + quantity.

Multi-pharmacy per sheet: if `pharmacyId`/`pharmacyName` column detected, group rows by it. Otherwise, entire sheet = one pharmacy (identified by sheet name or sender authorization).

### Canonical Order Line Format

```json
{
  "sourceSheet": "Sheet1",
  "sourceRow": 5,
  "pharmacyId": "PH001",
  "pharmacyName": "Ljekarna Centar",
  "drugCode": "MED-12345",
  "articleName": "Ibuprofen 400mg",
  "quantity": 10,
  "unit": "kom",
  "notes": "",
  "parseMethod": "RULE_BASED",
  "parseConfidence": 1.0,
  "rawData": { "A": "MED-12345", "B": "Ibuprofen", "C": 10 }
}
```

### AI Fallback Parsing

When rule-based detection fails (`matched: false`), the sheet data is sent to an LLM:

1. Convert first ~50 rows of the unrecognized sheet to CSV text
2. HTTP Request node → LLM API (Claude or GPT) with structured prompt:
   ```
   You are a data extraction assistant. Below is spreadsheet data containing
   pharmacy drug orders. Extract each order line as a JSON object with fields:
   drugCode, articleName, quantity, unit, pharmacyId, pharmacyName.
   If a field is not present, set it to null.
   Return ONLY a valid JSON array. No other text.

   Data:
   [CSV rows here]
   ```
3. Code node: parse LLM JSON response, validate structure
4. Mark all lines: `parseMethod: "AI_EXTRACTED"`, `parseConfidence: 0.7`
5. These lines are auto-flagged in the approval form so the approver reviews them carefully

**Demo version**: Single LLM call, basic prompt, no verification. Works impressively on random formats.
**Production version** (Phase 2): Dual-LLM call (run twice with temperature=0, compare outputs). Disagree → flag for manual review. Full error handling for malformed LLM responses.

### XLSX Standardization Proposal

Distribute a standard template to senders:
- Row 1: Headers (`Šifra`, `Naziv`, `Količina`, `Jedinica`, `Napomena`)
- One sheet per pharmacy (sheet name = pharmacy ID or name)
- No merged cells, no formulas in data cells, no color-coded semantics

This reduces parsing complexity over time. The system works without it, but adoption makes everything more reliable.

## WF-04: Article Validator

- **Input**: Parsed order lines array
- **Per line** (batched to respect rate limits):
  1. Lookup by drug code → Medika registry API (exact match)
  2. If no code match → fuzzy search by name
  3. Score matches: `EXACT_MATCH`, `PROBABLE_MATCH` (similarity > 0.85), `UNMATCHED`
- **Output**: Validation summary with per-line match status, plus unmatched lines highlighted
- **Placeholder**: During dev, Code node returns mock matches. Swap to HTTP Request when API is ready.

## WF-05: Approval Gate

- **Pattern**: Wait node with "Resume: On Form Submitted" (HITL pattern)
- **Flow**:
  1. Build HTML summary of the order (table with line items, match statuses, flags)
  2. Email summary + approval link (`{{ $resumeWebhookUrl }}`) to `$vars.APPROVAL_NOTIFY_EMAIL`
  3. Wait node pauses execution (state persisted to DB)
  4. Approver clicks link → sees form with: Decision (Approve/Reject/Request Changes), Comments
  5. On submit: execution resumes, routes by decision
- **Timeout**: 48 hours (configurable). On timeout → escalation email to `$vars.ESCALATION_NOTIFY_EMAIL`, log `APPROVAL_TIMEOUT`
- **Phase 2 enhancement**: Auto-approve for all-EXACT_MATCH + trusted sender. Send confirmation email to sender.

**Requires n8n v2.0+** for Wait nodes to work correctly inside sub-workflows.

## WF-06: Order Submitter

- **Input**: Approved order payload
- **Action**: Transform to Medika API format → POST to Order API (3 retries, 5s delay)
- **Output**: `{ submitted, orderId, confirmationId }`
- **Placeholder**: During dev, use a mock webhook endpoint. Swap to real API when available.

---

## Audit Trail

### Dual-layer approach

1. **n8n execution history** (built-in): Every run logged automatically. Increase retention: `EXECUTIONS_DATA_MAX_AGE=8760` (1 year).
2. **Structured audit log**: HTTP Request nodes at each state transition POST to an audit endpoint. **Phase 1**: this can be a simple n8n DataTable or a lightweight webhook workflow that appends to a Google Sheet / JSON file. **Later**: extract to a dedicated audit service if query complexity demands it.

### Status states

```
ORDER_RECEIVED → SENDER_VALIDATED → PARSED → ARTICLES_VALIDATED
  → PENDING_APPROVAL → APPROVED → ORDER_SUBMITTED → COMPLETED

Failure branches:
  → SENDER_INVALID (terminal)
  → PARSE_FAILED (terminal)
  → APPROVAL_TIMEOUT → ESCALATED
  → REJECTED (terminal)
  → SUBMISSION_FAILED (terminal)
```

---

## Monolith vs. Microservice Decision Points

| Concern | Phase 1 (Monolith/n8n only) | Extract to microservice when... |
|---|---|---|
| Sender/pharmacy config | n8n DataTable (editable in UI) | Multiple systems need this data, or a custom admin UI is needed |
| Audit log | n8n execution history + DataTable/Sheet | Need complex queries, dashboards, or retention beyond n8n's DB |
| Drug registry | HTTP Request to existing Medika API | N/A — this is already external |
| Order submission | HTTP Request to Medika API | N/A — already external |
| XLSX parsing logic | n8n Code node | Parsing becomes so complex it needs its own test suite and deployment cycle |

**Principle**: Don't extract until the pain of keeping it in n8n exceeds the cost of maintaining a separate service.

---

## Infrastructure Changes

### docker-compose.yml updates
```yaml
# Add to n8n service environment:
- N8N_DEFAULT_BINARY_DATA_MODE=filesystem    # XLSX attachments on disk, not SQLite
- EXECUTIONS_DATA_MAX_AGE=8760               # 1 year retention
- EXECUTIONS_DATA_PRUNE=true
- EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000
```

### .env.example additions
```
SENDER_VALIDATION_API_URL=http://localhost:3000/api    # or n8n DataTable in Phase 1
DRUG_REGISTRY_API_URL=http://localhost:3001/api
ORDER_API_URL=http://localhost:3002/api
```

### n8n Variables (Settings > Variables in UI)
All prefixed with `MEDIKA_PREORDERS_`:
- `MEDIKA_PREORDERS_POLL_INTERVAL_MINUTES`
- `MEDIKA_PREORDERS_PARSE_HTML_BODY`
- `MEDIKA_PREORDERS_APPROVAL_NOTIFY_EMAIL`
- `MEDIKA_PREORDERS_ESCALATION_NOTIFY_EMAIL`
- `MEDIKA_PREORDERS_ERROR_NOTIFY_EMAIL`
- `MEDIKA_PREORDERS_APPROVAL_TIMEOUT_HOURS`

### Credentials (Settings > Credentials in UI)
- **Microsoft OAuth2** (for Outlook Trigger + Send Email via Microsoft Outlook node)
  - Requires Azure AD app registration: Azure Portal → App registrations → New
  - API permissions: `Mail.Read`, `Mail.ReadWrite`, `Mail.Send` (delegated or application)
  - Redirect URI: `https://<n8n-url>/rest/oauth2-credential/callback`
  - In n8n: Add "Microsoft Outlook OAuth2 API" credential with Client ID + Client Secret from Azure
- SMTP (fallback if Microsoft OAuth is not available for sending)

---

## Error Handling Summary

| Failure | Retry? | Action |
|---|---|---|
| Email auth failure | No | Email admin |
| Sender API unreachable | 3x, 2s | Then fail + notify |
| Sender not authorized | No | Log + email sender & process owner |
| XLSX corrupt/unreadable | No | Log + email sender |
| Column detection fails | No | AI fallback → if AI also fails, flag for manual review |
| Drug registry API down | 3x, 1s | Then fail + notify |
| Drug code not found | No | Fuzzy name search → flag in approval form |
| Approval timeout (48h) | No | Escalation email |
| Order API down | 3x, 5s | Then fail + notify |
| Any unhandled exception | No | WF-00 catches → email + audit |

---

## Time Estimates

### Weekend Demo (~17-21 hours)

A demo-ready system with a test inbox, mock APIs, and AI parsing is achievable in a focused weekend.

| # | Task | Est. Hours | Actual Hours | Notes |
|---|---|---|---|---|
| 1 | Infra setup (docker-compose, test email) | 1h | 0.25h | docker-compose, .env, .gitignore updated. Deploy script, credentials README. |
| 2 | WF-00: Error handler | 0.5h | 1h | 3 nodes: Error Trigger → Format Context → Send Email (Microsoft Outlook via Graph API). Most time on Azure AD OAuth2 setup: audience type gotcha, SMTP auth dead for personal accounts, redirect URI. |
| 3 | WF-01: Orchestrator | 2-3h | 1h | Trigger + metadata extraction + attachment routing done. Most time on deploy script debugging (REST API, read-only fields, bash arithmetic). Sub-workflow wiring TBD as we build each one. |
| 4 | WF-02: Sender validation (DataTable) | 1h | | Lookup against hardcoded list |
| 5 | WF-03: XLSX parser + rule-based detection | 3-4h | | Code node with header matching logic |
| 6 | WF-03b: AI fallback parsing | 2-3h | | LLM call for unrecognized formats |
| 7 | WF-04: Article validator (mock) | 1-1.5h | | Code node returning mock matches |
| 8 | WF-05: Approval gate (Wait form) | 2-3h | | Wait node config + email formatting |
| 9 | WF-06: Order submitter (mock) | 1h | | HTTP Request to mock endpoint |
| 10 | Integration testing + fixes | 2-3h | | End-to-end with test emails |
| 11 | Standard XLSX template | 0.5h | | Simple Excel file |
| | **Total** | **~17-21h** | **0h** | |

**Demo scope**: Test email account → parse XLSX (rule-based + AI fallback) → validate against mock data → approval form → mock API submission. Happy path + basic error handling + AI parsing wow factor.

**Not in demo**: Real Medika APIs, real sender list, dual-LLM determinism checks, production edge cases, audit microservice.

### Phase 1: Production Core Pipeline (~2-3 weeks after demo)
- Connect real Medika APIs (sender validation, drug registry, order submission)
- Harden error handling for all edge cases
- Real sender/pharmacy DataTable with actual data
- Test with 10+ real XLSX samples, iterate column detection
- Production email account setup (Azure AD app registration)
- Audit logging to DataTable

### Phase 2: AI Parsing + Auto-Confirmation (~2 weeks)
- Dual-LLM call for determinism in AI fallback
- Auto-approval for high-confidence orders from trusted senders
- HTML body parsing when `PARSE_HTML_BODY=true`

### Phase 3: Advanced (~2-4 weeks, as needed)
- Reporting/dashboards (query audit data)
- Sender status self-service webhook
- Email provider portability (IMAP / Gmail triggers as alternatives)
- Extract audit/config to microservice if justified

---

## Workflow Files

```
workflows/medika_preorder_00_error_handler.json
workflows/medika_preorder_01_orchestrator.json
workflows/medika_preorder_02_sender_validation.json
workflows/medika_preorder_03_xlsx_parser.json
workflows/medika_preorder_04_article_validator.json
workflows/medika_preorder_05_approval_gate.json
workflows/medika_preorder_06_order_submitter.json
workflows/medika_preorder_template.xlsx
```

Update `.gitignore` to track these: `!workflows/medika_preorder_**`

---

## Verification Plan

1. **Unit test each sub-workflow** independently using n8n's Manual Trigger + pinned test data
2. **XLSX parsing test**: collect 10+ real XLSX samples from senders, verify column detection succeeds on all
3. **End-to-end test**: send a test email with a sample XLSX → verify it flows through all stages to the approval form
4. **AI fallback test**: send a deliberately non-standard XLSX → verify AI parsing extracts correct data
5. **Approval flow test**: click the approval link, submit the form, verify execution resumes
6. **Error paths**: test invalid sender, corrupt XLSX, missing drug codes, approval timeout
7. **Audit verification**: check that all status transitions are logged correctly
