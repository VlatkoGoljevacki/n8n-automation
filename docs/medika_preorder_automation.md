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
WF-04: Data Validator          (validate required fields, flag issues)
WF-05: Approval Gate          (email + Wait form → manual approve/reject)
WF-06: Order Submitter        (POST to Medika Order API)
```

### Data Flow

```
[Outlook Trigger] ──→ [Config] → [ERP Token] → [Customer Cache] → [Sender Validation]
       │                                                                    ↓
       └──→ [Move to Processing]                              [Has Attachments?] → [XLSX Parser]
            (parallel, fire-and-forget)                                                  ↓
                                                                              [Data Validator]
                                                                                     ↓
                                                                          [Approval Gate (HITL)]
                                                                            ↓              ↓
                                                                      [Submit Order]   [Rejected]
                                                                            ↓              ↓
                                                                    [Move to Processed]  [Move to Processed]

Error paths (invalid sender, no attachments, parse failed) → [Move to Error]
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
- **Config**: Code node reads all env vars (`MEDIKA_ERP_URL`, `MEDIKA_ERP_USERNAME`, `MEDIKA_ERP_PASSWORD`, notification emails) and sets non-sensitive defaults (business center, discount, feature flags). Single source of truth — edit here to switch between dev and prod.
- **Customer Cache**: Loads customer/delivery-place registry from Medika's `Customers2` API into n8n Static Data with a configurable TTL (default 24h). On cache hit, builds lookup maps from stored data. On cache miss, authenticates via OAuth2 and fetches fresh data. See [Customer Registry Cache](#customer-registry-cache) below.
- **Email tracking**: Folder-based state tracking via Outlook folder moves (not mark-as-read):
  - **Immediately on trigger**: email moved from Inbox → `Processing` folder (parallel branch, fire-and-forget)
  - **On success** (order submitted or intentionally rejected): moved to `Processed` folder
  - **On error** (invalid sender, no attachments, parse failure): moved to `Processing Error` folder
  - Trigger is configured with `foldersToInclude: [Inbox]` so moved emails are never re-polled
- **Flow**:
  1. Config node loads environment variables + Move to Processing (parallel)
  2. Check ERP Token → fetch OAuth2 token if expired
  3. Check Customer Cache → fetch from `Customers2` API if stale
  4. Extract email metadata (sender, subject, attachments)
  5. Call WF-02 (sender validation) — if invalid → Move to Error
  6. Check attachments exist — if none → Move to Error
  7. Call WF-03 (XLSX parser) — if parse fails → Move to Error
  8. Call WF-04 (data validation) — cross-reference against customer lookup
  9. Call WF-05 (approval gate) — execution pauses here
  10. If approved: call WF-06 (submit order) → Move to Processed
  11. If rejected: → Move to Processed

## WF-02: Sender Validation

- **Input**: `senderEmail`, `emailSubject`
- **Phase 1 (monolith)**: Code node checks against a knowledge database of approved senders + pharmacy/customer mappings (see [Knowledge Database](#knowledge-database) below)
- **Phase 1+** (if external API exists): HTTP Request to sender validation API with 3 retries
- **Output**: `{ valid, senderEmail, senderName, customer, deliveryPlace, businessCenter, authorizedPharmacyIds }`
- **On invalid**: returns `{ valid: false, reason: "..." }` — orchestrator handles notification

The sender validation must resolve the sender email to Medika customer data needed for the order API: `Customer` (Medika customer ID), `DeliveryPlace` (delivery place ID), and `BusinessCenter` (regional center code).

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
  articleId:    ['šifra proizvoda', 'šifra artikla', 'sifra', 'šifra', 'sku', 'article_id',
                 'artikl_sifra', 'drug_code', 'product_code', 'code'],
  articleName:  ['naziv', 'name', 'artikl', 'proizvod', 'naziv_artikla', 'opis',
                 'naziv proizvoda', 'naziv artikla'],
  quantity:     ['kolicina', 'količina', 'qty', 'kom', 'amount', 'naručeno', 'kol'],
  pharmacyId:   ['šifra ljekarne', 'sifra ljekarne', 'ljekarna_id', 'pharmacy_id',
                 'kupac', 'id_ljekarne', 'customer_id'],
  pharmacyName: ['ljekarna', 'naziv_ljekarne', 'kupac_naziv', 'naziv ljekarne'],
  unit:         ['jedinica', 'mjera', 'jm', 'jed'],
  notes:        ['napomena', 'komentar', 'notes', 'poruka']
}
```

**Key insight**: The `articleId` column maps directly to Medika's `ArticleID` (= `variant.sku` in the Medika webshop). We trust the SKU from the XLSX and pass it straight to the `SaveTransferOrder` API. No article registry lookup needed.

Similarly, `pharmacyId` maps to the Medika `Customer` ID (= `stock_location_group.group_id` in the webshop). If present in the XLSX, it takes priority over the sender→customer mapping.

Minimum viable match: at least one article identifier (articleId OR articleName) + quantity.

Multi-pharmacy per sheet: if `pharmacyId`/`pharmacyName` column detected, group rows by it. Otherwise, entire sheet = one pharmacy (identified by sender mapping or sheet name).

### Canonical Order Line Format

Internal format used between WF-03 → WF-04 → WF-05 → WF-06:

```json
{
  "sourceSheet": "Sheet1",
  "sourceRow": 5,
  "articleId": "1301597",
  "articleName": "ASPIRIN 500 tbl 20X500mg",
  "quantity": 10,
  "unit": "kom",
  "pharmacyId": "290",
  "pharmacyName": "Ljekarna Centar",
  "notes": "",
  "parseMethod": "RULE_BASED",
  "parseConfidence": 1.0,
  "rawData": { "A": "1301597", "B": "ASPIRIN", "C": 10 }
}
```

- `articleId` — Medika's ArticleID (= variant SKU). Extracted directly from the XLSX "Šifra proizvoda" column. Passed straight to `SaveTransferOrder` as `ArticleID`.
- `pharmacyId` — Medika's Customer ID (= `stock_location_group.group_id`). Extracted from XLSX "Šifra ljekarne" if present, otherwise from sender→customer mapping.

Fields added by WF-04 (Data Validator):
- `valid` — boolean, whether the line has all required fields for API submission
- `errors` — array of strings for blocking issues (missing articleId, missing customer)
- `warnings` — array of strings for non-blocking issues (missing name, unknown pharmacy ID)
- `customer` — resolved Medika Customer ID (from lookup or sender mapping)
- `deliveryPlace` — resolved Medika DeliveryPlace ID (from lookup or sender mapping)
- `customerName` — resolved customer name from Customers2 registry
- `deliveryPlaceName` — resolved delivery place name from Customers2 registry

Lines with `valid: false` (errors) are flagged in the approval form and excluded from API submission. Lines with only warnings are still submitted but highlighted for review.

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
- Row 1: Headers (`Šifra proizvoda`, `Naziv`, `Količina`, `Jedinica`, `Napomena`, `Šifra ljekarne`)
- One sheet per pharmacy (sheet name = pharmacy name), or `Šifra ljekarne` column per row
- No merged cells, no formulas in data cells, no color-coded semantics

This reduces parsing complexity over time. The system works without it, but adoption makes everything more reliable.

## WF-04: Data Validator

- **Input**: Parsed order lines array + customer context + `customerLookup` (from Customers2 cache)
- **Purpose**: Validate required fields for API submission and cross-reference customer/delivery-place IDs against the Medika customer registry.
- **Per line**:
  1. Check `articleId` is present and non-empty (required for `SaveTransferOrder`) → **error** if missing
  2. Check `quantity` is a positive number → **error** if invalid
  3. Check `articleName` is present (for `ArticleDescCustomer`) → **warning** if missing
  4. Resolve customer + delivery place:
     - If `pharmacyId` from XLSX matches a delivery place in `customerLookup.deliveryPlaceById` → resolves both `customer` (parent) and `deliveryPlace`
     - If `pharmacyId` matches a customer in `customerLookup.customerById` → resolves `customer` only
     - If `pharmacyId` not found in registry → **warning** (could be new customer)
     - If no customer resolvable at all → **error**
  5. Fallback: use customer/deliveryPlace from sender mapping (WF-02) if XLSX doesn't contain pharmacy IDs
- **Output**: `{ validatedLines, invalidLines, summary: { valid, invalid, warnings } }`
  - Each line gets: `customer`, `deliveryPlace`, `customerName`, `deliveryPlaceName` (resolved from lookup)
  - Lines with `errors` → `valid: false` → excluded from API submission
  - Lines with only `warnings` → `valid: true` → highlighted in approval form for review
- **On issues**: Invalid lines appear in the approval form (WF-05) for the approver to review.

## WF-05: Approval Gate

- **Pattern**: Wait node with "Resume: On Form Submitted" (HITL pattern)
- **Flow**:
  1. Build HTML summary table with line items, validation status, customer info, parse method
     - Valid lines: green background, checkmark
     - Invalid lines (errors): red background, shows error messages
     - Warning lines: yellow background, shows warnings
     - AI-extracted lines: blue background, flagged for careful review
  2. Email summary + approval link (`{{ $resumeWebhookUrl }}`) to `config.approvalNotifyEmail`
  3. Wait node pauses execution (state persisted to DB)
  4. Approver clicks link → sees public form (no n8n login required): Decision (Approve/Reject/Request Changes) + Comments
  5. On submit: execution resumes, Process Decision passes all data through to orchestrator (config, validatedLines, customer, deliveryPlace, businessCenter, emailId, etc.)
- **Timeout**: 48 hours (configurable). On timeout → escalation email, log `APPROVAL_TIMEOUT`
- **Phase 2 enhancement**: Auto-approve for all-valid + trusted sender. Send confirmation email to sender.

**Requires n8n v2.0+** for Wait nodes to work correctly inside sub-workflows.

## WF-06: Order Submitter

- **Input**: Approved order payload (validated lines + customer data from WF-02)
- **Action**: Build `TransferOrderRequest` payload → POST to Medika Order API (3 retries, 5s delay)
- **Endpoint**: `POST https://testnar.medika.hr/api/SaveTransferOrder`
- **Auth**: OAuth2 Resource Owner Password Credentials (same as webshop ERP integration — `GET /Token` with `grant_type=password`, `MEDIKA_ERP_USERNAME`/`MEDIKA_ERP_PASSWORD`)
- **Output**: `{ submitted, orderId, status }` from Medika response

### Medika Order API — `SaveTransferOrder`

**Request** (`TransferOrderRequest`):

| Field | Type | Description | Source |
|---|---|---|---|
| `BusinessCenter` | string | Regional center: "10" Zagreb, "20" Split, "30" Rijeka, "60" Osijek | XLSX or sender mapping (default: "10") |
| `Customer` | string | Medika customer ID (`stock_location_group.group_id`) | XLSX "Šifra ljekarne" or sender mapping |
| `DeliveryPlace` | string | Delivery place ID (`stock_location.medika_id`) | Sender mapping or own DB |
| `CustomerOrderNumber` | string | Reference number | Generated: `MP-{emailId}-{timestamp}` |
| `CustomerOrderDate` | date | Reference date (`YYYY-MM-DD`) | Email received date |
| `Text` | string | Additional notes | Email subject |
| `Items` | array | Order line items (see below) | WF-03 parser + WF-04 validator |

**Item fields** (`TransferOrderItemRequest`):

| Field | Type | Description | Source |
|---|---|---|---|
| `ArticleID` | string | Medika's internal article ID (e.g. "1301597") | Directly from XLSX "Šifra proizvoda" column |
| `ArticleDescCustomer` | string | Customer's description for the article | `articleName` from XLSX |
| `Quantity` | float | Order quantity | `quantity` from XLSX |
| `DiscountPerc` | float | Discount percentage | Knowledge DB per customer, or 0.0 default |
| `Message` | string | Per-item note | `notes` from XLSX, or empty |

**Response** (`TransferOrder`): Returns the submitted order with additional fields set by Medika:
- `OrderID` (integer) — order ID set by Medika's system
- `Status` (integer) — 1: Received, 2: In process, 3: Processed
- Per item: `ItemID`, `ArticleDescMedika` (Medika's name), `Plant`, `UOM`

**Sample request**:
```json
{
  "BusinessCenter": "10",
  "Customer": "290",
  "DeliveryPlace": "7700001164",
  "CustomerOrderNumber": "MP-abc123-1709042400",
  "CustomerOrderDate": "2026-02-27",
  "Text": "Prednarudžba - Ljekarna Centar",
  "Items": [
    {
      "ArticleID": "1301597",
      "ArticleDescCustomer": "ASPIRIN",
      "Quantity": 5.0,
      "DiscountPerc": 0.0,
      "Message": ""
    }
  ]
}
```

---

## Customer Registry Cache

The orchestrator caches the full Medika customer/delivery-place list in n8n Workflow Static Data, avoiding repeated API calls.

### API Endpoint

**`GET {MEDIKA_ERP_URL}/api/Customers2`** (requires OAuth2 Bearer token)

Returns an array of all customers with nested delivery places:

```json
[
  {
    "ID": "2",
    "Type": "C",
    "OIB": "85461853135",
    "Name": "VRTIĆ V.NAZOR KASTAV DJEČJI VRTIĆ",
    "Name1": "VRTIĆ V.NAZOR KASTAV",
    "Name2": "DJEČJI VRTIĆ",
    "CountryCode": "HR",
    "City": "KASTAV",
    "PostCode": "51215",
    "Street": "SKALINI ISTARSKOG TABORA 1",
    "DeliveryPlaces": [
      {
        "ID": "7700004052",
        "Type": "D",
        "Name": "VRTIĆ V.NAZOR KASTAV DJEČJI VRTIĆ",
        "Name1": "VRTIĆ V.NAZOR KASTAV",
        "Name2": "DJEČJI VRTIĆ",
        "City": "KASTAV",
        "Street": "SKALINI ISTARSKOG TABORA 1"
      }
    ]
  }
]
```

**Customers2 vs Customers**: `Customers2` adds a `Name` field (combined `Name1` + `Name2`). Structure otherwise identical. Always use `Customers2`.

### Key fields

| Field | Maps to API | Description |
|---|---|---|
| Customer `ID` | `Customer` in `SaveTransferOrder` | Medika customer ID (e.g. "290") |
| DeliveryPlace `ID` | `DeliveryPlace` in `SaveTransferOrder` | Delivery place ID (e.g. "7700001164") |
| `Name` | Display only | Combined name (`Name1` + `Name2`) |
| `OIB` | — | Croatian tax ID, useful for secondary matching |

### Cache Strategy

- **Storage**: n8n Workflow Static Data (`$getWorkflowStaticData('global')`)
- **TTL**: Configurable via `config.customerCacheTTLHours` (default: 24 hours)
- **Refresh**: On cache miss (stale or empty), the orchestrator authenticates via OAuth2 and fetches the full list from `Customers2`
- **Lookup maps built on load**:
  - `customerById[ID]` → `{ name, name1, name2, oib, city, postCode, street }`
  - `deliveryPlaceById[ID]` → `{ customerId, customerName, name, name1, name2, city, postCode, street }`
- **Full replace**: On refresh, the entire cache is overwritten (no merge). The ERP is the source of truth.
- **Passed downstream**: The `customerLookup` object flows to WF-04 (validation) and WF-05 (approval display) via Prepare Input nodes

### Orchestrator node flow

```
Config → Check ERP Token → Token Valid?
           ├─ YES → Check Customer Cache
           └─ NO  → Prepare Auth → Fetch Token → Store Token → Check Customer Cache

Check Customer Cache → Customers Cached?
           ├─ YES → Extract Email Metadata (continue)
           └─ NO  → Fetch Customers API (HTTP GET /api/Customers2, uses cached token)
                     → Store Customer Cache → Extract Email Metadata
```

### Future enhancements

- **Force refresh on lookup miss**: If WF-04 encounters an unknown customer/delivery-place ID, trigger a cache refresh and retry before flagging as invalid
- **Shorter TTL for high-churn environments**: Reduce to 1-4 hours if new customers are added frequently
- **Search by OIB or name**: Fuzzy matching against `OIB` or `Name` fields when numeric ID lookup fails

---

## Knowledge Database

### Data Strategy

**Primary source**: The XLSX attachments themselves. Pharmacies include Medika SKUs ("Šifra proizvoda") and customer IDs ("Šifra ljekarne") in their order spreadsheets. We trust this data and pass it directly to the API.

**Fallback**: Sender → customer mapping for cases where the XLSX doesn't include pharmacy/customer identifiers. Stored in our own DB (not Medika's).

**No article registry needed**: We don't maintain an article catalog. The SKU in the XLSX IS the Medika `ArticleID`. If it's wrong, the Medika API will reject it and we notify via email.

### Medika Data Model (from webshop analysis)

Key relationships discovered in the Medika webshop codebase (`/home/wladisha/repos/medika`):

| Concept | Medika DB Table | Key Field | Maps to API Field |
|---|---|---|---|
| Pharmacy chain/affiliation | `spree_stock_location_groups` | `group_id` | `Customer` |
| Individual pharmacy | `spree_stock_locations` | `medika_id` | `DeliveryPlace` |
| Article/Product | `spree_variants` | `sku` | `ArticleID` |
| Business center | — | hardcoded `'10'` | `BusinessCenter` |

### ERP Authentication

The Medika ERP uses **OAuth2 Resource Owner Password Credentials**:
- **Token endpoint**: `GET {MEDIKA_ERP_URL}/Token` with `grant_type=password`
- **Credentials**: `MEDIKA_ERP_USERNAME` / `MEDIKA_ERP_PASSWORD` (env vars, read in Config node)
- **Usage**: `Authorization: Bearer <token>` on all API calls

This is the same auth flow used by the Medika webshop for `SaveOrder3`, stock updates, and price list downloads.

### Token Caching

The ERP token is long-lived and cached in n8n Static Data to avoid unnecessary auth calls.

**Orchestrator (WF-01):**
- At startup, checks `$getWorkflowStaticData('global')` for `erpToken` + `erpTokenExpiresAt`
- If valid (not expired, with 5 min buffer): uses cached token for Customers2 API
- If expired/missing: fetches new token via OAuth2, stores in static data with parsed expiry
- Token expiry parsed from response: `.expires` (ISO date string) or `expires_in` (seconds), fallback 1h

**Order Submitter (WF-06):**
- Manages its own token cache in its own static data (sub-workflows have separate static data)
- Same check/fetch/store pattern as orchestrator
- Independent cache because WF-06 is a self-contained sub-workflow

**Token flow in orchestrator:**
```
Config → Check ERP Token → Token Valid?
           ├─ YES → Check Customer Cache (uses cached token)
           └─ NO  → Prepare Auth → Fetch Token (HTTP) → Store Token → Check Customer Cache
```

**Refresh strategy**: Proactive — check expiry before use, refresh if within 5 min of expiring. No retry-on-401 logic yet (future enhancement).

### 1. Sender → Customer Mapping

Fallback for when XLSX doesn't contain pharmacy identifiers. Used by WF-02.

| Field | Example | Description |
|---|---|---|
| `email` | `narudzbe@ljekarna-centar.hr` | Sender email (exact match) |
| `domain` | `ljekarna-centar.hr` | Domain fallback (if email not found) |
| `senderName` | `Ljekarna Centar` | Display name |
| `customer` | `290` | Medika Customer ID (`group_id`) |
| `deliveryPlace` | `7700001164` | Medika Delivery Place ID (`medika_id`) |
| `businessCenter` | `10` | Medika Business Center (10/20/30/60) |
| `defaultDiscountPerc` | `0.0` | Default discount for this customer |
| `active` | `true` | Whether this sender is authorized |

**Storage options** (in order of preference for Phase 1):
1. Hardcoded in WF-02 Code node (current — simplest for demo)
2. n8n DataTable (editable in UI, no deploy needed)
3. Own database / JSON file

### 2. Open Questions

- [x] What authentication does `testnar.medika.hr` require? → **OAuth2 password grant** (same as webshop)
- [x] How to resolve Customer/DeliveryPlace IDs? → **Customers2 API** (`GET /api/Customers2`) returns full list. Cached in n8n Static Data with 24h TTL. DeliveryPlace IDs map back to their parent Customer ID.
- [ ] Is `DiscountPerc` per-customer, per-article, or always 0?
- [ ] Can one email contain orders for multiple `Customer`/`DeliveryPlace` combinations?
- [ ] What happens if an `ArticleID` is wrong or discontinued? (API error format?)
- [ ] Is `DeliveryPlace` always needed, or can it be omitted if `Customer` is provided?
- [ ] Do we need `MEDIKA_ERP_USERNAME`/`MEDIKA_ERP_PASSWORD` for the test environment?

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
# Medika ERP API (read by Config node in WF-01 Orchestrator)
MEDIKA_ERP_URL=https://testnar.medika.hr
MEDIKA_ERP_USERNAME=your-erp-username
MEDIKA_ERP_PASSWORD=your-erp-password

# Notifications (optional)
# MEDIKA_PREORDERS_APPROVAL_EMAIL=approval@medika.hr
# MEDIKA_PREORDERS_ERROR_EMAIL=errors@medika.hr
```

### Config Node (WF-01 Orchestrator)
All configuration is centralized in the Config Code node at the start of the orchestrator. Sensitive values come from env vars, non-sensitive values are defined as defaults in the node itself.

**From environment variables** (sensitive):
- `MEDIKA_ERP_URL` — ERP API base URL (default: `https://testnar.medika.hr`)
- `MEDIKA_ERP_USERNAME` — ERP OAuth2 username
- `MEDIKA_ERP_PASSWORD` — ERP OAuth2 password
- `MEDIKA_PREORDERS_APPROVAL_EMAIL` — approval notification recipient
- `MEDIKA_PREORDERS_ERROR_EMAIL` — error notification recipient

**Defined in Config node** (non-sensitive, edit to switch dev/prod):
- `businessCenterDefault` — default business center code (`'10'`)
- `defaultDiscountPerc` — default discount percentage (`0.0`)
- `customersApiPath` — customer registry endpoint (`'/api/Customers2'`)
- `customerCacheTTLHours` — customer cache TTL in hours (`24`)
- `parseHtmlBody` — whether to parse HTML email body (`false`)
- `aiParsingEnabled` — whether to use AI fallback for XLSX parsing (`true`)

### n8n Variables (Settings > Variables in UI)
Only used for values that need to be accessible across unrelated workflows:
- `MEDIKA_PREORDERS_LLM_API_KEY` — API key for AI fallback parsing (Claude)

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
| Customers2 API down | No | Use stale cache if available, otherwise fail + notify |
| Customer/DeliveryPlace not in registry | No | Warning in WF-04, highlighted in approval form |
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
| 4 | WF-02: Sender validation | 1h | 0.5h | Hardcoded approved senders + domain fallback. Passthrough trigger, data context fix. |
| 5 | WF-03: XLSX parser + AI fallback | 5-7h | 0.5h | Rule-based column detection + Claude API fallback. JSON created, not yet e2e tested. |
| 6 | WF-04: Data validator + customer lookup | 1-1.5h | 0.5h | Validates required fields, cross-references Customers2 registry. |
| 7 | WF-05: Approval gate (Wait form) | 2-3h | 0.25h | Wait form + email summary + decision routing. |
| 8 | WF-06: Order submitter (mock) | 1h | 0.25h | Build payload → HTTP POST → process response. |
| 9 | Orchestrator wiring (WF-03→06) | — | 0.5h | Replace TODO NoOps, add Prepare Input nodes, binary re-attachment. |
| 10 | Deploy script fixes | — | 1h | .env export, jq control chars, JSON body corruption, PUT vs POST. |
| 11 | Customer registry cache (Customers2 API) | — | 0.5h | Static Data cache with TTL, OAuth2 auth, lookup maps, WF-04 cross-ref. |
| 12 | ERP token caching + folder-based email tracking | — | 0.5h | Token cache in orchestrator + WF-06. Outlook folder moves (Processing/Processed/Error) replace mark-as-read. |
| 13 | WF-05 fixes + deploy pull command | — | 0.5h | Updated HTML summary fields, config refs, data passthrough. Added `pull` to deploy script. |
| 14 | Integration testing + fixes | 2-3h | | End-to-end with test emails |
| 15 | Standard XLSX template | 0.5h | | Simple Excel file |
| | **Total** | **~17-21h** | **~7h** | Tasks 4-13 done. E2E testing + template remaining. |

**Demo scope**: Test email account → parse XLSX (rule-based + AI fallback) → validate against mock data → approval form → submit to Medika test API (`testnar.medika.hr`). Happy path + basic error handling + AI parsing wow factor.

**Not in demo**: Real sender list from Medika, full article ID mapping, dual-LLM determinism checks, production edge cases, audit microservice.

### Phase 1: Production Core Pipeline (~2-3 weeks after demo)
- Populate knowledge database with real sender→customer mappings from Medika
- Populate article ID mapping (full Medika article catalog or search API)
- Connect to production Medika Order API (`nar.medika.hr` vs `testnar.medika.hr`)
- Implement API authentication for `testnar.medika.hr` / `nar.medika.hr`
- Harden error handling for all edge cases
- Test with 10+ real XLSX samples, iterate column detection
- Production email account setup (Azure AD app registration for `prednarudzbe@medika.hr`)
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

### Deploy Script

`scripts/deploy-workflows.sh` — deploys and pulls workflow JSON files via n8n REST API.

```bash
# Deploy all medika workflows
./scripts/deploy-workflows.sh

# Deploy a specific workflow
./scripts/deploy-workflows.sh workflows/medika_preorder_01_orchestrator.json

# Pull all workflows (saves UI-configured values: credentials, folder IDs, sub-workflow IDs)
./scripts/deploy-workflows.sh pull

# Pull a specific workflow
./scripts/deploy-workflows.sh pull workflows/medika_preorder_01_orchestrator.json
```

**Workflow after UI changes**: Edit in n8n UI → `pull` to save to git → future `deploy` preserves those values.

**What pull saves**: credential references (name + ID), folder IDs, node positions, sub-workflow bindings — everything configured via the UI. Secrets stay in n8n's encrypted credential store and never touch git.

---

## Troubleshooting & Lessons Learned

Issues encountered during implementation and how they were resolved.

### Azure AD / Microsoft OAuth2

| Issue | Error | Fix |
|---|---|---|
| Personal Outlook.com can't create app registrations | "The ability to create applications outside of a directory has been deprecated" | Sign up for Azure free account to get an Azure AD tenant |
| M365 Developer Program sandbox | "Not eligible for sandbox subscription" | Use Azure free account instead |
| OAuth2 audience mismatch | `invalid_request`: "The request is not valid for the application's 'userAudience' configuration. In order to use /common/ endpoint, the application must not be configured with 'Consumer'" | In Azure AD app registration, change "Supported account types" from "Personal Microsoft accounts only" to "Accounts in any organizational directory and personal Microsoft accounts". Then **delete and recreate** the n8n credential (changing Azure settings alone isn't enough). |
| SMTP auth disabled | `535 5.7.139 SmtpClientAuthentication is disabled for the Mailbox` | Personal Outlook.com accounts have SMTP auth disabled with no toggle to enable. Microsoft is deprecating basic SMTP auth entirely. Use Microsoft Graph API via OAuth2 instead. |
| SSL wrong version on SMTP | `tls_validate_record_header:wrong version number` | Use STARTTLS (SSL off) on port 587, not direct SSL. Moot since we switched to Graph API. |
| Redirect URI mismatch | OAuth callback fails silently | Redirect URI in Azure must exactly match n8n's callback: `https://<n8n-url>/rest/oauth2-credential/callback` |

### n8n REST API (Deploy Script)

| Issue | Error | Fix |
|---|---|---|
| CLI import creates corrupted IDs | `n8n import:workflow` produced newline-delimited JSON, concatenating two workflow IDs | Rewrote deploy script to use REST API instead of CLI |
| PUT body parse failure | `Failed to parse request body` (HTTP 500) | Shell variable `payload=$(jq ...)` + `echo "$payload"` mangles special characters in jsCode strings. Fix: pipe `jq` output directly to `curl` via `jq '...' file.json \| curl ... -d @-` |
| PUT returns 405 | `PUT method not allowed` | Was actually an auth issue — `source .env` doesn't export variables. The deploy script's `set -a; source .env; set +a` also didn't work reliably. Fix: read .env line-by-line with `export "$line"` |
| Read-only fields rejected | `request/body/active is read-only`, `request/body/tags is read-only` | Strip all read-only fields before POST/PUT: `jq 'del(.active, .id, .versionId, .tags, .meta, .updatedAt, .createdAt)'` |
| jq can't parse API response | `Invalid string: control characters from U+0000 through U+001F` | n8n API returns jsCode with unescaped control characters. Fix: use Python (`json.load`) instead of jq to extract name→id mapping from the workflow list response |
| Bash arithmetic exits under `set -e` | `((failed++))` exits with code 1 when variable is 0 | Use `failed=$((failed + 1))` instead of `((failed++))` |
| Corrupted workflow can't be deleted from UI | "Could not archive the workflow" | Use REST API with URL-encoded ID: `curl -X DELETE '.../workflows/ID1%0AID2'` |

### n8n Workflow Configuration

| Issue | Error | Fix |
|---|---|---|
| Trigger output mode parameter name | `"simple": false` was silently ignored by n8n, defaulting to simplified output | Correct parameter is `"output": "raw"` (options: `"simple"`, `"raw"`, `"fields"`) |
| Trigger filter parameters location | `readStatus` and `hasAttachments` under `"options"` were ignored | These belong under `"filters"`, not `"options"`. `"options"` is only for `downloadAttachments` etc. |
| Sub-workflow rejects input | "This workflow isn't set to accept any input data" | Add `"inputSource": "passthrough"` to the `executeWorkflowTrigger` parameters |
| Data context lost after sub-workflow | `$json.hasAttachments` undefined after WF-02 returns (current context is validation result, not email) | Reference the original node: `$('Extract Email Metadata').item.json.hasAttachments` |
| `from` field structure depends on output mode | With `output: "raw"`, `from` is a nested object, not a flat string | Use `$json.from.emailAddress.address` (not `$json.from`) |
| Binary data lost after sub-workflow | WF-03 needs XLSX binary, but after WF-02 only validation JSON is in context | Added "Prepare Parser Input" Code node that re-attaches binary: `$('Extract Email Metadata').first().binary` |

### Key n8n Patterns Learned

1. **Sub-workflow data passing**: Execute Workflow Trigger with `"inputSource": "passthrough"` receives whatever the parent sends. The parent's Execute Workflow node passes current item (JSON + binary).

2. **Referencing earlier nodes after sub-workflow calls**: After a sub-workflow returns, `$json` only contains the sub-workflow's output. To access earlier data, use `$('Node Name').item.json.field` or `$('Node Name').first().binary`.

3. **Deploy script architecture**: Use REST API (not CLI), pipe jq→curl directly (no shell variables for JSON), parse API responses with Python (not jq, due to control characters), and export .env variables explicitly.

4. **Outlook Trigger parameters**: The UI parameter names don't always match what you'd guess. Always verify deployed node parameters by fetching via API: `GET /api/v1/workflows/{id}`.

---

## Verification Plan

1. **Unit test each sub-workflow** independently using n8n's Manual Trigger + pinned test data
2. **XLSX parsing test**: collect 10+ real XLSX samples from senders, verify column detection succeeds on all
3. **End-to-end test**: send a test email with a sample XLSX → verify it flows through all stages to the approval form
4. **AI fallback test**: send a deliberately non-standard XLSX → verify AI parsing extracts correct data
5. **Approval flow test**: click the approval link, submit the form, verify execution resumes
6. **Error paths**: test invalid sender, corrupt XLSX, missing drug codes, approval timeout
7. **Audit verification**: check that all status transitions are logged correctly
