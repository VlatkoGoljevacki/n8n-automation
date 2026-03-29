# Lead Finder — Project Plan

> **Status:** Planning
> **Created:** 2026-03-08
> **Project namespace:** `lead-finder`

## Purpose

Automated pipeline to discover businesses in target verticals (starting with Hotels & Hospitality in Croatia), find their leadership contacts, and verify the data. Three phases:

1. **Business Discovery** — Find all businesses in a vertical, region by region
2. **People Finder** — Find leadership contacts (CEO, owner, founder, etc.)
3. **Contact Verification** — Verify emails, phones, cross-reference data

---

## Architecture Overview

```
                        ┌──────────────────┐
                        │  Google Sheets    │
                        │  (Lead Finder)    │
                        └──────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                 ▼
        ┌──────────┐    ┌──────────┐     ┌──────────┐
        │ Regions   │    │Businesses│     │  People  │
        │  Sheet    │    │  Sheet   │     │  Sheet   │
        └────┬─────┘    └────┬─────┘     └────┬─────┘
             │               │                 │
             ▼               ▼                 ▼
        ┌──────────┐    ┌──────────┐     ┌──────────┐
        │  WF-01   │───▶│  WF-02   │───▶ │  WF-03   │
        │ Business │    │  People  │     │ Contact  │
        │ Discovery│    │  Finder  │     │ Verifier │
        └──────────┘    └──────────┘     └──────────┘
              │               │                 │
              └───────────────┴─────────────────┘
                              │
                        ┌──────────┐
                        │  WF-00   │
                        │  Error   │
                        │ Handler  │
                        └──────────┘
```

### Workflows

| ID | Name | Purpose | Trigger | Status |
|----|------|---------|---------|--------|
| WF-00 | Error Handler | Catch errors, send email notifications | Error trigger | Done |
| WF-01 | Business Discovery | Google Places API → Businesses tab | Manual + Schedule | Done |
| WF-02 | People Finder | Orchestrator: calls search sub-workflows, extracts contacts | Manual + Schedule | Building |
| WF-02a | SerpApi Search | Google search via SerpApi → raw results | Sub-workflow | Future (needs signup) |
| WF-02b | Serper Search | Google search via Serper → raw results | Sub-workflow | Building |
| WF-02c | Hunter Search | Domain email discovery via Hunter.io → raw results | Sub-workflow | Future (needs signup) |
| WF-02d | OpenAI Search | Bing search via OpenAI web search → raw results | Sub-workflow | Building |
| WF-03 | Contact Verifier | Hunter verify + cross-reference | Manual + Schedule | Future |

---

## Google Sheets Structure

**One spreadsheet per country**, each with 3 tabs. This scopes data per country and makes it easy to share/manage independently.

```
Lead Finder — Croatia        (spreadsheet)
  ├── Regions                 (tab: 21 counties)
  ├── Businesses              (tab: hotels, resorts, etc.)
  └── People                  (tab: leadership contacts)

Lead Finder — Slovenia        (future, same 3 tabs)
Lead Finder — Montenegro      (future, same 3 tabs)
```

Workflows take a **spreadsheet ID** as input, so adding a country = create sheet + configure ID.

### Tab: Regions

Seed data for scanning. One row = one scannable unit.

| Column | Type | Description |
|--------|------|-------------|
| Region Type | text | county / state / province / district |
| Region Name | text | e.g., "Dubrovačko-neretvanska" |
| Region Name (EN) | text | e.g., "Dubrovnik-Neretva County" |
| Scan Status | text | pending / processing / done / error |
| Last Scanned | date | Timestamp of last scan |
| Businesses Found | number | Count from last scan |

**Initial seed (Croatia):** 21 counties:

1. Zagrebačka (Zagreb County)
2. Krapinsko-zagorska (Krapina-Zagorje)
3. Sisačko-moslavačka (Sisak-Moslavina)
4. Karlovačka (Karlovac)
5. Varaždinska (Varaždin)
6. Koprivničko-križevačka (Koprivnica-Križevci)
7. Bjelovarsko-bilogorska (Bjelovar-Bilogora)
8. Primorsko-goranska (Primorje-Gorski Kotar)
9. Ličko-senjska (Lika-Senj)
10. Virovitičko-podravska (Virovitica-Podravina)
11. Požeško-slavonska (Požega-Slavonia)
12. Brodsko-posavska (Brod-Posavina)
13. Zadarska (Zadar)
14. Osječko-baranjska (Osijek-Baranja)
15. Šibensko-kninska (Šibenik-Knin)
16. Vukovarsko-srijemska (Vukovar-Srijem)
17. Splitsko-dalmatinska (Split-Dalmatia)
18. Istarska (Istria)
19. Dubrovačko-neretvanska (Dubrovnik-Neretva)
20. Međimurska (Međimurje)
21. Grad Zagreb (City of Zagreb)

### Tab: Businesses

Discovered hotels, resorts, camps, etc.

| Column | Type | Description |
|--------|------|-------------|
| Google Place ID | text | Unique identifier (dedup key) |
| Name | text | Business name |
| Type | text | hotel / resort / camp / hostel / aparthotel / etc. |
| Region | text | Region name from Regions tab |
| Address | text | Full formatted address |
| Phone | text | Phone number |
| Email | text | Contact email (if found) |
| Website | text | Website URL |
| Rating | number | Google rating (1-5) |
| Google Maps URL | text | Link to Google Maps listing |
| People Status | text | pending / done / error |
| Last Updated | date | Timestamp |

### Tab: People

Leadership contacts linked to businesses.

| Column | Type | Description |
|--------|------|-------------|
| Business Name | text | FK to Businesses tab |
| Name | text | Person's full name |
| Title | text | Job title (CEO, Owner, Director, etc.) |
| Email | text | Direct email |
| Phone | text | Direct phone |
| LinkedIn | text | LinkedIn profile URL |
| Facebook | text | Facebook profile URL |
| Instagram | text | Instagram profile URL |
| Twitter | text | Twitter/X profile URL |
| Source | text | How we found them (search/hunter/website) |
| Verified | text | pending / verified / unverified / risky |
| Verification Date | date | When verified |
| Last Updated | date | Timestamp |

---

## Workflow Details

### WF-00: Error Handler

Reusable error handler pattern (same as medika).

- Catches errors from all lead-finder workflows
- Sends email notification with: workflow name, error message, failed node, execution link
- Email recipient: configurable via workflow variable

### WF-01: Business Discovery

**Input:** Spreadsheet ID (per country) + unprocessed rows from Regions tab (Scan Status = "pending")
**Output:** Rows written to Businesses tab

The workflow receives a spreadsheet ID as config. Each spreadsheet = one country. The country name is derived from the spreadsheet or set as a workflow variable.

```
Schedule/Manual Trigger
  → Read Regions tab (filter: Scan Status = pending)
  → For each region:
      → Mark region: Scan Status = processing
      → For each search term:
          → Google Places Text Search API
            Query: "{search_term} in {Region Name (EN)}, {Country}"
          → Paginate (follow nextPageToken for complete results)
      → Deduplicate results by Google Place ID
      → For each place: get Place Details (phone, website)
      → Upsert to Businesses tab (match on Google Place ID)
      → Update region: Scan Status = done, Businesses Found = N
  → Rate control: 2-second delay between API calls
```

**Google Places API Details:**
- Endpoint: `POST https://places.googleapis.com/v1/places:searchText`
- Auth: `X-Goog-Api-Key` header with PLACES_API key
- Field mask: `places.id,places.displayName,places.formattedAddress,places.nationalPhoneNumber,places.websiteUri,places.rating,places.types,places.googleMapsUri`
- Pagination: response includes `nextPageToken`, pass as body param for next page
- Returns up to 20 results per page

**Search Terms (configurable per niche):**

English + Croatian localized terms:

| English | Croatian | Notes |
|---------|----------|-------|
| hotel | hotel | Same in both languages |
| resort | odmaralište, ljetovalište | Multiple Croatian terms |
| boutique hotel | boutique hotel | Same |
| aparthotel | aparthotel | Same |
| spa hotel | spa hotel, toplice | |
| beach resort | plaža resort | Coastal regions |
| camping resort | kamp, kamping | |
| hostel | hostel | Same |
| wellness hotel | wellness hotel | Same |
| mountain lodge | planinski dom, gorska kuća | Interior regions |
| bed and breakfast | pansion, prenoćište | |
| hotel chain | hotelski lanac | |

**Niche config** can live as a JSON array in a Set node or workflow variable, making it easy to swap verticals later.

### WF-02: People Finder (Orchestrator)

**Input:** Businesses where People Status = "pending" (configurable batch size, default 20)
**Output:** Rows written to People tab
**Schedule:** Daily morning run, processes N businesses per run

```
Schedule/Manual Trigger
  → People Finder Config (batchSize: 20)
  → Read Businesses tab (filter: People Status = pending, limit to batchSize)
  → Has Businesses?
  → Loop Businesses (flat, one at a time)
    → Call WF-02a: SerpApi Search (returns raw results)      [FUTURE - needs signup]
    → Call WF-02b: Serper Search (returns raw results)
    → Call WF-02c: Hunter Search (returns raw results)       [FUTURE - needs signup]
    → Call WF-02d: OpenAI Search (returns raw results)
    → Combine Results (merge raw results from all sources)
    → OpenAI Extract Contacts (gpt-4.1-mini: structured extraction)
    → Append to People tab
    → Mark business People Status = done
    → Rate Limit Delay (20s between businesses)
    → Loop Businesses
  → Done
```

Sub-workflows are called sequentially. Each returns raw search results as JSON.
The orchestrator combines all raw results and feeds them to OpenAI for final extraction.
Sub-workflows that aren't ready yet (SerpApi, Hunter) are skipped — the orchestrator
handles missing results gracefully.

### WF-02a: SerpApi Search (FUTURE)

**Status:** Blocked — needs SerpApi signup
**Input:** businessName, website, region (via Execute Workflow Trigger)
**Output:** Raw search result snippets

```
Execute Workflow Trigger (passthrough)
  → Build search queries:
    - "{businessName} owner CEO founder director vlasnik direktor"
    - "{businessName} {domain} management team leadership"
    - "site:{domain} about team contact"
  → SerpApi HTTP Request (Google Search)
  → Return raw snippets as JSON
```

### WF-02b: Serper Search

**Input:** businessName, website, region (via Execute Workflow Trigger)
**Output:** Raw search result snippets

```
Execute Workflow Trigger (passthrough)
  → Build search queries:
    - "{businessName} owner CEO founder director vlasnik direktor"
    - "{businessName} {domain} management team leadership"
    - "{businessName} LinkedIn"
  → Serper HTTP Request (POST https://google.serper.dev/search)
  → Return combined snippets as JSON
```

### WF-02c: Hunter Domain Search (FUTURE)

**Status:** Blocked — needs Hunter.io signup
**Input:** website domain (via Execute Workflow Trigger)
**Output:** Emails, names, positions found at domain

```
Execute Workflow Trigger (passthrough)
  → Extract domain from website URL
  → Hunter Domain Search (built-in node)
  → Return emails/names/positions as JSON
```

### WF-02d: OpenAI Web Search

**Input:** businessName, website, region (via Execute Workflow Trigger)
**Output:** Raw search results from Bing via OpenAI

```
Execute Workflow Trigger (passthrough)
  → OpenAI Chat (gpt-4.1-mini with web search tool enabled)
    - "Find the owners, founders, CEO, directors of {businessName} ({website}).
       Return their names, titles, emails, phone numbers, and social media profiles."
  → Return raw response as JSON
```

### OpenAI Contact Extraction (in orchestrator)

After all sub-workflow results are combined, a single OpenAI call extracts structured contacts.

**System Prompt:**
```
You are a business intelligence analyst. Given search results and email data
about a hotel/hospitality business, extract the senior leadership contacts.

For each person found, return a JSON array:
[{
  "name": "Full Name",
  "title": "Job Title",
  "email": "email@domain.com",
  "phone": "+385...",
  "linkedin": "https://linkedin.com/in/...",
  "facebook": "",
  "instagram": "",
  "twitter": ""
}]

Priority order: CEO, Founder, Owner, Managing Director, General Manager,
Director, COO, CFO, Head of Operations.

Rules:
- Only include people clearly associated with THIS specific business
- Prefer direct/personal emails over generic (info@, reception@)
- Include Croatian title variations: vlasnik (owner), direktor (director),
  ravnatelj (head/principal), predsjednik uprave (CEO)
- If no leadership found, return empty array []
- Do NOT fabricate data. Only return what you can confirm from the sources.
```

**Model fallback:** gpt-4.1-mini → gpt-5-mini (if first returns empty/error).

### WF-03: Contact Verifier

**Input:** People where Verified = "pending"
**Output:** Updated Verified status on People sheet

```
Schedule/Manual Trigger
  → Read People sheet (filter: Verified = pending)
  → Batch with delays
  → For each contact:
      → If email exists:
          → Hunter Email Verifier API
          → Result: deliverable / risky / undeliverable
      → If website exists on linked business:
          → HTTP HEAD request → check if resolves
      → Update People sheet:
          - Verified = verified / unverified / risky
          - Verification Date = now
```

**Bulk alternative:** For large batches, export unverified emails as CSV → upload to Lumrid (app.lumrid.com) → reimport results. This can be a manual step initially, automated later if needed.

---

## Services & Credentials

| Service | Purpose | n8n Node | Status | Action Needed |
|---------|---------|----------|--------|---------------|
| Google Places API | Business discovery | HTTP Request | Active (key in .env) | None |
| Google Sheets | Data storage | Built-in | OAuth2 configured in n8n | None |
| OpenAI | Data extraction | Built-in | Key in .env | None |
| Serper | Web search | HTTP Request | Credential exists | None |
| Hunter.io | Email find + verify | Built-in Hunter node | **Not set up** | **Sign up + add API key** |
| Gmail/Outlook | Error notifications | Built-in | Credential exists | None |
| Lumrid | Bulk email verification | Manual CSV upload | Free webapp | Optional, Phase 3 |

---

## Implementation Order

### Phase 1: Infrastructure
- [ ] Create Google Sheet with 3 sheets (Regions, Businesses, People)
- [ ] Seed Regions sheet with Croatia's 21 counties
- [ ] Sign up for Hunter.io, get API key
- [ ] Add Hunter credential to n8n
- [ ] Create project directory: `workflows/lead-finder/test/`
- [ ] Update .env if needed

### Phase 2: WF-00 + WF-01 (Business Discovery)
- [ ] WF-00: Error handler
- [ ] WF-01: Google Places API search per region
- [ ] Test with 1-2 counties (e.g., Dubrovnik-Neretva, Istria — high hotel density)
- [ ] Verify results in Businesses sheet
- [ ] Run full Croatia scan

### Phase 3: WF-02 (People Finder)
- [ ] WF-02b: Serper Search sub-workflow
- [ ] WF-02d: OpenAI Search sub-workflow
- [ ] WF-02: People Finder orchestrator (calls sub-workflows, combines, extracts)
- [ ] Test with 5-10 businesses
- [ ] Tune OpenAI extraction prompt based on result quality
- [ ] Run for all businesses (daily batches of 20)
- [ ] WF-02a: SerpApi Search sub-workflow (after signup)
- [ ] WF-02c: Hunter Search sub-workflow (after signup)

### Phase 4: WF-03 (Contact Verification)
- [ ] WF-03: Hunter email verification
- [ ] Test with sample contacts
- [ ] Run for all contacts
- [ ] Evaluate Lumrid for bulk verification

### Phase 5: Polish & Expand
- [ ] Schedule all workflows (daily/weekly cadence)
- [ ] Add monitoring/alerting
- [ ] Expand to next country
- [ ] Evaluate adding more search sources

---

## Design Principles

1. **Simple over clever** — Fewer moving parts = more robust
2. **Idempotent** — Every workflow can be re-run safely (upsert, status tracking)
3. **Resumable** — Status columns let workflows pick up where they left off
4. **Configurable** — Country, niche, search terms are data, not code
5. **Modular** — Each workflow does one job, runs independently
6. **Observable** — Error handler + execution history for debugging

---

## Cost Estimates

| Service | Pricing | Expected Usage | Est. Monthly Cost |
|---------|---------|----------------|-------------------|
| Google Places API | $17/1000 Text Search calls | ~500 calls for Croatia | ~$8.50 one-time |
| OpenAI (gpt-4.1-mini) | $0.40/1M input, $1.60/1M output | ~1000 businesses | ~$2-5 |
| Serper | 2500 free searches/mo | ~2000 searches | Free tier |
| Hunter.io | Free: 25 searches/mo; Starter $49/mo: 500 | Depends on scale | $0-49/mo |

**Total estimated for Croatia scan:** ~$15-60 depending on Hunter tier.

---

## Notes

- People Finder v0.2 serves as reference architecture (state tracking, batch processing, model fallback)
- OpenAI replaces Gemini; Serper + Hunter replace Gemini's built-in search
- Google Places API is purpose-built for Phase 1 — much more reliable than scraping search results
- Hunter.io is the key addition — provides email discovery AND verification in one service
- The niche (Hotels & Hospitality) is the starting point but the system is designed to work with any vertical by changing search terms
