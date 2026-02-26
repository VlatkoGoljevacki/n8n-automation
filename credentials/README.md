# Credentials Setup

These credentials must be created manually in the n8n UI (Settings > Credentials).
They cannot be safely version-controlled because n8n encrypts them at rest.

## Required for medika-preorders

### Medika Preorders - Microsoft Outlook (Graph API via OAuth2)

This is the primary credential for reading/sending email. Uses Microsoft Graph API.

#### Step 1: Azure AD App Registration

1. Go to [Azure Portal → App registrations](https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
2. Click **New registration**
   - **Name**: `Medika Preorders - n8n`
   - **Supported account types**: **Accounts in any organizational directory and personal Microsoft accounts**
     - IMPORTANT: Do NOT choose "Personal Microsoft accounts only" — n8n uses the `/common/` OAuth endpoint which requires the "All" audience
   - **Redirect URI**: Web → `http://localhost:<N8N_PORT>/rest/oauth2-credential/callback`
     - Must match exactly: correct port, `http` not `https`, no trailing slash
3. Note the **Application (client) ID** from the Overview page

#### Step 2: Client Secret

1. Go to **Certificates & secrets** (left sidebar)
2. Click **New client secret** → add a description → click Add
3. Copy the **Value** immediately (only shown once)

#### Step 3: API Permissions

1. Go to **API permissions** (left sidebar)
2. Click **Add a permission** → **Microsoft Graph** → **Delegated permissions**
3. Add these permissions:
   - `Mail.Read`
   - `Mail.ReadWrite`
   - `Mail.Send`
   - `User.Read`
4. Click **Grant admin consent** (if you're the tenant admin)

#### Step 4: n8n Credential

1. In n8n: **Settings → Credentials → Add Credential**
2. Search for **Microsoft Outlook OAuth2 API**
3. Fill in:
   - **Name**: `Medika Preorders - Microsoft Outlook`
   - **Client ID**: (from Step 1)
   - **Client Secret**: (from Step 2)
4. Click **Sign in with Microsoft** → sign in and accept permissions

#### Troubleshooting

**Error: "not valid for the application's 'userAudience' configuration"**
- The app is configured as "Personal Microsoft accounts only" instead of "All"
- Fix: Azure Portal → App registration → Authentication → change Supported account types to "Accounts in any organizational directory and personal Microsoft accounts"
- Or edit the **Manifest** directly: set `"signInAudience"` to `"AzureADandPersonalMicrosoftAccount"`
- After changing, **delete and recreate** the n8n credential (cached OAuth state can cause stale errors)

**Error: redirect URI mismatch**
- Azure Portal → App registration → Authentication → check the redirect URI matches exactly: `http://localhost:<PORT>/rest/oauth2-credential/callback`

**Note on SMTP**: Personal Outlook.com accounts have SMTP AUTH disabled and there's no toggle to enable it (that's an Exchange Online admin feature). Basic SMTP auth is being deprecated by Microsoft entirely (April 2026). Use the Graph API OAuth2 approach above instead.

### Demo account

- **Email**: `kamehameha.digital@outlook.com`
- **Azure tenant**: personal account with Azure free tier
- **Production**: will use Medika's M365 enterprise tenant with a dedicated `prednarudzbe@medika.hr` mailbox
