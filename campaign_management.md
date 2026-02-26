# Campaign Management with n8n

## What is Campaign Management?

Campaign management is the process of planning, executing, tracking, and analyzing marketing campaigns across one or more communication channels (email, SMS, WhatsApp, social media, ads, etc.).

| Aspect | Description |
|---|---|
| **Audience Segmentation** | Splitting contacts into groups based on behavior, demographics, or engagement history |
| **Content Creation** | Crafting messages, templates, and creatives for each channel |
| **Scheduling & Delivery** | Sending the right message at the right time to the right segment |
| **Multi-channel Orchestration** | Coordinating across email, WhatsApp, SMS, push notifications, etc. |
| **Automation & Triggers** | Drip sequences, follow-ups, abandoned cart reminders — actions triggered by user behavior |
| **Analytics & Optimization** | Open rates, click rates, conversions, A/B testing results |
| **Compliance** | Opt-in/opt-out management, GDPR, CAN-SPAM |

---

## Architecture Overview

n8n acts as the campaign orchestration engine — it connects to contact sources, segments audiences, personalizes messages, dispatches across channels, and logs results.

```
┌─────────────────────────────────────────────────────────────┐
│  CAMPAIGN ENGINE (n8n)                                       │
│                                                              │
│  Trigger                                                     │
│  (Schedule / Webhook / Manual)                               │
│       │                                                      │
│       ▼                                                      │
│  Load Contacts ──→ Segment ──→ Personalize ──┐              │
│  (Google Sheets,    (Filter/    (Set node)    │              │
│   Airtable, CRM,    Switch)                   │              │
│   Postgres)                                   ▼              │
│                                         ┌──────────┐        │
│                                         │  Router   │        │
│                                         │ (Switch)  │        │
│                                         └────┬─────┘        │
│                                    ┌─────────┼──────────┐   │
│                                    ▼         ▼          ▼   │
│                                 Email    WhatsApp     SMS   │
│                                (SMTP/     (Twilio/   (Twilio│
│                                SendGrid)   Meta API)   etc) │
│                                    │         │          │   │
│                                    └─────────┼──────────┘   │
│                                              ▼              │
│                                     Log Results             │
│                                   (Google Sheets /          │
│                                    Airtable / DB)           │
└─────────────────────────────────────────────────────────────┘
```

---

## Email Campaign

### Workflow: Weekly Newsletter

**Nodes in order:**

1. **Schedule Trigger** — fires at a set time (e.g., every Monday 9am)
2. **Google Sheets / Airtable** — fetch contact list (name, email, segment, preferences)
3. **Filter** — select only contacts where `segment = "newsletter"` and `opted_in = true`
4. **Split In Batches** — process contacts in groups of 50 to avoid rate limits
5. **Set** — personalize fields (e.g., `Hi {{firstName}}, here's your weekly update...`)
6. **Send Email** (SMTP, SendGrid, or Mailgun) — send the personalized email
7. **IF** — check for send errors
8. **Google Sheets** — log delivery status (sent/failed, timestamp) back to the sheet

### Email Provider Options

| Provider | Free Tier | Notes |
|---|---|---|
| **SendGrid** | 100 emails/day | Most popular, good deliverability |
| **Mailgun** | 100 emails/day (trial) | Developer-friendly API |
| **SMTP (generic)** | Depends on provider | Works with any SMTP server |
| **Amazon SES** | 62,000 emails/month (from EC2) | Cheapest at scale |

### Personalization Approach

Use the **Set** node to build the email body from a template:

```
Subject: {{campaignSubject}}
Body:
  Hi {{firstName}},

  {{campaignBody}}

  {{#if promoCode}}
  Use code {{promoCode}} for {{discountPercent}}% off.
  {{/if}}

  Best,
  {{senderName}}
```

Variables come from the contact list (per-contact) and campaign config (shared across all).

---

## WhatsApp Campaign

### Prerequisites

WhatsApp Business API requires:

1. **Meta Business Account** — verified business on Meta
2. **WhatsApp Business Platform** access — apply via Meta or use Twilio as a BSP
3. **Pre-approved message templates** — Meta reviews all outbound templates before use
4. **User opt-in** — contacts must have explicitly opted in to receive WhatsApp messages

### Workflow: Promotional Campaign

**Nodes in order:**

1. **Webhook Trigger** or **Schedule Trigger** — start the campaign
2. **Airtable / Postgres** — fetch contacts with WhatsApp numbers and consent
3. **Filter** — only contacts who opted in to WhatsApp
4. **Split In Batches** — process in groups to respect rate limits
5. **HTTP Request** — call the WhatsApp Business API:

```json
POST https://graph.facebook.com/v21.0/{phone_number_id}/messages

{
  "messaging_product": "whatsapp",
  "to": "{{contact.phone}}",
  "type": "template",
  "template": {
    "name": "weekly_promo",
    "language": { "code": "en" },
    "components": [{
      "type": "body",
      "parameters": [
        { "type": "text", "text": "{{contact.firstName}}" },
        { "type": "text", "text": "{{promoCode}}" }
      ]
    }]
  }
}
```

6. **Wait** — add delay between batches to respect rate limits
7. **Google Sheets** — log delivery status

### WhatsApp Message Types

| Type | Requires Template? | Use Case |
|---|---|---|
| **Template messages** | Yes (Meta-approved) | Outbound campaigns, notifications, reminders |
| **Session messages** | No (free-form) | Replies within 24h of user's last message |

Campaigns always use template messages. Free-form replies are only for conversational responses.

### Rate Limits

| Tier | Messages per 24h | How to Reach |
|---|---|---|
| Tier 1 (new) | 1,000 | Default for new numbers |
| Tier 2 | 10,000 | Good quality rating + volume |
| Tier 3 | 100,000 | Sustained quality + volume |
| Tier 4 | Unlimited | High volume + excellent quality |

Quality rating is based on user feedback (blocks, reports). Poor quality = tier downgrade.

---

## Managing Multiple Campaign Types in n8n

### Option 1: Switch Node (1-2 campaign types)

One workflow handles all campaign types. A Switch node routes to different branches based on a `campaignType` field.

```
Trigger (with campaignType param)
    │
    ▼
Switch (campaignType)
    ├── "newsletter"   → Email branch
    ├── "promo"        → WhatsApp branch
    ├── "onboarding"   → Drip sequence branch
    └── "announcement" → Both channels branch
```

**Pros:** Everything in one place, easy to compare logic across types.
**Cons:** Gets messy with 5+ campaign types — the canvas becomes unreadable.

### Option 2: One Workflow Per Campaign Type (3-5 types)

Each campaign type is its own workflow. A dispatcher workflow calls the right one via the **Execute Workflow** node.

```
Dispatcher (webhook/manual trigger with campaignType)
    │
    ▼
Switch (campaignType)
    ├── Execute Workflow → "Campaign: Newsletter"
    ├── Execute Workflow → "Campaign: Promo Blast"
    └── Execute Workflow → "Campaign: Onboarding Drip"
```

**Pros:** Each workflow is self-contained, testable independently, clean canvas.
**Cons:** Shared logic (contact loading, logging) gets duplicated — solve with sub-workflows.

### Option 3: Shared Sub-Workflows (5+ types, best at scale)

Extract reusable pieces into sub-workflows that any campaign can call:

```
Campaign Workflow (any type)
    │
    ├── Execute Workflow → "Sub: Load & Segment Contacts"
    ├── Execute Workflow → "Sub: Personalize Message"
    ├── (campaign-specific logic here)
    ├── Execute Workflow → "Sub: Send Email" or "Sub: Send WhatsApp"
    └── Execute Workflow → "Sub: Log Results"
```

Change your contact-loading logic once, all campaigns pick it up. The **Execute Workflow** node is the key building block — it's how n8n does composability.

---

## Multi-Channel Campaign

The real power is combining channels in a single workflow with intelligent routing.

```
Trigger → Load Contacts → Switch (by preferred_channel)
                              │
                    ┌─────────┼──────────┐
                    ▼         ▼          ▼
                  Email    WhatsApp    Both
                    │         │          │
                    │         │     Send Email
                    │         │     Wait 2 hours
                    │         │     Send WhatsApp
                    ▼         ▼          ▼
                    └─────────┼──────────┘
                              ▼
                     Log all results
                     to Airtable/DB
```

### Drip Sequence Example

A multi-step campaign triggered by a user action (e.g., sign-up):

```
New Sign-up (Webhook)
    │
    ▼
Day 0: Welcome Email
    │
    Wait 2 days
    │
    ▼
Day 2: Tips Email
    │
    Wait 3 days
    │
    ▼
Day 5: Check engagement (IF opened previous emails?)
    │                          │
    Yes                        No
    │                          │
    ▼                          ▼
WhatsApp: Promo offer    Email: Re-engagement
    │                          │
    └──────────┬───────────────┘
               ▼
         Log final status
```

---

## Best Practices

| Practice | Why |
|---|---|
| **Split In Batches node** | Process contacts in groups of 50-100 to avoid rate limits and memory issues |
| **Wait node between batches** | Respect API rate limits (WhatsApp, SendGrid, etc.) |
| **Error handling branch** | Catch failed sends — retry or flag for manual review |
| **Opt-out webhook** | Separate workflow to handle unsubscribes immediately |
| **Template variables via Set node** | Centralize personalization logic in one place |
| **Separate test workflow** | Clone the campaign, point at a test contact list before going live |
| **Log everything** | Write send results back to your data source for analytics |
| **Idempotency** | Track which contacts already received a campaign to prevent duplicates on re-runs |

---

## Required Services & Costs

| Component | Purpose | Cost |
|---|---|---|
| **n8n** (self-hosted) | Workflow engine | Free |
| **SendGrid** | Email delivery | Free: 100/day |
| **Mailgun** | Email delivery (alternative) | Free: 100/day trial |
| **WhatsApp Business API** (Meta) | WhatsApp messaging | First 1,000 conversations/month free |
| **Twilio** (WhatsApp BSP) | WhatsApp + SMS | ~$0.005-0.05 per message |
| **Google Sheets / Airtable** | Contact list + logging | Free tier sufficient |
| **Postgres** (optional) | Contact storage at scale | Free with self-hosted n8n |

---

## Compliance Checklist

- [ ] Contacts have explicitly opted in (double opt-in for email, explicit consent for WhatsApp)
- [ ] Every message includes an unsubscribe/opt-out mechanism
- [ ] Opt-out requests are processed immediately (separate n8n workflow)
- [ ] WhatsApp message templates are approved by Meta before use
- [ ] Sender identity is clear (from name, business name)
- [ ] Contact data is stored securely (encrypted at rest, access controlled)
- [ ] Campaign logs are retained for audit purposes

---

## Sample Campaign: Real Estate Cold Lead Nurturing

### The Goal

Turn a database of cold property owners into warm leads — either **sellers** (list their property with us) or **buyers** (invest in new property). The strategy is a 3-phase escalation: start cheap and wide (email), get personal with engaged leads (WhatsApp), and deploy high-touch qualification only on hot leads (Voice AI).

### Target Audience

Property owners sourced from public records, expired listings, past inquiries, or purchased databases.

| Segment | Profile | Why They're Valuable |
|---|---|---|
| **Expired listings** | Tried to sell recently, listing expired | Highest intent — they already wanted to sell, just need a better approach |
| **Absentee owners** | Own property but live elsewhere | Often willing to liquidate, less emotionally attached |
| **Long-term owners (10+ years)** | Sitting on significant equity | Life changes (retirement, downsizing, relocation) may trigger a sale |
| **Inherited properties** | Received property through estate | Often want to sell quickly, unfamiliar with the process |
| **Multi-property owners** | Investors with 2+ properties | May be rebalancing portfolio, open to both selling and buying |
| **Past inquiries** | Visited website, attended open house, never followed through | Already showed interest once — re-engagement is easier |

### Personalization Data Points

| Data Point | Source | Used In |
|---|---|---|
| First name | Contact list / CRM | All channels |
| Property address | Property records | Email subject, WhatsApp, Voice script |
| Neighborhood | Geocoding / property records | Market reports, comparable sales |
| Property type (apartment, house, land) | Property records | Content selection |
| Estimated current value | Market data / Zillow API / manual | Valuation emails, WhatsApp teasers |
| Recent comparable sales nearby | MLS / market data | Email content (social proof) |
| Ownership duration (years) | Property records | Segment assignment |
| Previous engagement (opens, clicks) | n8n tracking / CRM | Channel escalation triggers |

### Lead Scoring Model

Every interaction earns points. The score determines which channel engages next.

| Action | Points |
|---|---|
| Email opened | +1 |
| Email link clicked | +3 |
| "Get My Valuation" CTA clicked | +5 |
| WhatsApp message read | +2 |
| WhatsApp reply (any) | +10 |
| Website visit (property-related page) | +3 |
| Multiple touchpoints within 7 days | +5 (bonus) |

| Score | Temperature | Next Action |
|---|---|---|
| 0–3 | Cold | Continue email drip |
| 4–9 | Warming | Escalate to WhatsApp |
| 10–15 | Warm | WhatsApp follow-up, prepare for Voice |
| 16+ | Hot | Voice AI qualification call |

### Channel Strategy: When to Use What

#### Email — The Workhorse

**When:** First touch for ALL cold leads. Cheapest channel, highest scale.

**Purpose:**
- Deliver value upfront (market reports, neighborhood data, comparable sales)
- Educate ("5 things to know before selling in [neighborhood]")
- Tease a free property valuation (primary CTA)
- Track engagement to identify who's warming up

**Why email first:** Cold leads haven't given you permission for anything personal. Email is low-friction, non-intrusive, and lets you measure interest silently through opens/clicks before investing in higher-cost channels.

#### WhatsApp — The Accelerator

**When:** Lead has engaged with email (opened 2+ emails, clicked a link, or clicked the valuation CTA). Score 4+.

**Purpose:**
- Create personal connection and urgency
- Time-sensitive market updates ("A property on your street just sold for €X")
- Quick conversational follow-up ("Noticed you checked the market report — any questions?")
- Offer direct access ("Reply YES for a free valuation")

**Why WhatsApp second:** 98% open rate vs. 20% for email. But it's personal space — you only enter it once someone has shown interest. Sending WhatsApp to a fully cold lead feels spammy and burns your quality rating (which controls your rate limits).

#### Voice AI Agent — The Closer

**When:** Lead shows high intent. Score 16+. Specific triggers:
- Clicked "Get My Property Valuation" link
- Replied to a WhatsApp message
- Opened 4+ touchpoints across channels
- Visited property listing pages multiple times

**Purpose:**
- Qualify the lead with conversational questions (timeline, motivation, price expectations)
- Handle basic objections ("I'm not sure it's the right time...")
- Book an appointment with a human agent if qualified
- Tag unqualified leads as "nurture" and loop them back into the email drip

**Why Voice AI last:** Most expensive per-contact, but highest conversion rate. You only deploy it on leads who have already demonstrated interest through cheaper channels. A voice call from a stranger to a cold lead is an interruption; a voice call to someone who clicked your valuation link 3 times is a service.

### The 3-Phase Campaign Flow

#### Phase 1: Cold Outreach — Email Only (Week 1–2)

Goal: Introduce value, surface who's alive in the list.

```
Day 0 ─── Email 1: "[Neighborhood] Market Report — February 2026"
           │
           ├── Personalized with their actual neighborhood
           ├── Recent comparable sales near their address
           ├── CTA: "See what your property could be worth →"
           └── Track: opens, clicks
           │
Day 4 ─── Email 2: "Properties like yours in [neighborhood] are selling for..."
           │
           ├── ONLY sent to those who opened Email 1
           ├── Include 2-3 comparable sales with prices
           ├── CTA: "Get your free property valuation"
           └── More specific, higher-intent content
           │
Day 8 ─── Email 3: Different approach for non-openers
           │
           ├── Sent to those who did NOT open Email 1 or 2
           ├── Shorter, curiosity-driven subject line
           ├── "Quick question about your property at [street]"
           └── Last email attempt for this cohort — don't spam
```

**Sample Email 1:**

```
Subject: Your [Neighborhood] Market Report — February 2026

Hi [firstName],

The [neighborhood] property market moved significantly last month.
Here's what happened near [street]:

• [address_1] sold for €[price_1] ([days_1] days on market)
• [address_2] sold for €[price_2] ([days_2] days on market)
• [address_3] sold for €[price_3] ([days_3] days on market)

Average price per m² in [neighborhood]: €[avg_price_sqm]
Change vs. last year: [yoy_change]%

Curious what your property could be worth in today's market?

→ Get your free, no-obligation valuation
  [LINK to valuation landing page]

Best regards,
[agentName]
[company]
```

#### Phase 2: Warm Engagement — WhatsApp (Week 2–3)

Goal: Personal follow-up with leads who showed interest.

**Trigger:** Lead score reached 4+ (opened 2+ emails OR clicked any CTA).

```
Day 10 ── WhatsApp Message 1 (Template: market_interest_followup)
           │
           "Hi [firstName], I noticed you checked out the [neighborhood]
            market report. Properties like yours at [street] are getting
            a lot of interest right now. Would you like a quick,
            no-obligation valuation? Just reply YES."
           │
           ├── Reply YES → Score +10, move to Phase 3 queue
           ├── Reply with question → Human agent responds within 24h
           │                          (session message, no template needed)
           └── No reply → continue to Message 2
           │
Day 14 ── WhatsApp Message 2 (Template: market_update_reminder)
           │
           "Hi [firstName], quick update — [count] properties sold in
            [neighborhood] last month, average price €[avg_price].
            The market is moving. Let me know if you'd like to chat
            about your options."
           │
           ├── Any reply → escalate to human or Voice AI
           └── No reply → tag as "WhatsApp-unresponsive",
                           loop back to email nurture (lower frequency)
```

**Note:** Both WhatsApp messages must be pre-approved **Meta message templates**. You cannot send free-form messages to someone who hasn't messaged you first within 24 hours.

#### Phase 3: Qualification — Voice AI Agent (Week 3+)

Goal: Qualify hot leads and book appointments with human agents.

**Trigger:** Score 16+ (replied to WhatsApp, clicked valuation CTA, or multi-channel engagement).

```
Voice AI calls the lead
    │
    ▼
Introduction:
    "Hi [firstName], this is [agentName] from [company].
     You recently showed interest in property values in
     [neighborhood]. I have some insights about your area —
     do you have a couple of minutes?"
    │
    ├── If yes → Qualification questions
    │     │
    │     ├── "Are you considering selling in the next 6-12 months?"
    │     ├── "Have you had the property valued recently?"
    │     ├── "Is there a specific price you'd need to get?"
    │     └── "Would you be open to a free, no-obligation
    │          market analysis from one of our agents?"
    │     │
    │     ├── Qualified (timeline + motivation) → Book appointment
    │     │     with human agent (calendar integration via n8n)
    │     │
    │     └── Not ready yet → "No problem at all. I'll keep you
    │           updated on [neighborhood] market trends.
    │           Have a great day!"
    │           Tag as "nurture", reduce score, loop to email drip
    │
    └── If no / bad time → "Sorry to bother you. When would
          be a better time to call?"
          Schedule callback (n8n Wait node + re-trigger)
```

### Full Campaign Flow Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│  REAL ESTATE COLD LEAD NURTURING CAMPAIGN                        │
│                                                                   │
│  ┌─────────────┐                                                 │
│  │ Contact DB   │ (Google Sheets / Airtable / Postgres)          │
│  │ + Lead Score │                                                 │
│  └──────┬──────┘                                                 │
│         │                                                         │
│         ▼                                                         │
│  ┌─────────────┐     ┌──────────────────────────────────┐        │
│  │ PHASE 1     │     │  Engagement Tracker (n8n)         │        │
│  │ Email Drip  │────→│  - Webhook receives open/click    │        │
│  │ (3 emails   │     │  - Updates lead score in DB       │        │
│  │  over 8 days)│     │  - Checks score thresholds       │        │
│  └──────┬──────┘     └──────────┬───────────────────────┘        │
│         │                       │                                 │
│         │            Score ≥ 4? │                                 │
│         │              YES ─────┘                                 │
│         │               │                                         │
│         ▼               ▼                                         │
│  Score < 4:      ┌─────────────┐                                 │
│  Keep in email   │ PHASE 2     │                                 │
│  nurture (lower  │ WhatsApp    │                                 │
│  frequency,      │ (2 messages │                                 │
│  monthly)        │  over 4 days)│                                 │
│                  └──────┬──────┘                                  │
│                         │                                         │
│              Score ≥ 16 or replied?                               │
│                YES ─────┘                                         │
│                 │                                                  │
│                 ▼                                                  │
│          ┌─────────────┐                                         │
│          │ PHASE 3     │                                         │
│          │ Voice AI    │                                         │
│          │ Agent Call  │                                         │
│          └──────┬──────┘                                         │
│                 │                                                  │
│          ┌──────┴──────┐                                         │
│          ▼             ▼                                          │
│     Qualified     Not Ready                                      │
│          │             │                                          │
│          ▼             ▼                                          │
│   Book Appointment   Loop back to                                │
│   with Human Agent   email nurture                               │
│   (Google Calendar)  (reduce score)                              │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

### Why This Sequence Works

| Principle | How It's Applied |
|---|---|
| **Cheapest channel first** | Email costs ~$0.001/send. WhatsApp ~$0.05. Voice ~$0.12/min. Only invest in expensive channels for proven interest. |
| **Value before ask** | Phase 1 gives free market data. No "sell your house" pitch until Phase 2. |
| **Behavioral triggers, not time-only** | Channel escalation is based on what the lead *did*, not just how many days passed. |
| **Respect personal space** | WhatsApp only after email engagement. Voice only after WhatsApp engagement or high-intent action. |
| **Always have a next step** | No lead falls into a black hole — unresponsive leads loop back to lower-frequency nurture. |
| **Qualify before human time** | The Voice AI agent filters out tire-kickers before booking a human agent's calendar. |

### n8n Implementation Notes

This campaign requires **4 workflows** (Option 2 pattern — one per campaign phase + dispatcher):

| Workflow | Trigger | Purpose |
|---|---|---|
| **Campaign: Dispatcher** | Manual or Schedule (weekly) | Loads contacts, checks scores, routes to the right phase |
| **Campaign: Email Drip** | Execute Workflow (from dispatcher) | Sends the 3-email sequence with wait nodes |
| **Campaign: WhatsApp Follow-up** | Execute Workflow (from dispatcher) | Sends WhatsApp templates to score 4+ leads |
| **Campaign: Voice AI Qualification** | Execute Workflow (from dispatcher) | Triggers Vapi call for score 16+ leads, handles callback |

Plus **2 supporting workflows**:

| Workflow | Trigger | Purpose |
|---|---|---|
| **Sub: Engagement Tracker** | Webhook (email open/click tracking pixel, WhatsApp delivery receipts) | Updates lead scores in the contact DB |
| **Sub: Opt-out Handler** | Webhook (unsubscribe link, WhatsApp "STOP" reply) | Immediately removes contact from all active campaigns |

---

## Useful Links

- [n8n Send Email Node Docs](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.sendemail/)
- [n8n HTTP Request Node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest/)
- [n8n Split In Batches Node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.splitinbatches/)
- [Meta WhatsApp Business Platform](https://developers.facebook.com/docs/whatsapp/cloud-api/)
- [WhatsApp Message Templates](https://developers.facebook.com/docs/whatsapp/message-templates/)
- [SendGrid n8n Integration](https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.sendgrid/)
- [Twilio WhatsApp API](https://www.twilio.com/docs/whatsapp/api)
- [n8n WhatsApp Bot Guide](https://blog.n8n.io/whatsapp-bot/)
