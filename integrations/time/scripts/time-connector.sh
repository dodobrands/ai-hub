#!/bin/bash
# Time (Mattermost) → Claude Code Channel connector — launcher.
#
# Loads .env (TIME_BOT_TOKEN, TIME_BASE_URL, TIME_CONNECTOR_*) through hub-meta/scripts/load-env.sh,
# locates team-config.json (whitelist: time.connector.allowed_users) and execs the TypeScript
# MCP server in integrations/time/connector/ on bun (preferred) or node >= 22.6.
#
# Usage: ./time-connector.sh [serve|check|print-env]
#   serve      — MCP stdio server (what Claude Code launches; stdout is the MCP transport — keep it clean)
#   check      — REST-only preflight: bot identity, whitelist resolution, teams
#   print-env  — non-secret diagnostics for the slash command / tests (never prints the token)
# Env:
#   TIME_CONNECTOR_RUNTIME=bun|node   force runtime
#   TIME_TEAM_CONFIG=/path/team-config.json   override whitelist config location
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same load-env resolution as time.sh: marketplace layout → plugin cache → CLAUDE_PLUGIN_ROOT.
_hub_load_env_sh="$SCRIPT_DIR/../../hub-meta/scripts/load-env.sh"
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "$SCRIPT_DIR"/../../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1)
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "${CLAUDE_PLUGIN_ROOT:-/dev/null}"/../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1)
if [[ -f "$_hub_load_env_sh" ]]; then
    # shellcheck source=../../hub-meta/scripts/load-env.sh
    source "$_hub_load_env_sh"
    hub_load_env "$SCRIPT_DIR" || true
else
    echo "time-connector: warning: hub-meta/scripts/load-env.sh not found — relying on inherited environment" >&2
fi
unset _hub_load_env_sh

MODE="${1:-serve}"
CONNECTOR_DIR="$SCRIPT_DIR/../connector"

export TIME_BASE_URL="${TIME_BASE_URL:-https://your-company.time-messenger.ru}"

# team-config.json: explicit → overlay root → git toplevel → repo root relative to this script
if [[ -z "${TIME_TEAM_CONFIG:-}" ]]; then
    for c in \
        "${HUB_OVERLAY_ROOT:-/nonexistent}/team-config.json" \
        "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)/team-config.json" \
        "$SCRIPT_DIR/../../../team-config.json"; do
        if [[ -f "$c" ]]; then TIME_TEAM_CONFIG="$c"; break; fi
    done
fi
export TIME_TEAM_CONFIG="${TIME_TEAM_CONFIG:-}"

node_ok() {
    command -v node >/dev/null 2>&1 || return 1
    local v major minor
    v=$(node --version 2>/dev/null | sed 's/^v//')
    major=${v%%.*}; minor=${v#*.}; minor=${minor%%.*}
    [[ "$major" -gt 22 ]] || { [[ "$major" -eq 22 ]] && [[ "$minor" -ge 6 ]]; }
}

pick_runtime() {
    case "${TIME_CONNECTOR_RUNTIME:-}" in
        bun)  command -v bun >/dev/null 2>&1 && { echo bun; return; } ;;
        node) node_ok && { echo node; return; } ;;
        "")   if command -v bun >/dev/null 2>&1; then echo bun; return; fi
              if node_ok; then echo node; return; fi ;;
    esac
    echo missing
}

RUNTIME=$(pick_runtime)

case "$MODE" in
    print-env)
        echo "TIME_BASE_URL=$TIME_BASE_URL"
        echo "TIME_TEAM_CONFIG=$TIME_TEAM_CONFIG"
        echo "TIME_BOT_TOKEN=$([[ -n "${TIME_BOT_TOKEN:-}" ]] && echo set || echo missing)"
        echo "TIME_CONNECTOR_ALLOWED_USERS=${TIME_CONNECTOR_ALLOWED_USERS:-}"
        echo "RUNTIME=$RUNTIME"
        echo "CONNECTOR_DIR=$(cd "$CONNECTOR_DIR" 2>/dev/null && pwd || echo "$CONNECTOR_DIR")"
        exit 0
        ;;
    serve|check) ;;
    *)
        echo "time-connector: unknown mode '$MODE' (serve|check|print-env)" >&2
        exit 2
        ;;
esac

if [[ -z "${TIME_BOT_TOKEN:-}" ]]; then
    echo "time-connector: TIME_BOT_TOKEN not set — add the Time bot token to .env (bash integrations/hub-meta/scripts/env-manager.sh set TIME_BOT_TOKEN <token>). See integrations/time/README.md, section «Connector»." >&2
    exit 1
fi

if [[ "$RUNTIME" == "missing" ]]; then
    echo "time-connector: no suitable runtime — install bun (https://bun.sh) or Node.js >= 22.6" >&2
    exit 1
fi

[[ -f "$CONNECTOR_DIR/server.ts" ]] || { echo "time-connector: $CONNECTOR_DIR/server.ts not found" >&2; exit 1; }
cd "$CONNECTOR_DIR"

# Dependencies are installed on first run (stdout stays clean for MCP stdio).
if [[ ! -d node_modules/@modelcontextprotocol/sdk ]]; then
    echo "time-connector: installing dependencies in $CONNECTOR_DIR …" >&2
    if [[ "$RUNTIME" == "bun" ]]; then
        bun install --no-summary 1>&2
    else
        npm install --no-audit --no-fund --silent 1>&2
    fi
fi

if [[ "$RUNTIME" == "bun" ]]; then
    exec bun server.ts "$MODE"
else
    exec node --experimental-strip-types --no-warnings server.ts "$MODE"
fi
