#!/bin/bash
# Time (Mattermost) Message operations — Layer 2
# Usage: ./time-messages.sh [--as bot|me] <action> [args...] [--resolve-users]
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIME="$SCRIPT_DIR/time.sh"
SIGNATURE_FILE="$SCRIPT_DIR/../.time-signature"

# Load message signature (appended to every outgoing message)
TIME_SIGNATURE=""
if [[ -f "$SIGNATURE_FILE" ]]; then
    TIME_SIGNATURE=$(cat "$SIGNATURE_FILE")
fi

# Best-effort load .env so optional defaults (e.g. $TIME_TEAM_ID for `search`) are available.
# Non-fatal: explicit-arg forms work without it (auth itself is handled by the time.sh subprocess).
_hub_load_env_sh="$SCRIPT_DIR/../../hub-meta/scripts/load-env.sh"
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "$SCRIPT_DIR"/../../../hub-meta/*/scripts/load-env.sh 2>/dev/null | head -1)
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "${CLAUDE_PLUGIN_ROOT:-/dev/null}"/../../hub-meta/*/scripts/load-env.sh 2>/dev/null | head -1)
[[ -f "$_hub_load_env_sh" ]] && { source "$_hub_load_env_sh"; hub_load_env "$SCRIPT_DIR"; }
unset _hub_load_env_sh

# Pass through --as flag
AS_ARGS=()
if [[ "$1" == "--as" ]]; then
    AS_ARGS=("--as" "$2")
    shift 2
fi

# Strip --resolve-users / --enrich anywhere in the remaining args
RESOLVE_USERS=0
_new_args=()
for arg in "$@"; do
    case "$arg" in
        --resolve-users|--enrich) RESOLVE_USERS=1 ;;
        *) _new_args+=("$arg") ;;
    esac
done
set -- "${_new_args[@]}"

# Shared helpers (extract_post_id, enrich_* etc.) — pure function definitions.
# shellcheck source=./time-helpers.sh
source "$SCRIPT_DIR/time-helpers.sh"

action="${1}"

case "$action" in
    posts)
        # Get posts in channel (newest first)
        # Usage: ./time-messages.sh posts <channel_id> [page] [per_page] [--resolve-users]
        CHANNEL_ID="${2:?Channel ID required}"
        PAGE="${3:-0}"
        PER_PAGE="${4:-30}"
        RESULT=$("$TIME" "${AS_ARGS[@]}" GET "/api/v4/channels/${CHANNEL_ID}/posts?page=${PAGE}&per_page=${PER_PAGE}")
        if (( RESOLVE_USERS )); then
            enrich_posts_dict "$RESULT"
        else
            echo "$RESULT"
        fi
        ;;

    get)
        # Get single post by ID or permalink URL
        # Usage: ./time-messages.sh get <post_id|permalink>
        INPUT="${2:?Post ID or permalink required}"
        POST_ID=$(extract_post_id "$INPUT")
        "$TIME" "${AS_ARGS[@]}" GET "/api/v4/posts/${POST_ID}"
        ;;

    thread)
        # Get thread by root post ID or permalink URL
        # Usage: ./time-messages.sh thread <post_id|permalink> [--resolve-users]
        INPUT="${2:?Post ID or permalink required}"
        POST_ID=$(extract_post_id "$INPUT")
        RESULT=$("$TIME" "${AS_ARGS[@]}" GET "/api/v4/posts/${POST_ID}/thread")
        if (( RESOLVE_USERS )); then
            enrich_posts_dict "$RESULT"
        else
            echo "$RESULT"
        fi
        ;;

    send)
        # Send message to channel, optionally with file attachments
        # Usage: ./time-messages.sh send <channel_id> <message> [root_id] [--file <path>]...
        CHANNEL_ID="${2:?Channel ID required}"
        MESSAGE="${3:?Message required}"
        shift 3
        ROOT_ID=""
        FILE_PATHS=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --file) FILE_PATHS+=("${2:?--file requires a path}"); shift 2 ;;
                *) ROOT_ID="$1"; shift ;;
            esac
        done
        MESSAGE="${MESSAGE}${TIME_SIGNATURE}"

        FILE_IDS=()
        for f in "${FILE_PATHS[@]}"; do
            UPLOAD_RESP=$("$TIME" "${AS_ARGS[@]}" UPLOAD "/api/v4/files?channel_id=${CHANNEL_ID}" "$f")
            FILE_IDS+=("$(echo "$UPLOAD_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["file_infos"][0]["id"])')")
        done

        BODY=$(CHANNEL_ID="$CHANNEL_ID" ROOT_ID="$ROOT_ID" FILE_IDS="${FILE_IDS[*]}" python3 -c '
import sys, os, json
body = {"channel_id": os.environ["CHANNEL_ID"], "message": sys.stdin.read().strip()}
if os.environ["ROOT_ID"]:
    body["root_id"] = os.environ["ROOT_ID"]
if os.environ["FILE_IDS"]:
    body["file_ids"] = os.environ["FILE_IDS"].split()
print(json.dumps(body))' <<< "$MESSAGE")

        "$TIME" "${AS_ARGS[@]}" POST "/api/v4/posts" "$BODY"
        ;;

    search)
        # Search messages in team
        # Usage: ./time-messages.sh search <team_id> <terms> [is_or_search] [--resolve-users]
        #    or: ./time-messages.sh search <terms>   (team_id берётся из $TIME_TEAM_ID в .env)
        if [[ -n "$3" ]]; then
            # Explicit form (backward-compatible): <team_id> <terms> [is_or_search]
            TEAM_ID="$2"
            TERMS="$3"
            IS_OR="${4:-false}"
        else
            # Short form: <terms>, team_id defaults from $TIME_TEAM_ID
            TEAM_ID="${TIME_TEAM_ID:?Team ID required: передай <team_id> первым аргументом или задай TIME_TEAM_ID в .env}"
            TERMS="${2:?Search terms required}"
            IS_OR="false"
        fi

        ESCAPED_TERMS=$(echo "$TERMS" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip())[1:-1])')

        RESULT=$("$TIME" "${AS_ARGS[@]}" POST "/api/v4/teams/${TEAM_ID}/posts/search" "{\"terms\":\"$ESCAPED_TERMS\",\"is_or_search\":$IS_OR}")
        if (( RESOLVE_USERS )); then
            enrich_posts_dict "$RESULT"
        else
            echo "$RESULT"
        fi
        ;;

    user)
        # Get user info by ID (for resolving usernames)
        # Usage: ./time-messages.sh user <user_id>
        USER_ID="${2:?User ID required}"
        "$TIME" "${AS_ARGS[@]}" GET "/api/v4/users/${USER_ID}"
        ;;

    users)
        # List or search users.
        # Usage: ./time-messages.sh users [search_term] [page] [per_page]
        #   Without term:  GET /users?page=&per_page=
        #   With term:     POST /users/search {"term": ...}
        TERM="${2:-}"
        PAGE="${3:-0}"
        PER_PAGE="${4:-50}"
        if [[ -z "$TERM" ]]; then
            "$TIME" "${AS_ARGS[@]}" GET "/api/v4/users?page=${PAGE}&per_page=${PER_PAGE}"
        else
            ESCAPED_TERM=$(echo "$TERM" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip())[1:-1])')
            "$TIME" "${AS_ARGS[@]}" POST "/api/v4/users/search" "{\"term\":\"$ESCAPED_TERM\"}"
        fi
        ;;

    dm)
        # Read last N messages from a direct channel with @username.
        # Usage: ./time-messages.sh dm <@username|username> [limit]
        # Auto-enriches with user info (no flag needed) since DM context is otherwise opaque.
        HANDLE="${2:?Username (@user or user) required}"
        LIMIT="${3:-30}"
        NAME="${HANDLE#@}"

        OTHER=$("$TIME" "${AS_ARGS[@]}" GET "/api/v4/users/username/${NAME}")
        OTHER_ID=$(echo "$OTHER" | jq -r '.id // empty')
        if [[ -z "$OTHER_ID" ]]; then
            echo "User @${NAME} not found" >&2
            exit 1
        fi

        ME=$("$TIME" "${AS_ARGS[@]}" GET "/api/v4/users/me")
        ME_ID=$(echo "$ME" | jq -r '.id // empty')
        if [[ -z "$ME_ID" ]]; then
            echo "Failed to resolve current user id" >&2
            exit 1
        fi

        CHANNEL=$("$TIME" "${AS_ARGS[@]}" POST "/api/v4/channels/direct" "[\"${ME_ID}\",\"${OTHER_ID}\"]")
        CHANNEL_ID=$(echo "$CHANNEL" | jq -r '.id // empty')
        if [[ -z "$CHANNEL_ID" ]]; then
            echo "Failed to create/get DM channel" >&2
            exit 1
        fi

        RESULT=$("$TIME" "${AS_ARGS[@]}" GET "/api/v4/channels/${CHANNEL_ID}/posts?per_page=${LIMIT}")
        enrich_posts_dict "$RESULT"
        ;;

    my-posts)
        # List posts authored by current user in a channel (auto-paginates)
        # Usage: ./time-messages.sh my-posts <channel_id> [max_posts] [--resolve-users]
        CHANNEL_ID="${2:?Channel ID required}"
        MAX_POSTS="${3:-800}"
        PER_PAGE=200

        MY_ID=$("$TIME" "${AS_ARGS[@]}" GET "/api/v4/users/me" | jq -r '.id')
        if [[ -z "$MY_ID" || "$MY_ID" == "null" ]]; then
            echo "Failed to resolve current user id" >&2
            exit 1
        fi

        page=0
        scanned=0
        results="[]"
        while (( scanned < MAX_POSTS )); do
            batch=$("$TIME" "${AS_ARGS[@]}" GET "/api/v4/channels/${CHANNEL_ID}/posts?page=${page}&per_page=${PER_PAGE}")
            count=$(echo "$batch" | jq '.order | length')
            if [[ "$count" == "0" ]]; then break; fi

            mine=$(echo "$batch" | jq --arg me "$MY_ID" '[.order[] as $id | .posts[$id] | select(.user_id == $me) | {id, user_id, create_at, root_id, message}]')
            results=$(jq -s '.[0] + .[1]' <(echo "$results") <(echo "$mine"))

            scanned=$(( scanned + count ))
            page=$(( page + 1 ))
            if (( count < PER_PAGE )); then break; fi
        done

        SORTED=$(echo "$results" | jq 'sort_by(.create_at)')
        if (( RESOLVE_USERS )); then
            enrich_post_array "$SORTED"
        else
            echo "$SORTED"
        fi
        ;;

    *)
        echo "Usage: $0 [--as bot|me] <action> [args...] [--resolve-users]" >&2
        echo "Actions: posts, get, thread, send, search, user, users, dm, my-posts" >&2
        echo "" >&2
        echo "Permalink support: 'get' and 'thread' accept either a raw post_id" >&2
        echo "  or a permalink URL like https://<host>/<team>/pl/<post_id>." >&2
        echo "" >&2
        echo "Enrichment: --resolve-users adds {user: {username, ...}} to each post" >&2
        echo "  for posts, thread, search, my-posts. DM action auto-enriches." >&2
        echo "  Cached at integrations/time/.cache/users.json (7-day TTL)." >&2
        exit 1
        ;;
esac
