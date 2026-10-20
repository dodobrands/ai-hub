#!/bin/bash
# Buildin Comments — комментарии через UI API: треды на фразах блоков, ответы,
# резолв и откат. Обычно вызывается через buildin-pages.sh — тот передаёт сюда
# команды комментариев как есть, поэтому оба вызова равнозначны:
#   ./buildin-pages.sh comment <args...>
#   ./buildin-comments.sh comment <args...>
#
# Commands:
#   comments <page_id|url[#block_id]> [block_id] — комментарии страницы или конкретного блока
#                                                  (URL с якорем #block-uuid фильтрует по блоку)
#   comment <page_id|url[#block_id]> [block_id] <anchor> <text>
#           [--dry-run] [--occurrence=N] [--rollback-out=<path>] [--mention=<user_uuid>]...
#                                                — создать комментарий к фразе <anchor> внутри блока
#                                                  <anchor>/<text>: строка, «@путь» — файл, «-» — stdin
#                                                  («@@текст» — литеральный «@текст»; значение с ведущими
#                                                   дефисами — после разделителя «--»)
#                                                  якорь должен быть однозначен: несколько вхождений —
#                                                  отказ, нужное выбирается через --occurrence=N
#                                                  только прозаические блоки (абзац, списки, заголовок,
#                                                  цитата, callout) — у картинки, таблицы и кода
#                                                  подсветки не будет, поэтому отказ
#                                                  дату и инлайн-формулу внутри блока — только
#                                                  целиком: разрез формулу ломает
#                                                  --mention — @-упоминание участника в начале текста
#                                                  (можно несколько; uuid сверяется с участниками)
#   comment-reply <page_id|url> <discussion_id> <text> [--dry-run] [--rollback-out=<path>]
#                 [--mention=<user_uuid>]...
#                                                — ответить в тред; <text> и --mention — как у comment;
#                                                  в закрытый тред — отказ, сначала comment-unresolve
#   comment-resolve <page_id|url> <discussion_id> [--dry-run]
#                                                — закрыть тред (резолв); уже закрытый — без записи
#   comment-unresolve <page_id|url> <discussion_id> [--dry-run]
#                                                — открыть закрытый тред заново
#   comment-rollback <file> [--narrow] [--dry-run]
#                                                — применить файл отката comment/comment-reply;
#                                                  файл становится <file>.applied, повтор — отказ;
#                                                  блок меняли после комментария — полный откат
#                                                  отвергается, --narrow снимает только свой тред;
#                                                  в треде чужой ответ или записи не ваши — отказ;
#                                                  ваши ответы в треде — тоже: сначала откатите их
#   members <page_id|url>                        — участники пространства страницы: «<uuid>  <nickname>»,
#                                                  uuid — для --mention

# pipefail обязателен вместе с JSON-отказом из buildin.sh: без него сбой клиента
# в конвейере `buildin ... | python3` маскируется нулевым статусом питона,
# который теперь честно разбирает тело ошибки и завершается успешно.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=buildin-lib.sh
source "$SCRIPT_DIR/buildin-lib.sh"

# Значение текстового аргумента: «@путь» — содержимое файла, «-» — stdin,
# иначе строка как есть. Длинный текст комментария в bash-строке — ад
# экранирования, поэтому у него есть файловая форма.
#
# Сигил «@» экранируется удвоением: «@@текст» — литеральный «@текст». Без
# этого комментарий, начинающийся с упоминания, передать было бы нечем: он
# молча уезжал бы в ветку «файл». У «-» своего escape нет намеренно — «--»
# занято разделителем конца опций; значение, равное одному дефису, берётся
# из файла или stdin.
read_arg_text() {
    local value="$1"
    case "$value" in
        -)   cat ;;
        @@*) printf '%s' "${value#@}" ;;
        @*)  local file="${value#@}"
             [[ -f "$file" ]] || {
                 echo "Error: значение начинается с «@», поэтому разобрано как путь к файлу: $file" >&2
                 echo "       файл не найден. Нужен литеральный текст с «@» — удвойте сигил: @@${file}" >&2
                 # «@имя» — естественная попытка позвать человека, а «@@имя» даст
                 # обычный текст без уведомления: агент решил бы, что позвал.
                 echo "       Чтобы позвать человека, нужен --mention=<uuid>; uuid даёт buildin-pages.sh members <страница>." >&2
                 echo "       «@@имя» даст обычный текст без упоминания и уведомления." >&2
                 exit 1
             }
             cat "$file" ;;
        *)   printf '%s' "$value" ;;
    esac
}

# Разобрать идентификаторы страницы и блока из общей формы «<uuid|url[#block]>
# [block_id]». Выставляет PAGE_ID и BLOCK_ID. Один разбор на `comments` и
# `comment`: две копии пришлось бы держать в синхроне руками.
parse_page_and_block_id() {
    local input="$1"
    local maybe_block="${2:-}"

    # Полный URL — buildin.ai/<space>/<page>: страница это последний UUID до «#»
    # (как в parse_id), блок — из якоря после «#».
    PAGE_ID=$(echo "${input%%#*}" | grep -oE "$UUID_RE" | tail -1 || true)
    [[ -z "$PAGE_ID" ]] && { echo "Error: no UUID found in '$input'" >&2; exit 1; }

    BLOCK_ID="$maybe_block"
    if [[ -z "$BLOCK_ID" && "$input" == *"#"* ]]; then
        BLOCK_ID=$(echo "${input#*#}" | grep -oE "$UUID_RE" | head -1 || true)
    fi
}

# Флаги команд комментариев — один разбор на comment, comment-reply и
# comment-resolve/unresolve: копии цикла разошлись бы молча. $1 — разрешённые
# флаги через пробел, дальше аргументы команды. Выставляет DRY_RUN,
# ROLLBACK_OUT, OCCURRENCE, NARROW, массив MENTIONS и массив ARGS с
# позиционными.
#
# Неизвестные «--»-токены отвергаются, а не сваливаются в позиционные: иначе
# опечатка «--dryrun» молча делает боевую запись вместо превью. Флаг, который
# команде не положен, отвергается так же: у резолва нет файла отката, и
# молча принятый --rollback-out обещал бы то, чего нет.
parse_comment_flags() {
    local allowed=" $1 " flag
    shift
    DRY_RUN=""
    ROLLBACK_OUT=""
    OCCURRENCE=""
    NARROW=""
    MENTIONS=()
    ARGS=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --?* ]]; then
            flag="${1%%=*}"
            [[ "$allowed" == *" ${flag#--} "* ]] || {
                echo "Error: неизвестный флаг: $1" >&2; echo "$USAGE" >&2; exit 1; }
        fi
        case "$1" in
            --dry-run)         DRY_RUN=1 ;;
            --narrow)          NARROW=1 ;;
            --occurrence=*)    OCCURRENCE="${1#*=}" ;;
            --occurrence)      shift; OCCURRENCE="${1:-}"
                               [[ -n "$OCCURRENCE" && "$OCCURRENCE" != --* ]] || {
                                   echo "Error: --occurrence без значения" >&2; exit 1; } ;;
            --rollback-out=*)  ROLLBACK_OUT="${1#*=}" ;;
            --rollback-out)    shift; ROLLBACK_OUT="${1:-}"
                               [[ -n "$ROLLBACK_OUT" && "$ROLLBACK_OUT" != --* ]] || {
                                   echo "Error: --rollback-out без значения" >&2; exit 1; } ;;
            --mention=*)       [[ -n "${1#*=}" ]] || { echo "Error: --mention без значения" >&2; exit 1; }
                               MENTIONS+=("${1#*=}") ;;
            --mention)         shift
                               [[ -n "${1:-}" && "${1:-}" != --* ]] || {
                                   echo "Error: --mention без значения" >&2; exit 1; }
                               MENTIONS+=("$1") ;;
            --)                shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done; break ;;
            --*)               echo "Error: неизвестный флаг: $1" >&2; echo "$USAGE" >&2; exit 1 ;;
            *)                 ARGS+=("$1") ;;
        esac
        shift || true
    done
}

# Аргументы билдера для @-упоминаний: файл участников пространства (для
# сверки uuid) и сами --mention. Пространство берётся у блока или треда из
# уже прочитанного /api/docs. Если их на странице нет, участников не
# спрашиваем: об отсутствии скажет билдер, и это сообщение точнее.
# Выставляет массив MENTION_ARGS и MEMBERS_FILE — его удаляет trap команды.
# $1 — файл /api/docs, $2 — id блока или треда.
mention_args() {
    local space m
    MENTION_ARGS=()
    [[ ${#MENTIONS[@]} -gt 0 ]] || return 0
    MEMBERS_FILE=$(mktemp)
    space=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8')).get('data') or {}
rec = (data.get('blocks') or {}).get(sys.argv[2]) or (data.get('discussions') or {}).get(sys.argv[2]) or {}
print(rec.get('spaceId', ''))
" "$1" "$2")
    if [[ -z "$space" ]]; then
        echo '{}' > "$MEMBERS_FILE"
    elif ! buildin GET "/api/spaces/$space/members" > "$MEMBERS_FILE"; then
        echo "Error: не удалось получить участников пространства — упоминание не проверить, запись отменена." >&2
        exit 1
    fi
    MENTION_ARGS+=("--members=$MEMBERS_FILE")
    for m in "${MENTIONS[@]}"; do
        MENTION_ARGS+=("--mention=$m")
    done
}

# Файл отката — готовое тело запроса. Один на comment и comment-reply: права
# и дефолтное имя у двух копий разошлись бы молча. $1 — spaceId, $2 — файл с
# операциями отката, $3 (необязательный) — файл сверки для ключа check.
# Путь — из ROLLBACK_OUT, а без него — свежий mktemp.
write_rollback() {
    local body
    [[ -n "$ROLLBACK_OUT" ]] || ROLLBACK_OUT=$(mktemp "${TMPDIR:-/tmp}/buildin-rollback-XXXXXX")
    body=$(tx_body "$1" "$(cat "$2")") || return
    if [[ -n "${3:-}" ]]; then
        # Сверка едет в том же файле: отдельный файл рядом легко потерять, и
        # откат тогда молча шёл бы без проверки свежести.
        body=$(python3 -c "
import json, sys
body = json.loads(sys.argv[1])
body['check'] = json.load(open(sys.argv[2], encoding='utf-8'))
print(json.dumps(body))
" "$body" "$3") || return
    fi
    # umask 077 на подоболочку: дефолтный путь создаёт mktemp с правами 0600,
    # а перенаправление по --rollback-out дало бы права по umask, хотя в
    # файле лежит полный текст блока. У уже существующего файла права свои.
    (umask 077; printf '%s\n' "$body" > "$ROLLBACK_OUT")
    echo "Откат: $ROLLBACK_OUT" >&2
}

# Запись с проверкой после неё — одна на ответ, резолв и откат: у копий
# разошлись бы коды выхода, а агент решает по ним, можно ли повторять.
# POST, перечитать страницу, вердикт билдера. Возвращается только при «ok»,
# иначе выход: 2 — исход неизвестен, 1 — транзакция не легла, повтор безопасен.
#   $1 spaceId, $2 операции, $3 страница, $4 файл под перечитанную страницу,
#   $5 что пишем (для сообщений), $6 что делать при неизвестном исходе,
#   $7 что сказать, если транзакция не легла; дальше — режим вердикта билдера
#   и его аргументы после перечитанной страницы.
write_verified() {
    local space=$1 ops=$2 page=$3 doc=$4 what=$5 unknown=$6 not_applied=$7 mode=$8 status
    shift 8
    if ! transaction "$space" "$ops" > /dev/null; then
        echo "Error: исход записи неизвестен ($what)." >&2
        echo "       $unknown" >&2
        exit 2
    fi
    if ! buildin GET "/api/docs/$page" > "$doc"; then
        echo "Error: транзакция отправлена ($what), но проверить результат не удалось." >&2
        echo "       $unknown" >&2
        exit 2
    fi
    # Упавший вердикт — тоже «исход неизвестен»: POST уже ушёл, а set -e вышел
    # бы с кодом 1 («не легло, повтор безопасен») — повтор задвоил бы запись.
    status=$(python3 "$SCRIPT_DIR/buildin-comment.py" "$mode" -- "$doc" "$@") || status=""
    case "$status" in
        ok)
            return 0
            ;;
        not-applied)
            echo "Error: транзакция не применилась ($what) — $not_applied" >&2
            exit 1
            ;;
        *)
            echo "Error: проверочное чтение не подтвердило запись ($what) — исход неизвестен." >&2
            echo "       $unknown" >&2
            exit 2
            ;;
    esac
}

# Превью операций для --dry-run — одна печать на все команды, иначе у копий
# разъезжается вид: у отката кириллица уже шла как \uXXXX. В буфер напрямую:
# печать не-ASCII через stdout падает при не-UTF-8 кодировке вывода. $1 (необязательный) —
# ключ, под которым операции лежат во входном JSON.
print_ops() {
    python3 -c "
import json, sys
ops = json.load(sys.stdin)
if len(sys.argv) > 1:
    ops = ops[sys.argv[1]]
sys.stdout.buffer.write(json.dumps(ops, ensure_ascii=False, indent=2).encode('utf-8') + b'\n')
" "$@"
}

# Пространство страницы по уже прочитанному /api/docs: у всех блоков страницы
# оно одно. Пусто — блоков в ответе нет (конверт ошибки или чужая страница).
doc_space_id() {
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1])).get('data') or {}
blocks = data.get('blocks') or {}
print(next(iter(blocks.values()), {}).get('spaceId', ''))
" "$1"
}

# Список команд для справки — одна копия на оба скрипта: buildin-pages.sh
# берёт его отсюда подкомандой commands.
print_commands() {
    echo "  comments <id|url[#block_id]> [block_id]  — комментарии страницы или блока (якорь #block-uuid фильтрует)"
    echo "  comment <id|url[#block_id]> [block_id] <anchor> <text>"
    echo "          [--dry-run] [--occurrence=N] [--rollback-out=<path>] [--mention=<user_uuid>]..."
    echo "                                           — комментарий к фразе <anchor> внутри блока"
    echo "                                             <anchor>/<text>: строка, @путь — файл, - — stdin"
    echo "                                             (@@текст — литеральный @текст; значение с ведущими"
    echo "                                              дефисами — после разделителя --)"
    echo "                                             неоднозначный якорь — отказ, см. --occurrence=N"
    echo "                                             только прозаические блоки; картинка/таблица/код — отказ"
    echo "                                             дату и инлайн-формулу — только целиком"
    echo "                                             stdout: discussion: <uuid>, rollback: <путь>"
    echo "  comment-reply <id|url> <discussion_id> <text> [--dry-run] [--rollback-out=<path>]"
    echo "          [--mention=<user_uuid>]...       — ответ в тред; в закрытый — отказ, сначала comment-unresolve"
    echo "                                             stdout: comment: <uuid>, rollback: <путь>"
    echo "  comment-resolve <id|url> <discussion_id> [--dry-run]   — закрыть тред"
    echo "  comment-unresolve <id|url> <discussion_id> [--dry-run] — открыть тред заново"
    echo "                                             stdout: discussion: <uuid>, status: changed|noop"
    echo "  comment-rollback <file> [--narrow] [--dry-run]"
    echo "                                           — откат comment/comment-reply по файлу из «rollback: <путь>»;"
    echo "                                             чужие ответы в треде или записи не ваши — отказ;"
    echo "                                             ваши ответы в треде — тоже: сначала откатите их;"
    echo "                                             блок меняли — полный откат отвергнут, --narrow снимает тред"
    echo "  members <id|url>                         — участники пространства: «<uuid>  <nickname>» для --mention"
    echo "                                             (упоминание — только людей и только в начале текста)"
}

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    comments)
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "Usage: comments <page_id|url[#block_id]> [block_id]" >&2; exit 1; }
        parse_page_and_block_id "$INPUT" "${2:-}"

        DOC_FILE=$(mktemp)
        trap 'rm -f "$DOC_FILE"' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        SPACE_ID=$(doc_space_id "$DOC_FILE")

        # Ники, ссылки на страницы и даты печатает общий с read модуль; участников
        # он спрашивает сам и лениво, без доступа к ним печатает короткие id.
        python3 -c "
import json, sys
from datetime import datetime

doc_file, page_id, block_id, space_id, script_dir = sys.argv[1:6]
sys.path.insert(0, script_dir)
from buildin_segments import Inline, MEMBERS_NOTE

data = json.load(open(doc_file)).get('data', {})
blocks = data.get('blocks', {})
discussions = data.get('discussions', {})
comments = data.get('comments', {})
inline = Inline(blocks, space_id, script_dir + '/buildin.sh')
name = inline.name

def rt(segments):
    return inline.text(segments).strip()

def ts(ms):
    return datetime.fromtimestamp(ms / 1000).strftime('%Y-%m-%d %H:%M') if ms else '?'

found = 0
for did, disc in discussions.items():
    parent = disc.get('parentId', '')
    if block_id and parent != block_id:
        continue
    block = blocks.get(parent, {})
    block_title = block.get('title') or rt(block.get('data', {}).get('segments'))
    context = rt(disc.get('context'))
    status = 'resolved' if disc.get('resolved') else 'open'
    found += 1
    print(f'## Блок {parent}')
    if block_title:
        print(f'Текст блока: {block_title}')
    if context and context != block_title:
        print(f'Выделено: «{context}»')
    print(f'Тред {did} [{status}]:')
    for cid in disc.get('comments', []):
        c = comments.get(cid, {})
        body = rt(c.get('text')) or '(без текста)'
        print(f'- {name(c.get(\"createdBy\", \"\"))} ({ts(c.get(\"createdAt\"))}): {body}')
    print()

if not found:
    where = f'блока {block_id}' if block_id else f'страницы {page_id}'
    print(f'Комментариев у {where} нет.')
if inline.members_unavailable:
    print(MEMBERS_NOTE)
" "$DOC_FILE" "$PAGE_ID" "$BLOCK_ID" "$SPACE_ID" "$SCRIPT_DIR"
        ;;

    comment)
        USAGE='Usage: comment <page_id|url[#block_id]> [block_id] <anchor> <text> [--dry-run] [--occurrence=N] [--rollback-out=<path>]
                [--mention=<user_uuid>]...
  <anchor>, <text>: строка, «@путь» — содержимое файла, «-» — stdin
                    («@@текст» — литеральный «@текст»; значение с ведущими
                     дефисами — после разделителя «--»)
  блок: только прозаический (абзац, списки, todo, toggle, заголовок, цитата,
        callout) — картинка, таблица, код и заголовок страницы отвергаются
  дату и инлайн-формулу внутри блока — только целиком: якорь «‣» у даты,
        исходник LaTeX у формулы'
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "$USAGE" >&2; exit 1; }
        shift
        parse_comment_flags "dry-run occurrence rollback-out mention" "$@"

        parse_page_and_block_id "$INPUT"
        # Первый позиционный считаем блоком, только если он целиком UUID: якорь
        # такой формы был бы патологией, а обычная фраза ею не притворится.
        if [[ "${ARGS[0]:-}" =~ ^$UUID_RE$ ]]; then
            BLOCK_ID="${ARGS[0]}"
            ARGS=("${ARGS[@]:1}")
        fi

        [[ -z "$BLOCK_ID" ]] && { echo "Error: не указан block_id (аргументом или якорем #block-uuid в URL)" >&2; echo "$USAGE" >&2; exit 1; }
        [[ ${#ARGS[@]} -eq 2 ]] || { echo "Error: ожидались ровно <anchor> и <text>, получено: ${#ARGS[@]}" >&2; echo "$USAGE" >&2; exit 1; }
        [[ -z "$OCCURRENCE" || "$OCCURRENCE" =~ ^[1-9][0-9]*$ ]] || { echo "Error: --occurrence ожидает целое число >= 1, получено: $OCCURRENCE" >&2; exit 1; }
        [[ "${ARGS[0]}" == "-" && "${ARGS[1]}" == "-" ]] && { echo "Error: stdin можно отдать только одному аргументу" >&2; exit 1; }

        ANCHOR=$(read_arg_text "${ARGS[0]}")
        TEXT=$(read_arg_text "${ARGS[1]}")
        # Проверяем РАЗВЁРНУТЫЕ значения: пустой файл и пустой stdin дают непустой
        # сигил, и тред с пустым сообщением уходил бы в живой документ.
        [[ -z "$ANCHOR" ]] && { echo "Error: якорь пустой" >&2; exit 1; }
        [[ -z "$TEXT" ]] && { echo "Error: текст комментария пустой" >&2; exit 1; }

        DOC_FILE=$(mktemp)
        FRESH_FILE=""
        OPS_DIR=""
        MEMBERS_FILE=""
        trap 'rm -rf "$DOC_FILE" ${FRESH_FILE:+"$FRESH_FILE"} ${OPS_DIR:+"$OPS_DIR"} ${MEMBERS_FILE:+"$MEMBERS_FILE"}' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")
        mention_args "$DOC_FILE" "$BLOCK_ID"

        # «--» обязателен: без него якорь или текст с ведущими дефисами билдер
        # примет за флаг, и файловая форма ввода от этого не спасает.
        BUILT=$(python3 "$SCRIPT_DIR/buildin-comment.py" \
            ${OCCURRENCE:+--occurrence="$OCCURRENCE"} ${MENTION_ARGS[@]+"${MENTION_ARGS[@]}"} --page="$PAGE_ID" -- \
            "$DOC_FILE" "$BLOCK_ID" "$ANCHOR" "$TEXT" "$NOW" "$USER_ID")

        if [[ -n "$DRY_RUN" ]]; then
            # Превью не трогает ни сеть, ни диск: файл отката по дефолтному пути
            # затёр бы откат предыдущего РЕАЛЬНОГО комментария.
            echo "$BUILT" | print_ops ops
            exit 0
        fi

        # spaceId берём у самого блока — тот же, что уходит в args операций
        SPACE_ID=$(python3 -c "
import json, sys
# encoding обязателен: под не-UTF-8 локалью open() берёт ASCII и падает
blocks = (json.load(open(sys.argv[1], encoding='utf-8')).get('data') or {}).get('blocks') or {}
print((blocks.get(sys.argv[2]) or {}).get('spaceId', ''))
" "$DOC_FILE" "$BLOCK_ID")

        # Оптимистичная проверка. Операции узкие, поэтому чужие ключи data и
        # чужие треды в списке переживают запись, а вот segments уходят целиком
        # из снапшота: правка блока между GET и POST потеряла бы чужую подсветку.
        FRESH_FILE=$(mktemp)
        buildin GET "/api/docs/$PAGE_ID" > "$FRESH_FILE"
        python3 -c "
import json, sys
def segs(path):
    blocks = (json.load(open(path, encoding='utf-8')).get('data') or {}).get('blocks') or {}
    return ((blocks.get(sys.argv[3]) or {}).get('data') or {}).get('segments')
if segs(sys.argv[1]) != segs(sys.argv[2]):
    sys.exit('Error: блок изменился, пока готовился комментарий — запись отменена.\n'
             '       Повторите команду: она возьмёт свежее состояние блока.')
" "$DOC_FILE" "$FRESH_FILE" "$BLOCK_ID"

        OPS_DIR=$(mktemp -d)
        DISCUSSION=$(echo "$BUILT" | python3 -c "
import json, os, sys
out = sys.argv[1]
built = json.load(sys.stdin)
for key in ('ops', 'rollback', 'rollback_records', 'check'):
    open(os.path.join(out, key + '.json'), 'w').write(json.dumps(built[key]))
print(built['discussion'])
" "$OPS_DIR")
        write_rollback "$SPACE_ID" "$OPS_DIR/rollback.json" "$OPS_DIR/check.json"

        # О созданном треде сообщаем ДО записи: id известен сразу после билдера,
        # а если POST оборвётся, узнать его будет неоткуда — curl в buildin.sh
        # идёт без -S и на обрыве молчит. Повтор вслепую повесил бы второй тред
        # на ту же фразу: видимый текст блока после разреза не меняется.
        echo "discussion: $DISCUSSION" >&2
        if ! transaction "$SPACE_ID" "$(cat "$OPS_DIR/ops.json")" > /dev/null; then
            echo "Error: исход записи неизвестен (discussion: $DISCUSSION)." >&2
            echo "       Не повторяйте команду вслепую — сначала посмотрите блок на странице." >&2
            exit 2
        fi

        # Проверка ПОСЛЕ записи. Проверка до неё сужает окно, но не закрывает:
        # несколько процессов успевают сделать оба GET раньше первого POST, и
        # тогда побеждает последний писавший segments.
        # FRESH_FILE переиспользуем: второй mktemp оставлял первый файл с полной
        # копией страницы в $TMPDIR навсегда — trap раскрывает переменную на
        # выходе и удалил бы только последний.
        if ! buildin GET "/api/docs/$PAGE_ID" > "$FRESH_FILE"; then
            echo "Error: транзакция отправлена (discussion: $DISCUSSION), но проверить результат не удалось." >&2
            echo "       Не повторяйте команду вслепую — сначала посмотрите блок на странице." >&2
            exit 2
        fi

        # Упавший вердикт — «исход неизвестен», как у write_verified: POST уже ушёл.
        VERDICT=$(python3 "$SCRIPT_DIR/buildin-comment.py" --verdict -- \
            "$DOC_FILE" "$FRESH_FILE" "$BLOCK_ID" "$DISCUSSION") || VERDICT=""
        STATUS=$(echo "$VERDICT" | sed -n 1p)
        LOST=$(echo "$VERDICT" | sed -n 2p)

        # Успех — только явный ok: пустой статус упавшего вердикта иначе прошёл
        # бы мимо всех веток и стал бы успехом.
        case "$STATUS" in
            ok)
                ;;
            not-applied)
                # Нашего треда нет даже в списке блока. listAfter аддитивен, и
                # конкурент наш id из списка не убирает — значит транзакция не
                # легла: создавать было нечего, повтор безопасен.
                echo "Error: транзакция не применилась — треда $DISCUSSION нет в списке блока." >&2
                echo "       Ничего создано не было, повтор безопасен." >&2
                echo "       Файл отката $ROLLBACK_OUT применять не надо." >&2
                exit 1
                ;;
            lost-ours)
                # Блок переписали поверх нас. Наших сегментов там уже нет, поэтому
                # полный откат применять НЕЛЬЗЯ — он вернул бы наш снапшот и стёр
                # подсветку победителя. Предупреждаем ДО самоочистки: её сбой не
                # должен проглотить этот запрет, иначе пользователь применит
                # полный откат, увидев только путь к нему.
                echo "Error: тред создан, но подсветка не закрепилась — блок перезаписали параллельно." >&2
                echo "       Файл отката $ROLLBACK_OUT применять НЕ надо — он вернёт устаревшие сегменты." >&2
                if transaction "$SPACE_ID" "$(cat "$OPS_DIR/rollback_records.json")" > /dev/null; then
                    echo "       Тред $DISCUSSION снят: убран из блока и погашен. Чужие правки не тронуты." >&2
                    echo "       Повторите команду: она возьмёт свежее состояние блока." >&2
                    exit 1
                fi
                echo "       Снять тред не удалось: $DISCUSSION остался в списке блока без подсветки." >&2
                echo "       Снимите его вручную или повторите команду и уберите лишний тред." >&2
                exit 2
                ;;
            *)
                # unverified (блока нет в ответе: конверт ошибки, чужая страница,
                # обрезанное тело) или вердикт не дал статуса. Об исходе записи
                # ничего не известно, поэтому ничего не гасим — самоочистка тут
                # снимала бы, возможно, успешный тред.
                echo "Error: проверочное чтение не вернуло блок — исход записи неизвестен." >&2
                echo "       Тред: $DISCUSSION. Не повторяйте команду вслепую — посмотрите блок на странице." >&2
                exit 2
                ;;
        esac

        # Именно if, а не «[[ … ]] && { … }»: это последняя команда ветки, и её
        # статус стал бы кодом выхода всей команды — пустой список превращался
        # бы в rc=1 на совершенно успешной записи.
        # Результат — в stdout, как id новой страницы у create: обёртке и агенту
        # естественно искать его там. Ранняя строка в stderr остаётся страховкой
        # на случай обрыва до этого места. Путь к откату — там же: выковыривать
        # его из stderr агенту приходилось бы среди предупреждений.
        echo "discussion: $DISCUSSION"
        echo "rollback: $ROLLBACK_OUT"

        if [[ -n "$LOST" ]]; then
            echo "ВНИМАНИЕ: параллельная запись лишила подсветки чужие треды: ${LOST// /, }" >&2
            echo "          Они остались в списке блока, но на странице их не видно." >&2
            echo "          Текст цел — посмотреть: buildin-pages.sh comments $PAGE_ID $BLOCK_ID" >&2
            echo "          Если это тред другого запуска comment, упавшего с ошибкой про" >&2
            echo "          подсветку, — он снимется сам и будет повторён, реагировать не надо." >&2
            echo "          Иначе вернуть подсветку можно только новым комментарием: сама" >&2
            echo "          команда не угадывает, к какой фразе чужой тред был привязан." >&2
        fi
        ;;

    comment-reply)
        USAGE='Usage: comment-reply <page_id|url> <discussion_id> <text> [--dry-run] [--rollback-out=<path>]
                      [--mention=<user_uuid>]...
  <discussion_id>: строка «Тред <uuid>» в выводе comments; страница — та, где висит тред
  <text>: строка, «@путь» — содержимое файла, «-» — stdin
          («@@текст» — литеральный «@текст»; значение с ведущими
           дефисами — после разделителя «--»)
  в закрытый тред ответ не пишется: сначала comment-unresolve'
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "$USAGE" >&2; exit 1; }
        shift
        parse_comment_flags "dry-run rollback-out mention" "$@"

        parse_page_and_block_id "$INPUT"
        [[ ${#ARGS[@]} -eq 2 ]] || { echo "Error: ожидались ровно <discussion_id> и <text>, получено: ${#ARGS[@]}" >&2; echo "$USAGE" >&2; exit 1; }
        DISCUSSION="${ARGS[0]}"
        [[ "$DISCUSSION" =~ ^$UUID_RE$ ]] || { echo "Error: <discussion_id> — не UUID: $DISCUSSION" >&2; echo "$USAGE" >&2; exit 1; }
        TEXT=$(read_arg_text "${ARGS[1]}")
        # Проверяем РАЗВЁРНУТОЕ значение: пустой файл и пустой stdin дают
        # непустой сигил, и ответ без текста ушёл бы в живой тред.
        [[ -z "$TEXT" ]] && { echo "Error: текст ответа пустой" >&2; exit 1; }

        DOC_FILE=$(mktemp)
        OPS_DIR=""
        MEMBERS_FILE=""
        trap 'rm -rf "$DOC_FILE" ${OPS_DIR:+"$OPS_DIR"} ${MEMBERS_FILE:+"$MEMBERS_FILE"}' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(get_user_id)
        mention_args "$DOC_FILE" "$DISCUSSION"

        # «--» обязателен: текст с ведущими дефисами билдер иначе принял бы за флаг.
        BUILT=$(python3 "$SCRIPT_DIR/buildin-comment.py" --reply ${MENTION_ARGS[@]+"${MENTION_ARGS[@]}"} \
            --page="$PAGE_ID" -- "$DOC_FILE" "$DISCUSSION" "$TEXT" "$NOW" "$USER_ID")

        if [[ -n "$DRY_RUN" ]]; then
            # Превью не пишет и файл отката: он затёр бы откат предыдущей
            # реальной записи.
            echo "$BUILT" | print_ops ops
            exit 0
        fi

        OPS_DIR=$(mktemp -d)
        COMMENT_ID=$(echo "$BUILT" | python3 -c "
import json, os, sys
out = sys.argv[1]
built = json.load(sys.stdin)
for key in ('ops', 'rollback', 'check'):
    open(os.path.join(out, key + '.json'), 'w').write(json.dumps(built[key]))
open(os.path.join(out, 'space'), 'w').write(built['space'])
print(built['comment'])
" "$OPS_DIR")
        SPACE_ID=$(cat "$OPS_DIR/space")
        write_rollback "$SPACE_ID" "$OPS_DIR/rollback.json" "$OPS_DIR/check.json"

        # id ответа — до записи, по той же причине, что у comment: если POST
        # оборвётся, узнать его будет неоткуда, а слепой повтор задвоит ответ.
        echo "comment: $COMMENT_ID" >&2
        write_verified "$SPACE_ID" "$(cat "$OPS_DIR/ops.json")" "$PAGE_ID" "$DOC_FILE" "comment: $COMMENT_ID" \
            "Не повторяйте команду вслепую — сначала посмотрите тред: buildin-pages.sh comments $PAGE_ID" \
            "ответа в треде нет, ничего не создано, повтор безопасен. Файл отката $ROLLBACK_OUT применять не надо." \
            --reply-verdict "$DISCUSSION" "$COMMENT_ID"
        echo "comment: $COMMENT_ID"
        echo "rollback: $ROLLBACK_OUT"
        ;;

    comment-resolve|comment-unresolve)
        USAGE="Usage: $COMMAND <page_id|url> <discussion_id> [--dry-run]
  <discussion_id>: строка «Тред <uuid>» в выводе comments; страница — та, где висит тред
  тред уже в нужном состоянии — записи нет, выход 0"
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "$USAGE" >&2; exit 1; }
        shift
        parse_comment_flags "dry-run" "$@"

        parse_page_and_block_id "$INPUT"
        [[ ${#ARGS[@]} -eq 1 ]] || { echo "Error: ожидался ровно <discussion_id>, получено: ${#ARGS[@]}" >&2; echo "$USAGE" >&2; exit 1; }
        DISCUSSION="${ARGS[0]}"
        [[ "$DISCUSSION" =~ ^$UUID_RE$ ]] || { echo "Error: <discussion_id> — не UUID: $DISCUSSION" >&2; echo "$USAGE" >&2; exit 1; }
        if [[ "$COMMAND" == comment-resolve ]]; then
            TARGET=true; STATE="закрыт"
        else
            TARGET=false; STATE="открыт"
        fi

        DOC_FILE=$(mktemp)
        trap 'rm -f "$DOC_FILE"' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        BUILT=$(python3 "$SCRIPT_DIR/buildin-comment.py" --resolve="$TARGET" -- "$DOC_FILE" "$DISCUSSION")
        OPS=$(echo "$BUILT" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['ops']))")
        SPACE_ID=$(echo "$BUILT" | python3 -c "import json, sys; print(json.load(sys.stdin)['space'])")

        # Строка status отличает «записал» от «уже было так»: код выхода у них
        # один, а агенту разница нужна, например чтобы не рапортовать о
        # закрытии треда, который закрыл кто-то другой.
        if [[ "$OPS" == "[]" ]]; then
            echo "Тред $DISCUSSION уже $STATE — записи не было." >&2
            echo "discussion: $DISCUSSION"
            echo "status: noop"
            exit 0
        fi
        if [[ -n "$DRY_RUN" ]]; then
            echo "$OPS" | print_ops
            exit 0
        fi

        # Резолв идемпотентен, поэтому при неизвестном исходе повтор безопасен —
        # в отличие от comment, где слепой повтор повесил бы второй тред.
        write_verified "$SPACE_ID" "$OPS" "$PAGE_ID" "$DOC_FILE" "discussion: $DISCUSSION" \
            "Повтор безопасен: команда сама увидит, если тред уже $STATE." \
            "тред не $STATE. Повтор безопасен." \
            --resolve-verdict="$TARGET" "$DISCUSSION"
        echo "Тред $DISCUSSION $STATE." >&2
        echo "discussion: $DISCUSSION"
        echo "status: changed"
        ;;

    comment-rollback)
        USAGE='Usage: comment-rollback <file> [--narrow] [--dry-run]
  <file>: файл отката — строка «rollback: <путь>» в stdout comment или comment-reply
  --narrow: снять только свой тред, не возвращая сегменты блока — для блока,
            который изменился после комментария (полный откат тогда отвергается)
  --dry-run: сверить файл со страницей и показать операции, ничего не записывая
  в треде есть чужие ответы или записи из файла не ваши — отказ: откат погасил бы чужое
  в треде ваши ответы — тоже отказ: сначала откатите их своими файлами из comment-reply
  после применения файл переименовывается в <file>.applied — повтор отвергается'
        parse_comment_flags "narrow dry-run" "$@"
        FILE="${ARGS[0]:-}"
        [[ -n "$FILE" && ${#ARGS[@]} -eq 1 ]] || { echo "$USAGE" >&2; exit 1; }
        # Применённый откат второй раз не применяется: полный откат снова вернул
        # бы блок к старому снапшоту и стёр бы подсветку тех, кто успел
        # прокомментировать после первого применения.
        [[ "$FILE" == *.applied ]] && { echo "Error: $FILE уже применён (суффикс .applied) — повтор отвергнут." >&2; exit 1; }
        if [[ ! -f "$FILE" ]]; then
            echo "Error: файла отката нет: $FILE" >&2
            [[ -f "$FILE.applied" ]] && echo "       Он уже применён: $FILE.applied — повтор отвергнут." >&2
            exit 1
        fi

        RB_DIR=$(mktemp -d)
        trap 'rm -rf "$RB_DIR"' EXIT
        # Сначала файл без сети: подложенный или битый отвергается до запросов.
        CHECKED=$(python3 "$SCRIPT_DIR/buildin-comment.py" --check-rollback -- "$FILE")
        CHECK_PAGE=$(echo "$CHECKED" | python3 -c "import json, sys; print((json.load(sys.stdin)['check'] or {}).get('page', ''))")

        # Решает план отката: он сверяет файл с текущей страницей — чьи записи
        # гасятся, нет ли в треде чужих ответов, не меняли ли блок. Файл без
        # сверки читать не с чем: пустой документ, и план его отвергнет.
        echo '{}' > "$RB_DIR/doc.json"
        if [[ -n "$CHECK_PAGE" ]] && ! buildin GET "/api/docs/$CHECK_PAGE" > "$RB_DIR/doc.json"; then
            echo "Error: не удалось прочитать страницу из файла отката, чтобы сверить его с ней — откат не применён." >&2
            exit 1
        fi
        USER_ID=$(get_user_id)
        # План по странице в $RB_DIR/doc.json. Отказ — причина в stderr и код
        # 1: ничего не отправлено. Применяем только при явном apply: сбой плана
        # не должен превращаться в откат вслепую.
        rollback_plan() {
            python3 "$SCRIPT_DIR/buildin-comment.py" --rollback-plan ${NARROW:+--narrow} --user="$USER_ID" -- \
                "$FILE" "$RB_DIR/doc.json" | python3 -c "
import json, os, sys
plan, out = json.load(sys.stdin), sys.argv[1]
if plan['apply'] is not True:
    sys.stderr.write('Error: %s Откат не применён.\\n' % plan['reason'])
    if plan['hint']:
        sys.stderr.write('       %s\\n' % plan['hint'])
    sys.exit(1)
open(os.path.join(out, 'space'), 'w').write(plan['space'])
open(os.path.join(out, 'ops'), 'w').write(json.dumps(plan['ops']))
open(os.path.join(out, 'threads'), 'w').write(' '.join(plan['open_threads']))
" "$RB_DIR"
        }
        rollback_plan || exit 1
        SPACE_ID=$(cat "$RB_DIR/space")
        OPS=$(cat "$RB_DIR/ops")
        THREADS=$(cat "$RB_DIR/threads")
        if [[ -n "$DRY_RUN" ]]; then
            # Превью после всех сверок: агент видит ровно то, что уйдёт, или
            # отказ. Файл не переименовывается — откат ещё не применён.
            [[ -z "$THREADS" ]] || echo "Перед откатом команда закроет тред $THREADS и сверит его ещё раз." >&2
            echo "$OPS" | print_ops
            exit 0
        fi

        # Шаг 1: открытый гасимый тред сначала закрывается. Закрытый /api/docs
        # ещё отдаёт, погашенный — уже нет, поэтому только так виден ответ
        # коллеги, пришедший в окне между сверкой и откатом: условной записи у
        # API нет (проверено живьём). Пришёл — тред открывается обратно, откат
        # отказывает; ничего не потеряно. Закрытый тред на странице не виден,
        # так что после этого шага новый ответ в него маловероятен.
        AFTER_CLOSE=""
        for T in $THREADS; do
            write_verified "$SPACE_ID" "[{\"id\": \"$T\", \"command\": \"update\", \"table\": \"discussion\", \"path\": [], \"args\": {\"resolved\": true}}]" \
                "$CHECK_PAGE" "$RB_DIR/doc.json" "закрытие треда $T перед откатом" \
                "Файл не переименован, тред $T мог остаться закрытым. Посмотрите его: buildin-pages.sh comments $CHECK_PAGE" \
                "тред не закрылся, файл не переименован, повтор безопасен." \
                --resolve-verdict=true "$T"
            AFTER_CLOSE=" Тред $T сейчас закрыт: повторите откат или откройте тред — buildin-pages.sh comment-unresolve $CHECK_PAGE $T"
        done
        if [[ -n "$THREADS" ]] && ! rollback_plan; then
            for T in $THREADS; do
                write_verified "$SPACE_ID" "[{\"id\": \"$T\", \"command\": \"update\", \"table\": \"discussion\", \"path\": [], \"args\": {\"resolved\": false}}]" \
                    "$CHECK_PAGE" "$RB_DIR/doc.json" "возврат треда $T" \
                    "Тред $T мог остаться закрытым — откройте его: buildin-pages.sh comment-unresolve $CHECK_PAGE $T" \
                    "тред $T остался закрытым — откройте его: buildin-pages.sh comment-unresolve $CHECK_PAGE $T" \
                    --resolve-verdict=false "$T"
            done
            echo "       Тред снова открыт: в него ответили, пока шёл откат. Откат не применён." >&2
            exit 1
        fi

        # Конверт собирается заново общим transaction(): в сеть уходит одна
        # форма тела, а из файла берётся только то, что проверено по операциям.
        # В .applied файл уходит только после подтверждения на странице: иначе
        # неприменившийся откат уже не повторить, а повтор тут безопасен.
        write_verified "$SPACE_ID" "$OPS" "$CHECK_PAGE" "$RB_DIR/doc.json" "откат $FILE" \
            "Файл не переименован. Прежде чем применять снова, посмотрите блок или тред: buildin-pages.sh comments $CHECK_PAGE.$AFTER_CLOSE" \
            "файл не переименован, повтор безопасен.$AFTER_CLOSE" \
            --rollback-verdict "$RB_DIR/ops"
        # Итог — строкой status, а rollback: — путь к файлу там, где он лежит
        # сейчас, как у comment и comment-reply. Если переименовать не вышло,
        # путь прежний: .applied, которого нет, сбил бы агента.
        echo "status: applied"
        if mv "$FILE" "$FILE.applied"; then
            echo "rollback: $FILE.applied"
        else
            echo "ВНИМАНИЕ: откат применён, но переименовать $FILE не удалось." >&2
            echo "          Повторно его не применяйте." >&2
            echo "rollback: $FILE"
        fi
        ;;

    members)
        USAGE='Usage: members <page_id|url>
  участники пространства страницы, по строке «<uuid>  <nickname>» — uuid для --mention'
        [[ -n "${1:-}" && $# -eq 1 ]] || { echo "$USAGE" >&2; exit 1; }
        parse_page_and_block_id "$1"

        DOC_FILE=$(mktemp)
        trap 'rm -f "$DOC_FILE"' EXIT
        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        SPACE_ID=$(doc_space_id "$DOC_FILE")
        [[ -n "$SPACE_ID" ]] || { echo "Error: в ответе на страницу $PAGE_ID нет блоков — пространство не определить." >&2; exit 1; }
        # Почты не печатаем: для упоминания хватает uuid, а вывод целиком
        # уходит в контекст агента — чужие адреса там ни к чему.
        buildin GET "/api/spaces/$SPACE_ID/members" | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data')
if not isinstance(data, list):
    sys.exit('Error: список участников пространства не получен.')
users = [(m or {}).get('user') or {} for m in data]
for user in sorted((u for u in users if u.get('uuid')), key=lambda u: (u.get('nickname') or '').lower()):
    print(('%s  %s' % (user['uuid'], user.get('nickname') or '')).rstrip())
"
        ;;

    commands)
        print_commands
        ;;

    help)
        echo "Buildin Comments — комментарии к фразам внутри блоков (UI API)"
        echo "Принимает page_id как UUID или URL buildin.ai"
        echo ""
        echo "Commands:"
        print_commands
        ;;

    *)
        # Опечатка вроде comment-resolv проходит диспетчер по шаблону comment-*.
        # Справка с кодом 0 была бы неотличима от успеха, а контракт команд
        # держится на кодах 0/1/2.
        echo "Error: неизвестная команда: $COMMAND" >&2
        print_commands >&2
        exit 1
        ;;
esac
