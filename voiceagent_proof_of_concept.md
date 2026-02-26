# Voice AI Agent - Proof of Concept

## Architecture

- **Vapi** — owns the real-time conversation loop (telephony, STT, LLM, TTS, turn-taking, interruptions)
- **n8n** — acts as the tool server via webhooks (CRM lookups, database queries, booking logic, etc.)

### What lives where

| Vapi | n8n |
|---|---|
| Phone number / web widget | CRM lookups |
| Voice (STT/TTS) | Database queries |
| LLM + system prompt | Calendar/booking logic |
| Conversation state | Email/SMS sending |
| Call recording | Custom business logic |

Vapi also has its own knowledge base feature (upload docs/URLs). For dynamic lookups based on caller input, n8n handles that as the tool server.

## Setup Steps

1. Sign up at [vapi.ai](https://vapi.ai) — free credits included
2. Create an Assistant — pick LLM, voice (TTS provider), set system prompt
3. **Test via Vapi Web SDK** — embed widget in browser, call agent directly. No phone number needed, zero cost, works immediately
4. Set the Assistant's "Server URL" to an n8n webhook URL
5. In n8n, create a workflow:
   - **Webhook node** — receives Vapi tool call requests
   - **AI Agent / Code nodes** — business logic
   - **Respond to Webhook** — sends result back to Vapi
6. Add a phone number when ready for production

## Phone Number Options

| Option | Setup Time | Notes |
|---|---|---|
| **Vapi web widget** | Instant | Browser-based, best for testing |
| **US number from Vapi** | Instant | Call from Croatia with international rates |
| **Croatian (+385) number via Twilio** | Days | Requires regulatory compliance (address proof). Import into Vapi after purchase |

### Recommendation

Start with the **web widget** for testing, swap to a real phone number later.

## Agent Configuration

Vapi agents are not trained in the ML sense — no fine-tuning. They are configured through three layers:

### 1. System Prompt
The main way to shape agent behavior. Write instructions like for any LLM — personality, rules, conversation flow, what to say/not say. Vapi has a [voice-specific prompting guide](https://docs.vapi.ai/prompting-guide).

### 2. Knowledge Base (RAG)
Upload files (PDFs, text, docs) that the agent can search during a conversation. Uses retrieval-augmented generation.

- Upload via Vapi dashboard or API
- Keep files under 300KB each
- Organize by topic with clear headings
- Must explicitly tell the agent in the system prompt when to use the knowledge base — it won't search automatically

### 3. Tools (n8n webhooks)
Define functions the agent can call — booking, customer lookups, availability checks. These are n8n webhook endpoints. The agent decides when to call them based on the conversation.

## Voice Quality & Latency

Target latency: **750–900ms** end-to-end (natural human pauses are 200–500ms).

### Common fixes for artificial/slow voice

**Choose the right TTS provider:**

| Provider | Latency | Voices | Notes |
|---|---|---|---|
| **ElevenLabs Flash v2.5** | ~75ms | 3,000+ | Most natural, fastest |
| **ElevenLabs Standard** | ~150ms | 3,000+ | Still very good |
| **OpenAI TTS** | ~200ms | 11 | Cheaper, fewer voices |
| **Play.ht / Azure** | Varies | Many | Alternative options |

**Optimize turn detection:**
- Vapi's default turn detection adds 1.5+ seconds of wait time — this kills perceived responsiveness
- Tune `startSpeakingPlan` settings to reduce unnecessary pauses
- Disable formatting and other "nice-to-have" processing that adds latency

**Keep LLM responses short:**
- Instruct the agent in the system prompt to give brief, conversational answers (1-2 sentences)
- Long responses = long TTS processing = slow delivery

**Use a fast LLM:**
- GPT-4o-mini or Gemini Flash for speed
- GPT-4o or Claude for quality (slightly slower)

### Latency breakdown

Each step in the pipeline adds latency:
```
Caller speaks → STT (~200ms) → LLM (~300-500ms) → TTS (~75-200ms) → Caller hears response
                                                              Total: ~575-900ms
```

Optimize each component individually. The biggest wins are usually TTS provider choice and turn detection settings.

---

## Future: Two Tiers of Ownership

### Tier 1 — Own the agents, 3rd party handles telephony

You build and control the agents (LLM, prompts, STT/TTS, tools). A platform like Vapi handles the call infrastructure.

```
Phone/Web ──→ Vapi (telephony + audio) ──→ Your Agent (via Server URL)
                                               │
                                               ├── STT/LLM/TTS (your choice)
                                               └── Tools → n8n (business logic)
```

**You provide:**
- Agent code (LiveKit Agents framework or custom Python/Node)
- LLM choice + system prompt + knowledge base
- STT/TTS provider selection
- n8n workflows for tool calls

**3rd party provides:**
- Phone numbers
- SIP / PSTN connectivity
- WebRTC infrastructure
- Call recording, analytics

**Candidates:** Vapi (custom LLM endpoint), Retell.ai, Bland.ai

### Tier 2 — Own everything, only SIP trunk from provider

You run the full stack. The only external dependency is a SIP trunk for PSTN connectivity.

```
┌─────────────────────────────────────────────────────┐
│  YOUR INFRASTRUCTURE                                 │
│                                                      │
│  Phone ──→ Twilio SIP Trunk ──┐                     │
│  Web    ──→ LiveKit Web SDK ──┼──→ LiveKit Server   │
│  Mobile ──→ LiveKit SDK ──────┘      (rooms)        │
│                                        │             │
│                               LiveKit Agent          │
│                                 ├── STT              │
│                                 ├── LLM              │
│                                 ├── TTS              │
│                                 └── Tools → n8n      │
│                                                      │
│  WhatsApp ──→ Twilio/Meta API ──→ n8n (separate)    │
└─────────────────────────────────────────────────────┘
 ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  EXTERNAL: Twilio (SIP trunk + phone numbers only)
```

**You provide:**
- LiveKit Server (self-hosted or LiveKit Cloud)
- LiveKit Agent (Python/Node) — full voice pipeline
- STT / LLM / TTS providers (your accounts, your keys)
- n8n — tool server + WhatsApp chatbot
- Web frontend (LiveKit SDK — React, Flutter, etc.)

**SIP trunk provider provides:**
- Phone numbers
- PSTN ↔ SIP bridge (that's it)

**Candidates for SIP trunk:** Twilio, Telnyx, Plivo

#### Infrastructure requirements (Tier 2, self-hosted LiveKit)

| Component | Specs | Notes |
|---|---|---|
| LiveKit Server | 4 cores, 8GB RAM | Per node; needs host networking |
| Agent Server | 4 cores, 8GB RAM | Per agent worker pool |
| Redis | Small instance | Required for multi-replica / egress/ingress |
| SSL certificates | Required | For domain + TURN/TLS |
| Storage | ~10GB ephemeral | Agent Docker images |

LiveKit is open-source — self-hosting is free. Alternatively, use [LiveKit Cloud](https://livekit.io/pricing) to skip infra management.

#### WhatsApp (both tiers)

Text messaging only — separate flow from voice, handled entirely by n8n.

```
WhatsApp message ──→ Twilio/Meta API ──→ n8n webhook ──→ AI Agent node ──→ reply via WhatsApp node
```

### Cost per minute comparison

#### Vapi (PoC / Tier 1)

```
$0.05       Vapi orchestration
$0.01       STT (e.g. Deepgram)
$0.01–0.03  LLM (e.g. GPT-4o-mini)
$0.04–0.05  TTS (e.g. ElevenLabs)
$0.01       Twilio telephony
─────────────────────────────────
~$0.12–0.15/min
```

#### LiveKit Cloud (Tier 2)

```
$0.01       LiveKit Cloud orchestration
$0.005–0.008  Deepgram STT
$0.01–0.02  GPT-4o-mini LLM (token-based, varies)
~$0.05      ElevenLabs TTS
$0.005–0.01 Twilio SIP trunk
─────────────────────────────────
~$0.08–0.11/min
```

#### LiveKit Self-Hosted (Tier 2, max savings)

```
$0.00       LiveKit (self-hosted, free)
$0.005–0.008  Deepgram STT
$0.01–0.02  GPT-4o-mini LLM
~$0.05      ElevenLabs TTS
$0.005–0.01 Twilio SIP trunk
─────────────────────────────────
~$0.07–0.09/min  (+ server costs)
```

#### Savings at scale

| Monthly minutes | Vapi cost | LiveKit self-hosted | Savings |
|---|---|---|---|
| 1,000 | ~$140 | ~$80 | $60 |
| 10,000 | ~$1,400 | ~$800 | $600 |
| 50,000 | ~$7,000 | ~$4,000 | $3,000 |

Main saving is eliminating the $0.05 Vapi orchestration fee. AI provider costs (STT/LLM/TTS) are roughly the same either way — same APIs, same keys.

### Feature comparison

| | Tier 1 (own agents) | Tier 2 (own everything) |
|---|---|---|
| Setup time | Days | Weeks |
| Voice pipeline | Your code, their infra | Your code, your infra |
| Telephony | Managed | SIP trunk only |
| Cost per minute | ~$0.12–0.15 | ~$0.07–0.11 |
| Web/mobile calls | Via provider's widget | LiveKit SDK (full control) |
| WhatsApp | Via n8n + Twilio | Via n8n + Twilio |
| Code required | Agent code | Agent code + infra/DevOps |
| Vendor lock-in | Moderate | Minimal (SIP is standard) |

### Migration path

1. **Now** — Vapi PoC, Vapi handles everything (validate the use case)
2. **Tier 1** — Bring your own agents to Vapi/similar (own the AI, outsource telephony)
3. **Tier 2** — LiveKit self-hosted, Twilio SIP trunk only (own everything)

n8n stays the tool/business logic server across all tiers.

---

## Business Model: Agency / Integration Service

### Approach

Client owns their own Vapi account (and pays Vapi directly for usage). You charge for the expertise, setup, and ongoing maintenance.

```
Client pays Vapi ──→ Vapi (voice minutes, phone numbers)
Client pays you  ──→ Agent setup, n8n server, CRM integration, maintenance
```

### What you charge for

| Service | Pricing model | Description |
|---|---|---|
| **Initial setup** | One-time fee | Build the agent (prompt, knowledge base, voice selection), configure Vapi, set up n8n workflows, CRM integration |
| **n8n server** | Monthly | Host and maintain the n8n instance with their business logic workflows |
| **Agent maintenance** | Monthly retainer | Prompt tuning, knowledge base updates, adding new tools/workflows, monitoring call quality |
| **CRM embedding** | One-time or monthly | Embed Vapi web widget into their CRM/website, custom integrations |
| **New features** | Per project | Additional workflows, new channels (WhatsApp), new tools |

### What the client pays directly

Vapi's $0.05/min only covers orchestration (stitching the call together). Each AI provider bills separately on top. Typical per-minute cost breakdown:

```
$0.05  Vapi orchestration
$0.01  STT provider (e.g. Deepgram, AssemblyAI, Google STT)
$0.03  LLM provider (e.g. GPT-4o-mini, Claude, Gemini)
$0.04  TTS provider (e.g. ElevenLabs, OpenAI TTS, Play.ht)
$0.01  Telephony provider (e.g. Twilio — carries the actual phone call)
─────
~$0.14/min total (varies by provider choice)
```

Client sets up their own API keys for each provider in their Vapi dashboard, or uses Vapi's defaults (slightly marked up).

Summary of client costs:
- **Vapi** — orchestration (~$0.05/min)
- **AI providers** — STT + LLM + TTS (own API keys)
- **Twilio** — telephony + phone numbers (if needed)
- **n8n hosting** — or bundled into your monthly fee

### Why this works

- **No margin stacking** — client sees transparent Vapi costs, trusts the relationship
- **Recurring revenue** — n8n hosting + maintenance retainer
- **Scalable** — same n8n patterns/templates across clients, customize per client
- **Low risk** — no need to front Vapi costs or manage billing pass-through
- **Sticky** — you maintain the agents + n8n server, switching cost is high

### Typical client verticals

- Real estate (lead qualification, showing scheduler)
- Medical/dental (appointment booking, after-hours)
- Hotels/hospitality (reservations, concierge)
- Service businesses (plumbing, HVAC — dispatch + booking)
- Law firms (intake, scheduling)

## Useful Links

- [Vapi Docs - Phone Calling](https://docs.vapi.ai/phone-calling)
- [Vapi Free Telephony](https://docs.vapi.ai/free-telephony)
- [How To Connect Vapi To n8n in 9 Minutes](https://vapi.ai/library/how-to-connect-vapi-to-n8n-ai-agents-in-9-minutes)
- [n8n Vapi Template - Call Scheduling](https://n8n.io/workflows/3427-automate-call-scheduling-with-voice-ai-receptionist-using-vapi-google-calendar-and-airtable/)
- [Non-US Twilio Number for Vapi](https://vapi.ai/library/how-to-get-a-non-us-twilio-number-for-vapi-ai-avoid-us-restrictions-full-setup-2025)
- [Twilio Croatia Pricing](https://www.twilio.com/en-us/voice/pricing/hr)
- [Twilio Croatia Regulatory Guidelines](https://www.twilio.com/en-us/guidelines/hr/regulatory)
- [Vapi Voice AI Prompting Guide](https://docs.vapi.ai/prompting-guide)
- [Vapi Knowledge Base Docs](https://docs.vapi.ai/knowledge-base)
- [How to Build Lowest Latency Voice Agent in Vapi](https://www.assemblyai.com/blog/how-to-build-lowest-latency-voice-agent-vapi)
- [Vapi Speech Latency Solutions](https://vapi.ai/blog/speech-latency)
- [ElevenLabs vs OpenAI TTS](https://vapi.ai/blog/elevenlabs-vs-openai)
- [LiveKit Agents Framework](https://docs.livekit.io/agents/)
- [LiveKit Telephony / SIP](https://docs.livekit.io/sip/)
- [LiveKit + Twilio Inbound Calls](https://docs.livekit.io/telephony/accepting-calls/inbound-twilio/)
- [LiveKit Agent Frontends](https://docs.livekit.io/frontends/)
- [LiveKit Self-Hosted Deployments](https://docs.livekit.io/deploy/custom/deployments/)
- [LiveKit Pricing](https://livekit.io/pricing)
- [n8n WhatsApp Bot Guide](https://blog.n8n.io/whatsapp-bot/)
- [WhatsApp Voice Assistant with Twilio + Vapi + n8n](https://n8n.io/workflows/8284-create-a-whatsapp-voice-assistant-with-twilio-vapi-google-calendar-and-openai/)
