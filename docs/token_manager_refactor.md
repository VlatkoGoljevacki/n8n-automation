# Shared ERP Token Manager Sub-Workflow (Deferred)

**Status**: Planned — implement after full flow is tested and approved.

## Context

ERP token management is currently duplicated: the orchestrator has 5 nodes for token fetch/cache, and WF-06 has 4 nodes for the same thing. Each workflow's `$getWorkflowStaticData('global')` is scoped per-workflow, so WF-06 can't access the orchestrator's cached token.

**Current workaround**: Orchestrator passes its cached token through the data chain to WF-06 via "Prepare Submission Input" node. WF-06 checks the incoming token first, falls back to fetching its own if missing.

## Plan

Create `workflows/medika_preorder_00b_token_manager.json`:
- Input: `{ erpApiUrl, erpUsername, erpPassword }` (flat or under `config.*`)
- Output: `{ accessToken, expiresAt, cacheHit }`
- Caches token in its own static data with 5-min expiry buffer

### Orchestrator changes
- Remove 5 token nodes (Check ERP Token, Token Valid?, Prepare Auth, Fetch ERP Token, Store ERP Token)
- Replace with 1 Execute Workflow call to token manager
- Add second call before WF-06 (after approval, token may have expired)
- Rename `erpToken` → `accessToken` in Check/Store Customer Cache and Fetch Customers API

### WF-06 changes
- Remove 4 token nodes (Check Token Cache, Token Valid?, Fetch ERP Token, Store Token)
- Simplify to: Build API Payload → Submit Order (token always from caller)

See full implementation plan in `.claude/plans/breezy-meandering-crane.md`.
