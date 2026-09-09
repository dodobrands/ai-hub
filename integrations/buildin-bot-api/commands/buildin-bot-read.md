---
description: "Read a Buildin.ai page via Official Bot API (by URL, page_id, or search query)"
argument-hint: "<page URL, UUID, or search query>"
---

# Buildin Bot API — Read Page

Read a Buildin.ai page using the Official Bot API (`api.buildin.ai/v1/`).

**Important:** The bot can only access pages that have been explicitly shared with the bot integration. If you get a 403 error, ask the user to share the page with the bot in Buildin settings.

## Auth check

```bash
$INTEGRATION_DIR/../buildin-bot-api/scripts/buildin-bot.sh GET /v1/users/me
```

If token is missing, ask the user to:
1. Go to Buildin → Settings → Integrations → Create bot integration
2. Copy the generated token
3. Run: `bash integrations/sagos95-ai-hub/integrations/hub-meta/scripts/env-manager.sh set BUILDIN_BOT_TOKEN <token>`

## Input handling

The user provides `$ARGUMENTS` — it can be:
- **URL** like `https://buildin.ai/.../page-uuid` → extract UUID
- **UUID** like `2a904afe-42e9-4ebd-a94e-f6fe0cbacf58` → use directly
- **Search query** like `"RFC template"` → ⚠️ read the warning below first

> **⚠️ The Bot API search endpoint `POST /v1/search` is broken — do NOT search via this command.**
> That specific endpoint returns **HTTP 500** server-side (not fixable here), so `buildin-bot-pages.sh search` is guarded and fails on purpose. This is *not* "Buildin search" in general — the UI-API integration uses different mechanisms that work: a local shadow-index (`buildin-shadow.sh search`) and UI search (`POST /api/search/...`, low quality). Reach those via the `/ai-hub:buildin-read` command.
> If you were given only a title/topic (no URL or UUID), get a `page_id` this way — do **not** loop on search:
> 1. **Ask the user for the page URL or page_id.** This is the fastest reliable path.
> 2. Or, if a base page in that area is known, navigate its tree via the UI-API command `/ai-hub:buildin-read` (it has a working shadow-index + `buildin-nav children`).

## Execution

### If URL or UUID detected:

```bash
$INTEGRATION_DIR/../buildin-bot-api/scripts/buildin-bot-pages.sh read "$PAGE_ID"
```

### If only a title / search query (no URL/UUID):

Bot API search is broken (HTTP 500) — **do not call `buildin-bot-pages.sh search`.** Ask the user for the page URL/page_id, or switch to the UI-API command `/ai-hub:buildin-read` (shadow-index + tree navigation). Once you have a `page_id`:

```bash
$INTEGRATION_DIR/../buildin-bot-api/scripts/buildin-bot-pages.sh read "$SELECTED_PAGE_ID"
```

## Output

Return the markdown content to the user. If the page has child pages, mention them so the user can navigate deeper.
