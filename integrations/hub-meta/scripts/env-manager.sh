#!/bin/bash
# env-manager.sh — safe .env file management (never outputs actual values)
#
# Usage: ./env-manager.sh <command> [args...]
#   check              — report set/missing status for all known vars
#   set KEY VALUE      — add or update a key in .env (no duplicates)
#   has KEY            — exit 0 if KEY is set and non-empty, 1 otherwise
#   migrate            — rename .env.local → .env if applicable
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBTREE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=load-env.sh
source "$SCRIPT_DIR/load-env.sh"

# Walk up to find an existing .env. If none exists yet, default to the
# git toplevel (which in an overlay setup is the team repo root, and in a
# standalone ai-hub clone is the ai-hub root itself).
hub_load_env "$SCRIPT_DIR" || true

WRITE_ROOT="${HUB_OVERLAY_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SUBTREE_ROOT")}"
ENV_FILE="${HUB_ENV_FILE:-$WRITE_ROOT/.env}"
ENV_LOCAL_FILE="$WRITE_ROOT/.env.local"

# Known variable groups
COMPANY_CONFIG=(KAITEN_DOMAIN TIME_BASE_URL BUILDIN_SPACE_ID)
COMPANY_OPTIONAL=(GENIE_HOST GENIE_SPACE_ID TIME_CONNECTOR_ALLOWED_USERS)
PERSONAL_TOKENS=(KAITEN_TOKEN BUILDIN_UI_TOKEN TIME_TOKEN)
PERSONAL_OPTIONAL=(GENIE_TOKEN TIME_BOT_TOKEN)

# Re-load env (subcommands may have written to it). Delegates to the
# shared helper so secret stripping rules stay consistent.
load_env() {
    hub_load_env "$SCRIPT_DIR" || true
}

check_var() {
    local key="$1"
    local val="${!key}"
    if [[ -n "$val" && "$val" != your_* && "$val" != your-* && "$val" != YOUR_* ]]; then
        echo "$key=set"
    else
        echo "$key=missing"
    fi
}

cmd_check() {
    load_env

    echo "=== Company Config ==="
    for key in "${COMPANY_CONFIG[@]}"; do
        check_var "$key"
    done

    echo ""
    echo "=== Company Config (optional) ==="
    for key in "${COMPANY_OPTIONAL[@]}"; do
        check_var "$key"
    done

    echo ""
    echo "=== Personal Tokens ==="
    for key in "${PERSONAL_TOKENS[@]}"; do
        check_var "$key"
    done

    echo ""
    echo "=== Personal Tokens (optional) ==="
    for key in "${PERSONAL_OPTIONAL[@]}"; do
        check_var "$key"
    done
}

cmd_set() {
    local key="$1"
    local value="$2"

    if [[ -z "$key" || -z "$value" ]]; then
        echo "Usage: env-manager.sh set KEY VALUE" >&2
        exit 1
    fi

    # Validate key format
    if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
        echo "Error: invalid key format (expected UPPER_SNAKE_CASE)" >&2
        exit 1
    fi

    touch "$ENV_FILE"

    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        # Update existing key (portable sed without -i)
        sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" > "${ENV_FILE}.tmp" \
            && mv "${ENV_FILE}.tmp" "$ENV_FILE"
        echo "updated:$key"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
        echo "added:$key"
    fi
}

cmd_has() {
    local key="$1"

    if [[ -z "$key" ]]; then
        echo "Usage: env-manager.sh has KEY" >&2
        exit 1
    fi

    load_env
    local val="${!key}"
    if [[ -n "$val" && "$val" != your_* && "$val" != your-* && "$val" != YOUR_* ]]; then
        exit 0
    else
        exit 1
    fi
}

# Non-secret whitelist: only these keys are safe to print.
# Tokens and anything sensitive must NEVER be printed.
NONSECRET_WHITELIST=(KAITEN_DOMAIN TIME_BASE_URL BUILDIN_SPACE_ID GENIE_HOST GENIE_SPACE_ID TIME_CONNECTOR_ALLOWED_USERS)

cmd_get() {
    local key="$1"

    if [[ -z "$key" ]]; then
        echo "Usage: env-manager.sh get KEY (non-secret only)" >&2
        exit 1
    fi

    local allowed=0
    for whitelisted in "${NONSECRET_WHITELIST[@]}"; do
        [[ "$key" == "$whitelisted" ]] && allowed=1 && break
    done

    if [[ "$allowed" -eq 0 ]]; then
        echo "error:refused key '$key' is not in non-secret whitelist" >&2
        exit 2
    fi

    load_env
    local val="${!key}"
    if [[ -n "$val" && "$val" != your_* && "$val" != your-* && "$val" != YOUR_* ]]; then
        echo "$val"
    else
        exit 1
    fi
}

cmd_migrate() {
    if [[ -f "$ENV_LOCAL_FILE" && ! -f "$ENV_FILE" ]]; then
        mv "$ENV_LOCAL_FILE" "$ENV_FILE"
        echo "migrated:.env.local -> .env"
    elif [[ -f "$ENV_LOCAL_FILE" && -f "$ENV_FILE" ]]; then
        echo "warning:both .env and .env.local exist — merge manually" >&2
        exit 1
    else
        echo "ok:nothing to migrate"
    fi
}

# --- Main ---
COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    check)   cmd_check ;;
    set)     cmd_set "$1" "$2" ;;
    has)     cmd_has "$1" ;;
    get)     cmd_get "$1" ;;
    migrate) cmd_migrate ;;
    help|*)
        echo "env-manager.sh — safe .env management (never outputs secrets)"
        echo ""
        echo "Commands:"
        echo "  check              — report set/missing status for all known vars"
        echo "  set KEY VALUE      — add or update a key in .env"
        echo "  has KEY            — exit 0 if set, 1 if missing"
        echo "  get KEY            — print value (non-secret whitelist only)"
        echo "  migrate            — rename .env.local -> .env if applicable"
        ;;
esac
