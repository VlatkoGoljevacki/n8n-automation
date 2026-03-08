# Microsoft Graph: Client Credentials Migration

## Why

- Current setup uses **delegated** (Authorization Code) OAuth2 — acts as a user
- Delegated accounts can hit per-user rate limits, not ideal for automation
- Client credentials (app-only) auth has higher rate limits and no browser login requirement

## Mailbox setup

With client credentials, **one app registration accesses any mailbox in the tenant** — you specify which mailbox in the API URL path. No separate credentials needed per mailbox.

| Purpose | Mailbox | Example | Notes |
|---|---|---|---|
| Reading orders | Existing inbox | `orders@company.hr` | Already exists |
| Sending notifications | Shared Mailbox | `automation@company.hr` | Free, no M365 license needed |

**Shared Mailbox** is the recommended option for sending:
- Free — no Microsoft 365 license required
- Created by admin in Exchange Admin Center (2 minutes)
- Has its own inbox (receives replies/bounces)
- Works with Graph API via client credentials

### Security: restrict app to specific mailboxes

By default, app-only permissions give access to **every mailbox in the org**. The admin should create an **Application Access Policy** to scope the app to only the mailboxes it needs:

```powershell
# In Exchange Online PowerShell

# 1. Create a mail-enabled security group containing only the allowed mailboxes
# (done in Exchange Admin Center or via PowerShell)

# 2. Restrict the app to that group
New-ApplicationAccessPolicy -AppId "{client-id}" `
  -PolicyScopeGroupId "n8n-automation-mailboxes@company.hr" `
  -AccessRight RestrictAccess `
  -Description "Restrict n8n to automation mailboxes only"
```

The security group `n8n-automation-mailboxes@company.hr` should contain both the reading and sending mailboxes.

## What to request from the client

Azure AD / Entra ID admin needs to:

1. **App Registration** with **Application permissions** (not Delegated):
   - `Mail.Read` — read mailbox
   - `Mail.Send` — send emails
   - `Mail.ReadWrite` — move messages between folders
2. **Grant admin consent** for the above permissions
3. **Create a Shared Mailbox** for sending (e.g. `automation@company.hr`)
4. **Create an Application Access Policy** restricting the app to only the reading + sending mailboxes
5. Provide:
   - **Client ID** (Application ID)
   - **Client Secret** (or certificate)
   - **Tenant ID**
   - **Reading mailbox address** (e.g. `orders@company.hr`)
   - **Sending mailbox address** (e.g. `automation@company.hr`)

## n8n implementation

The built-in Outlook node only supports delegated OAuth2. With client credentials we use **HTTP Request nodes** calling the Graph API directly.

### Credential setup

Use n8n's **Generic OAuth2 API** credential:

| Field | Value |
|---|---|
| Grant Type | Client Credentials |
| Access Token URL | `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token` |
| Client ID | from app registration |
| Client Secret | from app registration |
| Scope | `https://graph.microsoft.com/.default` |
| Authentication | Body |

### API endpoints

Two mailboxes, same credential. `{reader}` = orders inbox, `{sender}` = automation/sending mailbox.

```
# --- Reading (uses {reader} mailbox, e.g. orders@company.hr) ---

# List unread messages in a folder
GET https://graph.microsoft.com/v1.0/users/{reader}/mailFolders/{folderId}/messages?$filter=isRead eq false&$top=10

# Move a message to another folder
POST https://graph.microsoft.com/v1.0/users/{reader}/messages/{messageId}/move
Body: { "destinationId": "{folderId}" }

# Get message attachments
GET https://graph.microsoft.com/v1.0/users/{reader}/messages/{messageId}/attachments

# Download attachment content
GET https://graph.microsoft.com/v1.0/users/{reader}/messages/{messageId}/attachments/{attachmentId}/$value

# --- Sending (uses {sender} mailbox, e.g. automation@company.hr) ---

# Send an email
POST https://graph.microsoft.com/v1.0/users/{sender}/sendMail
Body: {
  "message": {
    "subject": "...",
    "body": { "contentType": "HTML", "content": "..." },
    "toRecipients": [{ "emailAddress": { "address": "recipient@example.com" } }]
  }
}
```

### Workflows to update

| Workflow | Current Outlook usage | Migration |
|---|---|---|
| WF-01 Orchestrator | Fetch Email Batch (Outlook node), Move to Processing (already HTTP) | Replace Outlook node with HTTP Request |
| WF-01b Process Email | Fetch Email (Outlook node for attachments) | Replace with HTTP Request + attachment download |
| WF-05 Send Order Notification | Send Order Notification Email (Outlook node) | Replace with HTTP Request to `/sendMail` |
| WF-01b Process Email | Send Warning Email (Outlook node) | Replace with HTTP Request to `/sendMail` |

### Rate limits (app-only vs delegated)

- **Delegated:** 10,000 requests per 10 minutes per user per app
- **App-only:** 10,000 requests per 10 minutes per app (across all mailboxes)
- App-only limits are per-app, not per-user, so less risk of hitting limits from other activity on the same account

## References

- [Microsoft Graph rate limits](https://learn.microsoft.com/en-us/graph/throttling)
- [Client credentials flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)
- [n8n Microsoft credentials docs](https://docs.n8n.io/integrations/builtin/credentials/microsoft/)
