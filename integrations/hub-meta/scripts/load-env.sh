#!/bin/bash
# Shared helper to load .env for all integration scripts.
#
# Behavior:
#   1. Unsets known secrets from inherited shell environment, so .env
#      is the only authoritative source. Without this, a stale token in
#      ~/.zshrc could silently override the per-repo .env file.
#   2. Walks UP from the caller's SCRIPT_DIR to find the nearest .env
#      file. This is overlay-aware: when scripts live inside a git-subtree
#      (e.g. som-ai-hub/integrations/sagos95-ai-hub/...), the team-overlay's
#      .env at the repo root takes precedence over any .env inside the
#      subtree itself.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../../hub-meta/scripts/load-env.sh"
#   hub_load_env "$SCRIPT_DIR"
#
# After hub_load_env returns successfully, $HUB_ENV_FILE holds the
# absolute path of the file that was sourced.

# Known secret variable names. Add new tokens here so they are stripped
# from inherited shell environment before sourcing .env.
#
# Team-local wrappers may extend this list before calling hub_load_env, e.g.:
#   source "$SCRIPT_DIR/../../sagos95-ai-hub/.../load-env.sh"
#   HUB_KNOWN_SECRETS+=(MY_CUSTOM_TOKEN)
#   hub_load_env "$SCRIPT_DIR"
HUB_KNOWN_SECRETS=(
    KAITEN_TOKEN
    BUILDIN_UI_TOKEN
    BUILDIN_BOT_TOKEN
    TIME_TOKEN
    TIME_BOT_TOKEN
    GENIE_TOKEN
    KUSTO_TOKEN
    TESTOPS_TOKEN
)

hub_load_env() {
    local start="${1:-$PWD}"

    # Relative paths collapse to "." under dirname and the walk below would
    # loop forever (dirname . == .). Normalize to an absolute path first.
    if [[ "$start" != /* ]]; then
        start="$(cd "$start" 2>/dev/null && pwd)" || start="$PWD"
    fi

    local _k
    for _k in "${HUB_KNOWN_SECRETS[@]}"; do
        unset "$_k"
    done

    # Walk up collecting all .env files innermost-FIRST via append. The
    # resulting array is ordered innermost→outermost (found[0] = nearest .env,
    # found[last] = overlay root). Sourcing in that order makes the outer .env
    # (overlay root) win on conflicting keys, while inner-only keys (e.g. one
    # shipped inside a vendored subtree) are still picked up. This gives
    # team-overlay installs the expected behavior — team .env at the repo root
    # overrides any leftover values inside integrations/sagos95-ai-hub/.env,
    # while still picking up subtree-only keys (e.g. KUSTO_CLUSTER,
    # TIME_BASE_URL) when the overlay doesn't redefine them.
    local found=()
    local dir="$start"
    # The "." guard is a safety net in case start was not normalized to an
    # absolute path (dirname of a relative path eventually yields ".", which
    # dirname maps back to "." forever).
    while [[ "$dir" != "/" && "$dir" != "." && -n "$dir" ]]; do
        if [[ -f "$dir/.env" ]]; then
            found=("${found[@]}" "$dir/.env")
        fi
        dir="$(dirname "$dir")"
    done

    if [[ ${#found[@]} -eq 0 ]]; then
        return 1
    fi

    # Source innermost first, outermost last → outermost (overlay root) wins.
    local _f
    for _f in "${found[@]}"; do
        set -a
        # shellcheck disable=SC1090,SC1091
        source "$_f"
        set +a
    done

    # Overlay root = directory of the OUTERMOST .env (last in `found`).
    # Use len-1 indexing instead of ${found[-1]} for bash 3.x compatibility
    # (macOS ships /bin/bash 3.2 by default).
    local outermost="${found[$((${#found[@]} - 1))]}"
    export HUB_ENV_FILE="$outermost"
    export HUB_OVERLAY_ROOT="${outermost%/.env}"
    return 0
}

# Resolve the team overlay root: the directory whose .env was sourced by
# hub_load_env. Scripts use this to find shared assets like team-config.json
# that live at the overlay root, not inside the subtree.
#
# If hub_load_env wasn't called or no .env was found, prints nothing and
# returns 1.
hub_overlay_root() {
    if [[ -n "${HUB_OVERLAY_ROOT:-}" ]]; then
        echo "$HUB_OVERLAY_ROOT"
        return 0
    fi
    return 1
}

# Resolve a file inside a sibling plugin, supporting both layouts:
#   1. Marketplace / source: <root>/integrations/<plugin>/<rel>
#   2. Claude Code plugin cache: <cache>/<marketplace>/<plugin>/<version>/<rel>
#      (located via $CLAUDE_PLUGIN_ROOT)
#
# Usage:
#   path=$(hub_resolve_plugin_path hub-meta scripts/browser-cookie-extract.py) \
#       || { echo "not found" >&2; exit 1; }
#
# Prints the absolute path to stdout on success, returns 1 if not found.
hub_resolve_plugin_path() {
    local plugin="$1"
    local rel="$2"
    [[ -z "$plugin" || -z "$rel" ]] && return 1

    # 1. Marketplace / source layout — relative to SUBTREE_ROOT if set.
    if [[ -n "${SUBTREE_ROOT:-}" && -f "$SUBTREE_ROOT/integrations/$plugin/$rel" ]]; then
        echo "$SUBTREE_ROOT/integrations/$plugin/$rel"
        return 0
    fi

    # 2. Claude Code plugin cache: <cache>/<marketplace>/<plugin>/<version>/<rel>.
    # $CLAUDE_PLUGIN_ROOT points at the current plugin's versioned dir, so its
    # grandparent is <cache>/<marketplace>/.
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        local marketplace_cache
        marketplace_cache="$(cd "$CLAUDE_PLUGIN_ROOT/../.." 2>/dev/null && pwd)" || return 1
        local found
        found=$(find "$marketplace_cache/$plugin" -maxdepth 4 -path "*/$rel" -type f 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            echo "$found"
            return 0
        fi
    fi

    return 1
}
