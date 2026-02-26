# Credentials Setup

These credentials must be created manually in the n8n UI (Settings > Credentials).
They cannot be safely version-controlled because n8n encrypts them at rest.

## Required for medika-preorders

### Medika Preorders - SMTP
- **Type**: SMTP
- **Host**: `smtp-mail.outlook.com`
- **Port**: `587`
- **SSL/TLS**: STARTTLS
- **User**: `kamehameha.digital@outlook.com` (demo) / production email TBD
- **Password**: (set in UI)

### Medika Preorders - IMAP
- **Type**: IMAP
- **Host**: `outlook.office365.com`
- **Port**: `993`
- **SSL/TLS**: SSL
- **User**: `kamehameha.digital@outlook.com` (demo) / production email TBD
- **Password**: (set in UI)

### Medika Preorders - Microsoft Outlook OAuth2 (production)
- **Type**: Microsoft Outlook OAuth2 API
- **Client ID**: (from Azure AD app registration)
- **Client Secret**: (set in UI)
- **Tenant ID**: (from Azure AD)
- Required permissions: `Mail.Read`, `Mail.ReadWrite`, `Mail.Send`
