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

# Workspace выбирает профиль CLI (GENIE_PROFILE), а без него — GENIE_HOST: CLI сам находит
# профиль с этим хостом. Без обоих CLI берёт профиль по умолчанию из ~/.databrickscfg.
GENIE_HOST="${GENIE_HOST:-}"
GENIE_PROFILE="${GENIE_PROFILE:-}"
GENIE_SPACE_ID="${GENIE_SPACE_ID:-}"

if [[ -n "${GENIE_TOKEN:-}" ]]; then
    echo "Warning: GENIE_TOKEN is no longer used: genie logs in via databricks CLI. Remove it from .env and revoke the PAT in Databricks." >&2
fi

# Подсказка ведёт в тот же workspace, что и запрос. Иначе человек логинится под одним
# профилем, а следующий запрос снова уходит в профиль по умолчанию и падает так же.
genie_login_hint() {
    local cmd
    if [[ -n "$GENIE_PROFILE" ]]; then
        cmd="databricks auth login --host ${GENIE_HOST:-<workspace-url>} --profile $GENIE_PROFILE"
    elif [[ -n "$GENIE_HOST" ]]; then
        cmd="databricks auth login --host $GENIE_HOST"
    else
        cmd="databricks auth login --host <workspace-url> --profile <profile>, then set GENIE_PROFILE=<profile> in .env"
    fi
    echo "Login required. It opens a browser, so the user has to run it (an agent should stop and ask the user): $cmd" >&2
}

if ! command -v databricks >/dev/null 2>&1; then
    echo "Error: databricks CLI not found. Install: https://docs.databricks.com/aws/en/dev-tools/cli/install" >&2
    genie_login_hint
    exit 1
fi

if [[ -z "$GENIE_SPACE_ID" || "$GENIE_SPACE_ID" == your* ]]; then
    if [[ -n "$GENIE_PROFILE" ]]; then
        list_spaces="databricks genie list-spaces --profile $GENIE_PROFILE"
    elif [[ -n "$GENIE_HOST" ]]; then
        list_spaces="DATABRICKS_HOST=$GENIE_HOST databricks genie list-spaces"
    else
        list_spaces="databricks genie list-spaces --profile <profile>"
    fi
    echo "Error: GENIE_SPACE_ID is not set. Add it to .env. List spaces: $list_spaces" >&2
    exit 1
fi

GENIE_CLI_ARGS=(-o json)
if [[ -n "$GENIE_PROFILE" ]]; then
    GENIE_CLI_ARGS+=(--profile "$GENIE_PROFILE")
elif [[ -n "$GENIE_HOST" ]]; then
    # Только без профиля: при заданном профиле хост из окружения перебил бы хост профиля.
    export DATABRICKS_HOST="$GENIE_HOST"
fi
