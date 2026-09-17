#!/usr/bin/env bash
# setup.sh — AI Hub setup dispatcher.
#
# Contract for AI agents: call `bash integrations/hub-meta/scripts/setup.sh next`
# in a loop until stdout's first line is "STATUS: DONE". Each call returns one
# current step with precise, ready-to-copy instructions. Execute, loop again.
#
# No "guess what to do" — the script tells you. No "if you're Claude Code vs Codex"
# bifurcation — instructions are unified. Secrets never printed.
#
# Usage:
#   setup.sh next                    — print current step + instructions
#   setup.sh status                  — print completion status of all steps
#   setup.sh mark <step_name>        — mark step explicitly completed (for steps
#                                      without a programmatic check, e.g. holst)
#   setup.sh skip <step_name>        — mark step skipped by user (e.g. team_config)
#   setup.sh reset                   — clear .setup-state (re-run from scratch)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBTREE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load env first so HUB_OVERLAY_ROOT is known. ROOT_DIR is the directory
# whose .env should drive the setup (overlay root in team installs,
# subtree root in standalone ai-hub clones). State file always lives in
# the subtree, since the state schema ships with the subtree code.
# shellcheck source=load-env.sh
source "$SCRIPT_DIR/load-env.sh"
hub_load_env "$SCRIPT_DIR" || true
ROOT_DIR="${HUB_OVERLAY_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SUBTREE_ROOT")}"
cd "$ROOT_DIR"

ENV_MGR="bash $SCRIPT_DIR/env-manager.sh"
STATE_FILE="$SUBTREE_ROOT/integrations/hub-meta/.setup-state"
CONFIG_PAGE_URL="https://buildin.ai/c7ec2023-9025-4c09-be09-e6f54cb07f7e"
CONFIG_PAGE_ID="c7ec2023-9025-4c09-be09-e6f54cb07f7e"

touch "$STATE_FILE"

# ---------- state helpers ----------
state_has()  { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
state_add()  { state_has "$1" || echo "$1" >> "$STATE_FILE"; }

is_marked()  { state_has "marked:$1"; }
is_skipped() { state_has "skipped:$1"; }

# ---------- status banner ----------
banner() {
    local step_num="$1"
    local step_total="$2"
    local name="$3"
    cat <<EOF
STATUS: IN_PROGRESS
STEP: $step_num/$step_total
NAME: $name

⚠️ Tone: инструкции ниже — для тебя (агента), НЕ для юзера. Юзеру пересказывай
ТОЛЬКО действия («сделай X в браузере») и результат («готово, залогинен»).
НЕ объясняй ему внутренности (cookie SQLite, keychain, pycookiecheat и т.п.) —
это запутывает, пугает и никому не нужно. Короткие, дружелюбные фразы.

EOF
}

done_banner() {
    local mcp_status="ready"
    if is_skipped install_mcp; then
        mcp_status="failed"
    elif ! is_marked mcp_ready; then
        mcp_status="unknown"
    fi

    cat <<EOF
STATUS: DONE

AI Hub установлен. Buildin и Kaiten уже работают в этом же сеансе.

Коннектор Time в ai-hub больше не входит — он переехал в отдельный плагин dodo-time
(MCP, OAuth). Если юзеру нужен Time, скажи поставить его: claude plugin install
dodo-time@dodo-ai-marketplace

Предложи юзеру что-нибудь попробовать прямо сейчас (без перезапуска), например:
  • «покажи мои открытые карточки в Kaiten»
  • «открой страницу Buildin <ссылка> и суммаризируй»
  • «сделай spike по <карточка Kaiten>»

EOF

    case "$mcp_status" in
        ready)
            cat <<EOF
Holst: MCP установлен. Чтобы Holst-скиллы (/ai-hub:holst-export, /ai-hub:holst-write)
заработали, нужно ОДНОКРАТНО перезапустить сессию агента — MCP-серверы подгружаются
только при старте. Скажи юзеру:

  > «Для Holst перезапусти меня: выйди (Ctrl+C / /exit) и запусти снова. После
  >  рестарта первое что нужно — залогиниться в Holst (один раз): скажи «настрой Holst»,
  >  я открою app.holst.so через MCP и ты зайдёшь через Google SSO.»

Если Holst сейчас не нужен — рестарт можно отложить. Buildin/Kaiten работают
без него.
EOF
            ;;
        failed)
            cat <<EOF
Holst: ⚠️ MCP установить не получилось (нет npx / нет claude CLI / permission denied —
смотри лог выше). Из-за этого /ai-hub:holst-export / /ai-hub:holst-write РАБОТАТЬ НЕ
БУДУТ. Остальное (Buildin, Kaiten, spike, discovery, code-review и т.д.) — ок.

Если захочется починить Holst позже — установи Chrome DevTools MCP руками:
  claude mcp add chrome-devtools -- npx chrome-devtools-mcp@latest
(или аналог для своего агента), перезапусти сессию, потом $0 reset и пройди setup заново.
EOF
            ;;
        unknown)
            cat <<EOF
Holst: MCP не проверялся в этом запуске (шаг был отмечен вручную). Если /ai-hub:holst-*
не работают — поставь MCP и перезапусти сессию.
EOF
            ;;
    esac

    cat <<EOF

Если что-то сломается — \`$0 reset\` и пройди setup заново; \`$ENV_MGR check\` покажет
текущий статус переменных.
EOF
}

# ---------- step definitions ----------
# Each step has: check_<N>() returns 0 if done, 1 if TODO.
#                say_<N>() prints instructions (called only when check fails).

TOTAL=8

# Step 0 — миграция .env.local (если есть старый файл)
check_0() { [[ -f "$ROOT_DIR/.env.local" && ! -f "$ROOT_DIR/.env" ]] || return 0; return 1; }
say_0() {
    cat <<EOF
Найден устаревший .env.local. Мигрируй в .env:

  $ENV_MGR migrate

Затем снова: $0 next
EOF
}

# Step 6 (was 1) — Chrome DevTools MCP. Автоматическая установка.
# Buildin уже работает через cookie extraction; MCP нужен ТОЛЬКО для Holst.
# Агент тихо ставит MCP (если нет); при неудаче — помечает как skipped и идёт
# к DONE с предупреждением что Holst работать не будет.
check_1() { is_marked mcp_ready || is_skipped install_mcp; }
say_1() {
    cat <<EOF
Финальный шаг — Chrome DevTools MCP. Автоматический, без вопросов юзеру.

MCP нужен ТОЛЬКО для /ai-hub:holst-export / /ai-hub:holst-write (доски Holst
работают через живую страницу внутри MCP-браузера). Buildin, Kaiten и
вся остальная функциональность УЖЕ работает без MCP.

АЛГОРИТМ:

1. Проверь сначала — может MCP уже работает: попробуй вызвать
   mcp__chrome-devtools__list_pages (или любой другой mcp__chrome-devtools__*).

2a. Если MCP ОТВЕТИЛ — он уже установлен и загружен:
      $0 mark mcp_ready
      $0 next

2b. Если MCP НЕ ОТВЕТИЛ — поставь его автоматически, без вопросов юзеру:

      # Claude Code CLI:
      claude mcp add chrome-devtools -- npx chrome-devtools-mcp@latest

      # Codex / Cursor / Windsurf — добавь запись в их MCP-конфиг:
      { "chrome-devtools": { "command": "npx", "args": ["chrome-devtools-mcp@latest"] } }

    Если УСПЕХ (команда вернула 0 / запись добавилась):
      $0 mark mcp_ready
      $0 next
      (done_banner сам предупредит про рестарт для Holst)

    Если УСТАНОВКА НЕ УДАЛАСЬ (нет npx, нет claude CLI, permission denied и т.п.):
      $0 skip install_mcp
      $0 next
      (done_banner пометит что Holst работать не будет)

3. ЗАПРЕЩЕНО:
   • спрашивать юзера «поставить MCP?» — ставь сам, молча.
   • перезапускать сессию агента во время setup'а — рестарт нужен только ПОСЛЕ
     setup'а и только если юзер захочет Holst. Про это скажет done_banner.
EOF
}

# Step 2 — логин в Buildin
check_2() {
    bash "$SUBTREE_ROOT/integrations/buildin/scripts/buildin-login.sh" check 2>&1 | grep -q '^ok '
}
say_2() {
    cat <<EOF
Логин в Buildin. Primary — автоматический, без MCP, без окон браузера.

USER-FACING (скажи коротко):

  > «Залогинься в Buildin в своём обычном Chrome/Brave/Arc, если ещё не.
  >  Дальше я сам возьму сессию. macOS один раз спросит пароль — жми
  >  **«Разрешить только сейчас»** (не Always Allow).»

ЗАПУСК:
  bash integrations/buildin/scripts/buildin-login.sh cookie

Успех → \`ok <Nickname> (via chrome/Profile N)\` → $0 next.

РАЗРУЛИВАНИЕ ОШИБОК (юзеру говори в user-friendly виде):
  • \`error:no_cookie_found\` → «залогинься в Buildin в Chrome и скажи готово», повтори.
  • \`error:validation_failed\` → «сессия истекла, перелогинься в Buildin», повтори.
  • \`error:pycookiecheat_install_failed\` / только Safari → FALLBACK ниже.

FALLBACK (ручной — только если primary не сработал):

  Скажи юзеру:
  > «Открой https://buildin.ai, залогинься. Нажми F12 → вкладка Console → вставь:
  >    document.cookie.match(/next_auth=([^;]+)/)?.[1]
  >  Скопируй результат и пришли мне.»

  Когда юзер пришлёт:
    bash integrations/buildin/scripts/buildin-login.sh save "<token>"

После: $0 next
EOF
}

# Step 3 — подтянуть конфиг команды из Buildin
check_3() {
    $ENV_MGR has KAITEN_DOMAIN
}
say_3() {
    cat <<EOF
Подтяни URL-ы команды (Kaiten). Юзеру ничего говорить не нужно —
молча сделай шаг и переходи дальше.

Действие:
  bash integrations/buildin/scripts/buildin-pages.sh read $CONFIG_PAGE_ID

Распарси строки \`[A-Z_]+=<значение>\`, сохрани каждую:
  $ENV_MGR set <KEY> "<VALUE>"

Минимум: KAITEN_DOMAIN. BUILDIN_SPACE_ID — опционально.

FALLBACK (если страница 404/403/пустая — команда не использует шаблон):
  Спроси юзера в живом виде, без технических терминов:
  > «Какой у вашей команды домен Kaiten? (пример: yourcompany.kaiten.ru)»
  Сохрани через \`$ENV_MGR set\`.

После: $0 next
EOF
}

# Step 7 (was 5) — Holst login. Опциональный, требует MCP из Step 6.
# Если MCP skipped — Holst auto-skip'ится (cascade).
check_5() { is_marked holst_ready || is_skipped holst || is_skipped install_mcp; }
say_5() {
    cat <<EOF
Holst — финальный опциональный шаг. Единственный в setup'е, где cookie extraction НЕ
помогает: у Holst нет API-токена, скиллы /ai-hub:holst-export/write работают через
живую страницу внутри MCP-браузера (evaluate_script).

MCP из Step 6 должен уже быть установлен и доступен.

Через Chrome DevTools MCP:

  1. navigate_page → https://app.holst.so/
  2. Скажи юзеру: «Залогинься в Holst через Google SSO, скажи "готово" когда будешь
     в рабочем пространстве.»
  3. После подтверждения юзера:
       $0 mark holst_ready
       $0 next

Если юзер не хочет настраивать Holst сейчас:
  $0 skip holst
  $0 next
EOF
}

# Step 5 (was 6) — Kaiten API-token. Опциональный, ручной.
# У Kaiten нет cookie-based API: токен выдаёт только UI в профиле.
# pycookiecheat не поможет. Если юзер не пользуется Kaiten — шаг пропускается.
check_6() {
    is_skipped kaiten_token || is_marked kaiten_token
}
load_env_locally() {
    hub_load_env "$SCRIPT_DIR" || true
}
say_6() {
    local kaiten_domain
    kaiten_domain=$($ENV_MGR get KAITEN_DOMAIN 2>/dev/null || echo '<KAITEN_DOMAIN>')

    cat <<EOF
Kaiten token — опциональный. В отличие от Buildin, у Kaiten нет cookie-based
API, токен выдаётся только через UI профиля. Автоматом его взять нельзя — юзер
должен скопировать сам.

Скажи юзеру (кратко и дружелюбно):

  > «Для работы с Kaiten нужен персональный API-токен — забрать его сам я не могу,
  >  это ручной шаг.
  >
  >  1. Открой https://$kaiten_domain/profile
  >  2. Найди раздел **API Key** (или «API ключ»)
  >  3. Создай токен, скопируй
  >  4. Пришли мне токен прямо сюда — сохраню в .env.
  >
  >  Или открой .env в любом текстовом редакторе и вставь сам в строку
  >  \`KAITEN_TOKEN=...\` — как удобнее.
  >
  >  Если не пользуешься Kaiten — скажи «пропустить», настроим без него.»

ЖДИ ОТВЕТА ЮЗЕРА. НЕ ПРОДОЛЖАЙ ДАЛЬШЕ АВТОМАТИЧЕСКИ.

ЕСЛИ ЮЗЕР ПРИСЛАЛ ТОКЕН (в чате):
  $ENV_MGR set KAITEN_TOKEN "<token>"
  Валидируй: curl с Authorization: Bearer на https://$kaiten_domain/api/latest/users/current
  — 200 → $0 mark kaiten_token && $0 next
  — иначе → попроси пересоздать токен.

ЕСЛИ ЮЗЕР СКАЗАЛ «ГОТОВО» / «СОХРАНИЛ» (положил в .env сам):
  Валидируй тем же curl'ом (прочитай токен из .env).
  — 200 → $0 mark kaiten_token && $0 next
  — иначе → попроси проверить токен.

ЕСЛИ ЮЗЕР СКАЗАЛ «ПРОПУСТИТЬ»:
  $0 skip kaiten_token
  $0 next
EOF
}

# Step 7 — team-config.json
check_7() {
    [[ -f "$ROOT_DIR/team-config.json" ]] || is_skipped team_config
}
say_7() {

    local example=""
    if [[ -f "$ROOT_DIR/team-config.example.json" ]]; then
        example="team-config.example.json"
    elif [[ -f "$ROOT_DIR/integrations/sagos95-ai-hub/team-config.example.json" ]]; then
        example="integrations/sagos95-ai-hub/team-config.example.json"
    fi

    cat <<EOF
Файл team-config.json — ID досок Kaiten, колонок, кастомных свойств.
Без него некоторые скиллы будут каждый раз спрашивать эти ID у юзера.

Шаблон: ${example:-(не найден — см. README)}

Действия:
1. cp $example team-config.json   (если шаблон найден)
2. Спроси юзера: «Заполнить сейчас вместе (я задам по одному вопросу) или отложить?»
   — "вместе": запрашивай по одному полю (kaiten.space_id, kaiten.boards.sprint.id,
     колонки sprint_backlog/in_progress/doing/on_hold/done),
     записывай через jq:

       tmp=\$(mktemp)
       jq '.kaiten.space_id = (\$v | tonumber)' --arg v "\$ANSWER" team-config.json > "\$tmp" \\
         && mv "\$tmp" team-config.json

     В конце: jq . team-config.json
   — "отложить":
       $0 skip team_config

После: $0 next
EOF
}

# ---------- commands ----------
# Step execution order. MCP+Holst are moved to the end because they are
# OPTIONAL (MCP is only needed for Holst). All the zero-MCP logins (Buildin,
# Kaiten) complete first so the setup is usable even if MCP install
# fails or the user doesn't want Holst.
STEP_ORDER=(0 2 3 6 7 1 5)
STEP_NAMES=(
    "migrate_env_local"
    "buildin_login"
    "fetch_team_config"
    "kaiten_token"
    "team_config"
    "install_mcp"
    "holst_login"
)
STEP_NOTES=(
    ""
    ""
    ""
    "(optional — skip if not using Kaiten)"
    ""
    "(optional — only for Holst)"
    "(optional — requires MCP)"
)

cmd_next() {
    # First unfinished step in STEP_ORDER → print its instructions.
    local total=${#STEP_ORDER[@]}
    local i
    for i in "${!STEP_ORDER[@]}"; do
        local step="${STEP_ORDER[$i]}"
        if ! "check_$step"; then
            banner $((i+1)) $total "${STEP_NAMES[$i]}"
            "say_$step"
            return 0
        fi
    done
    done_banner
}

cmd_status() {
    echo "=== AI Hub Setup Status ==="
    local i
    for i in "${!STEP_ORDER[@]}"; do
        local step="${STEP_ORDER[$i]}"
        local name="${STEP_NAMES[$i]}"
        local note="${STEP_NOTES[$i]}"
        local mark="[ ]"
        if "check_$step"; then mark="[x]"; fi
        printf "  %s %d. %s %s\n" "$mark" "$((i+1))" "$name" "$note"
    done
}

cmd_mark() {
    local key="$1"
    if [[ -z "$key" ]]; then
        echo "Usage: $0 mark <step_name>" >&2
        exit 1
    fi
    state_add "marked:$key"
    echo "marked:$key"
}

cmd_skip() {
    local key="$1"
    if [[ -z "$key" ]]; then
        echo "Usage: $0 skip <step_name>" >&2
        exit 1
    fi
    state_add "skipped:$key"
    echo "skipped:$key"
}

cmd_reset() {
    > "$STATE_FILE"
    echo "ok: state cleared ($STATE_FILE)"
    echo "Note: .env values не трогались. Чтобы сбросить токены — редактируй .env вручную."
}

COMMAND="${1:-next}"
shift 2>/dev/null || true

case "$COMMAND" in
    next)    cmd_next ;;
    status)  cmd_status ;;
    mark)    cmd_mark "$1" ;;
    skip)    cmd_skip "$1" ;;
    reset)   cmd_reset ;;
    help|-h|--help|*)
        cat <<EOF
setup.sh — AI Hub setup dispatcher

Usage:
  $0 next                 — print current step + instructions (default)
  $0 status               — list all steps with [x]/[ ] markers
  $0 mark <step_name>     — mark step done (for steps without auto-check)
  $0 skip <step_name>     — mark step skipped by user
  $0 reset                — clear state file (re-run from scratch)

Steps: mcp_ready, buildin_login, fetch_team_config, holst_login/holst,
       kaiten_token, team_config

Agent contract: call \`$0 next\` in a loop until stdout's first line is "STATUS: DONE".
EOF
        ;;
esac
