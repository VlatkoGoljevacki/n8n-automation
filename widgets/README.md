# Widgets

Reusable standalone tools that can be embedded in any project.

## feedback/

Visual feedback widget for any website. Adds a floating button that lets users click anywhere on a page, pin a comment, and reply in threads. Data stored via n8n webhook + data table.

### Setup

1. **n8n data table** `feedback_comments` with columns:

   | Column | Type | Description |
   |--------|------|-------------|
   | id | Auto/Number | Primary key |
   | project | String | Project identifier (e.g. `spona`, `client-x`) |
   | page | String | Page filename (e.g. `dashboard-salary.html`) |
   | x_pct | Number | Click X position as % of page width (0-100) |
   | y_pct | Number | Click Y position as % of page height (0-100) |
   | comment | String | Comment text |
   | author | String | Commenter name |
   | parent_id | Number | null = top-level, ID of parent = reply |
   | resolved | Boolean | false by default |
   | created_at | String | ISO timestamp |

2. **Two n8n workflows:**
   - **GET** webhook: receives `?project=X&page=Y`, filters data table, returns JSON array
   - **POST** webhook: receives `{ project, page, x_pct, y_pct, comment, author, parent_id }`, adds `created_at` + `resolved: false`, inserts row, returns created row

3. **Auth:** Both workflows check `X-Feedback-Token` header. Default token: `n8n-automation-wladisha`

### Usage

Add to any HTML page:

```html
<script src="path/to/feedback.js"
        data-api="https://your-n8n-url/webhook/comments"
        data-token="n8n-automation-wladisha"
        data-project="my-project-name">
</script>
```

- `data-api` — n8n webhook URL (same for GET and POST)
- `data-token` — auth token (must match n8n workflow)
- `data-project` — project identifier (scopes comments so multiple projects share one data table)

### Features

- Click anywhere to pin a comment
- Threaded replies on each pin
- Author name saved in localStorage
- Comments scoped by project + page
- No dependencies, single JS file (~300 lines)
- Works on any static or dynamic website

---

## transcribe/

Audio/video transcription using faster-whisper. Outputs plain text + VTT subtitles.

### Setup

```bash
pipx install faster-whisper --include-deps
```

### Usage

```bash
pipx run --spec faster-whisper python transcribe.py INPUT_FILE [options]

# Options:
#   --language hr          Language code (default: hr)
#   --model large-v3       Model size (default: large-v3)
#   --output-dir ./out     Output directory (default: same as input)

# Examples:
pipx run --spec faster-whisper python transcribe.py meeting.m4a
pipx run --spec faster-whisper python transcribe.py call.mp4 --language en --model medium
```

### Models

| Model | Speed | Accuracy |
|-------|-------|----------|
| tiny | ~2x realtime | Low |
| base | ~1.5x realtime | Decent |
| small | ~1x realtime | Good |
| medium | ~0.3x realtime | Very good |
| large-v3 | ~0.15x realtime | Best |

For Croatian/low-resource languages, use `large-v3`. For English, `medium` is usually sufficient.
