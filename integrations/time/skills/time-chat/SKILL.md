---
name: time-chat
description: >
  Read a Time (Mattermost) post, thread, or DM when the user shares a
  permalink URL like https://<host>/<team>/pl/<post_id> or asks to look up
  a conversation by @handle. Triggers on Time/Mattermost permalinks, on
  any "time-messenger" / "тайм" / "Mattermost" mention paired with a link
  or @username, and on requests to read direct messages with a specific
  user.
---

# Time (Mattermost) read skill

When a Time permalink or a "read DMs with @user" request appears, fetch the
content via the plugin's bash wrappers and summarise it for the user.

## Trigger

Activate on any of:

- A permalink URL: `https://<host>/<team>/pl/<post_id>` (query/fragment ok)
- A request to read DMs / личные сообщения with a specific `@user`
- A search request against Time/Mattermost ("найди в тайме …")

## Read

First resolve the helper once — independent of the current directory. This skill is
activated from an arbitrary CWD (a marketplace plugin lives in a cache dir; a team overlay
may vendor this repo as a git subtree and symlink the skill into `~/.claude/skills/`), so a
bare `integrations/time/scripts/...` path does not resolve. The snippet below finds
`time-messages.sh` for **every** install model, with no consumer-specific knowledge:

```bash
_t=""
# 1) marketplace (Claude Code / Copilot / Cursor): $CLAUDE_PLUGIN_ROOT → this plugin's dir
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/time-messages.sh" ] && _t="$CLAUDE_PLUGIN_ROOT"
# 2) subtree + skill symlink (a team overlay vendoring ai-hub): find our own symlink, walk up
if [ -z "$_t" ]; then for _d in "$HOME"/.claude/skills/*; do
  [ -L "$_d" ] || continue; _r="$(readlink -f "$_d" 2>/dev/null)"
  case "$_r" in */integrations/time/skills/time-chat)
    [ -f "${_r%/skills/time-chat}/scripts/time-messages.sh" ] && { _t="${_r%/skills/time-chat}"; break; } ;;
  esac
done; fi
# 3) Copilot _direct install
[ -z "$_t" ] && [ -f "$HOME/.copilot/installed-plugins/_direct/time/scripts/time-messages.sh" ] && _t="$(readlink -f "$HOME/.copilot/installed-plugins/_direct/time")"
# 4) plain git clone (run from anywhere inside it)
[ -z "$_t" ] && _r="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -f "$_r/integrations/time/scripts/time-messages.sh" ] && _t="$_r/integrations/time"
TIME_MESSAGES="$_t/scripts/time-messages.sh"
```

The scripts accept permalinks directly — no manual id extraction.

```bash
# Single post by permalink or raw id
"$TIME_MESSAGES" get "<permalink_or_post_id>"

# Full thread (preferred — gives complete context)
"$TIME_MESSAGES" thread "<permalink_or_post_id>" --resolve-users

# DMs with a user (auto-enriched)
"$TIME_MESSAGES" dm @<username> [limit]

# Search in a team
"$TIME_MESSAGES" search <team_id> "<query>" --resolve-users
```

`--resolve-users` inlines `{username, nickname, first_name, last_name}` next
to every `user_id` so authors are human-readable. Cached at
`integrations/time/.cache/users.json` (7-day TTL).

## Summarise

After fetching, give the user a concise wrap-up: who participated, key
decisions, action items, anything relevant to the current task. For long
threads (50+ messages) summarise rather than repeat verbatim.

## See also

- `commands/time-chat.md` — full interactive workflow, including posting
- `README.md` — auth setup, all actions, troubleshooting
