#!/bin/bash
# Databricks Genie configuration
#
# Авторизация — OAuth через databricks CLI: токен живёт в кэше CLI и в скрипт не попадает.
# PAT не используем: его выпуск в Databricks бывает закрыт политикой безопасности.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source hub-meta/scripts/load-env.sh from either marketplace layout
# (<root>/integrations/<plugin>/scripts/) or Claude Code plugin cache
# (<cache>/<marketplace>/<plugin>/<version>/scripts/, resolved by globbing the
# sibling hub-meta versions and taking the highest, with $CLAUDE_PLUGIN_ROOT
# as a last resort).
_hub_load_env_sh="$SCRIPT_DIR/../../hub-meta/scripts/load-env.sh"
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "$SCRIPT_DIR"/../../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1)
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "${CLAUDE_PLUGIN_ROOT:-/dev/null}"/../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1)
[[ -f "$_hub_load_env_sh" ]] || { echo "Error: hub-meta/scripts/load-env.sh not found (marketplace and plugin-cache layouts checked)" >&2; exit 1; }
# shellcheck source=../../hub-meta/scripts/load-env.sh
source "$_hub_load_env_sh"
unset _hub_load_env_sh
# Секретов в .env у Genie нет, поэтому без файла тоже работаем — значения могут прийти из окружения.
hub_load_env "$SCRIPT_DIR" || true

# Хост живёт в профиле CLI; GENIE_HOST нужен только для подсказки с командой логина.
GENIE_HOST="${GENIE_HOST:-}"
# Пусто — CLI возьмёт DATABRICKS_CONFIG_PROFILE или профиль DEFAULT.
GENIE_PROFILE="${GENIE_PROFILE:-}"
GENIE_SPACE_ID="${GENIE_SPACE_ID:-}"

genie_login_hint() {
    echo "Login: databricks auth login --host ${GENIE_HOST:-<workspace-url>} --profile ${GENIE_PROFILE:-<profile>}" >&2
}

if ! command -v databricks >/dev/null 2>&1; then
    echo "Error: databricks CLI not found. Install: https://docs.databricks.com/aws/en/dev-tools/cli/install" >&2
    genie_login_hint
    exit 1
fi

if [[ -z "$GENIE_SPACE_ID" || "$GENIE_SPACE_ID" == your* ]]; then
    echo "Error: GENIE_SPACE_ID is not set. Add it to .env. List spaces: databricks genie list-spaces --profile ${GENIE_PROFILE:-<profile>}" >&2
    exit 1
fi

GENIE_CLI_ARGS=(-o json)
if [[ -n "$GENIE_PROFILE" ]]; then
    GENIE_CLI_ARGS+=(--profile "$GENIE_PROFILE")
fi
