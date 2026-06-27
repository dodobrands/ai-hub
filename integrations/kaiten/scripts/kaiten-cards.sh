#!/bin/bash
# Kaiten Cards API - быстрые команды для работы с карточками
# Usage: ./kaiten-cards.sh <command> [args...]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kaiten() {
    "$SCRIPT_DIR/kaiten.sh" "$@"
}

show_help() {
    cat << EOF
Kaiten Cards CLI

Usage: ./kaiten-cards.sh <command> [args...]

Commands:
  list [board_id]                    - Список карточек (без id - все карточки \$KAITEN_SPACE)
  search <query> [space_id]          - Поиск карточек по тексту (API параметр "query")
  get <card_id> [--with-comments]    - Получить карточку (с --with-comments
                                       вмёрживает массив comments; иначе в карточке
                                       только comments_total — текстов комментов нет)
  create <board_id> <column_id> <title> [description] [size_text] [type_id]
                                       - Создать карточку (size_text: "5 SP", type_id: число)
  update <card_id> <json_body>       - Обновить карточку
  move <card_id> <column_id>         - Переместить в колонку
  delete <card_id>                   - Удалить карточку
  
  comment <card_id> <text>           - Добавить комментарий
  comments <card_id>                 - Получить комментарии
  
  assign <card_id> <user_id>         - Назначить ответственного
  unassign <card_id> <member_id>     - Снять ответственного (member_id из members)
  members <card_id>                  - Получить участников
  
  tag <card_id> <tag_id>             - Добавить тег
  tags <card_id>                     - Получить теги
  
  checklist <card_id> <name>         - Создать чек-лист
  checklists <card_id>               - Получить чек-листы
  check-item <card_id> <checklist_id> <text>  - Добавить пункт чек-листа
  update-check-item <card_id> <checklist_id> <item_id> <text>
                                       - Обновить текст пункта чек-листа
  toggle-check-item <card_id> <checklist_id> <item_id> <true|false>
                                       - Отметить/снять пункт чек-листа
  delete-check-item <card_id> <checklist_id> <item_id>
                                       - Удалить пункт чек-листа

Examples:
  ./kaiten-cards.sh list 123
  ./kaiten-cards.sh search "перевод меню"
  ./kaiten-cards.sh search "перевод меню" <space_id>
  ./kaiten-cards.sh create 123 456 "Новая задача" "Описание" "5 SP" 42
  ./kaiten-cards.sh move 789 101
  ./kaiten-cards.sh comment 789 "Готово!"
EOF
}

# Use KAITEN_SPACE as default
SPACE_ID="${KAITEN_SPACE:-}"

case "${1:-help}" in
    list)
        endpoint=""
        if [[ -n "$2" ]]; then
            endpoint="/cards?board_id=$2"
        elif [[ -n "$SPACE_ID" ]]; then
            endpoint="/cards?space_id=$SPACE_ID"
        else
            echo "Error: board_id required or set KAITEN_SPACE" >&2
            exit 1
        fi
        
        # Fetch all cards with pagination (API limit is 100 per request)
        # Save to temp files to avoid unicode/control character corruption in bash variables
        offset=0
        limit=100
        tmpdir=$(mktemp -d)
        trap "rm -rf '$tmpdir'" EXIT
        page=0

        while true; do
            kaiten GET "${endpoint}&offset=${offset}&limit=${limit}" > "$tmpdir/page_${page}.json"
            batch_count=$(jq 'length' "$tmpdir/page_${page}.json")

            if [[ "$batch_count" -eq 0 ]]; then
                rm -f "$tmpdir/page_${page}.json"
                break
            fi

            offset=$((offset + limit))
            page=$((page + 1))

            if [[ "$batch_count" -lt "$limit" ]]; then
                break
            fi
        done

        if [[ $page -eq 0 ]] && [[ ! -f "$tmpdir/page_0.json" ]]; then
            echo "[]"
        else
            jq -s 'add' "$tmpdir"/page_*.json
        fi
        ;;
    search)
        [[ -z "$2" ]] && { echo "Error: query required" >&2; exit 1; }
        encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$2'))")
        search_space="${3:-$SPACE_ID}"
        if [[ -n "$search_space" ]]; then
            kaiten GET "/cards?space_id=$search_space&query=$encoded_query"
        else
            kaiten GET "/cards?query=$encoded_query"
        fi
        ;;
    get)
        # Kaiten не встраивает массив comments в объект карточки (только comments_total).
        # blockers и checklists встроены по умолчанию; для текстов комментов нужен
        # отдельный вызов — с --with-comments вмёрживаем их в .comments.
        if [[ "$3" == "--with-comments" ]]; then
            card=$(kaiten GET "/cards/$2")
            comments=$(kaiten GET "/cards/$2/comments")
            jq -n --argjson card "$card" --argjson comments "$comments" \
                '$card + {comments: $comments}'
        else
            kaiten GET "/cards/$2"
        fi
        ;;
    create)
        # Use jq for safe JSON escaping (prevents injection)
        size_text="${6:-}"
        type_id="${7:-}"
        body=$(jq -n \
            --arg title "$4" \
            --argjson board_id "$2" \
            --argjson column_id "$3" \
            --arg description "${5:-}" \
            --arg size_text "$size_text" \
            --arg type_id "$type_id" \
            '{title: $title, board_id: $board_id, column_id: $column_id, description: $description}
            | if $size_text != "" then . + {size_text: $size_text} else . end
            | if $type_id != "" then . + {type_id: ($type_id | tonumber)} else . end')
        kaiten POST "/cards" "$body"
        ;;
    update)
        kaiten PATCH "/cards/$2" "$3"
        ;;
    move)
        kaiten PATCH "/cards/$2" "{\"column_id\": $3}"
        ;;
    delete)
        kaiten DELETE "/cards/$2"
        ;;
    comment)
        # Use jq to properly escape text for JSON (handles newlines, quotes, unicode)
        json_body=$(jq -n --arg text "$3" '{"text": $text}')
        kaiten POST "/cards/$2/comments" "$json_body"
        ;;
    comments)
        kaiten GET "/cards/$2/comments"
        ;;
    assign)
        kaiten POST "/cards/$2/members" "{\"user_id\": $3, \"type\": 1}"
        ;;
    unassign)
        [[ -z "$2" || -z "$3" ]] && { echo "Usage: $0 unassign <card_id> <member_id>" >&2; exit 1; }
        kaiten DELETE "/cards/$2/members/$3"
        ;;
    members)
        kaiten GET "/cards/$2/members"
        ;;
    tag)
        kaiten POST "/cards/$2/tags" "{\"tag_id\": $3}"
        ;;
    tags)
        kaiten GET "/cards/$2/tags"
        ;;
    checklist)
        # Use jq for safe JSON escaping
        json_body=$(jq -n --arg name "$3" '{"name": $name}')
        kaiten POST "/cards/$2/checklists" "$json_body"
        ;;
    checklists)
        # Checklists are embedded in the card object (no separate endpoint)
        kaiten GET "/cards/$2" | jq '.checklists'
        ;;
    check-item)
        # Use jq for safe JSON escaping
        json_body=$(jq -n --arg text "$4" '{"text": $text, "checked": false}')
        kaiten POST "/cards/$2/checklists/$3/items" "$json_body"
        ;;
    update-check-item)
        [[ -z "$5" ]] && { echo "Usage: $0 update-check-item <card_id> <checklist_id> <item_id> <text>" >&2; exit 1; }
        json_body=$(jq -n --arg text "$5" '{"text": $text}')
        kaiten PATCH "/cards/$2/checklists/$3/items/$4" "$json_body"
        ;;
    toggle-check-item)
        [[ -z "$5" ]] && { echo "Usage: $0 toggle-check-item <card_id> <checklist_id> <item_id> <true|false>" >&2; exit 1; }
        kaiten PATCH "/cards/$2/checklists/$3/items/$4" "{\"checked\": $5}"
        ;;
    delete-check-item)
        [[ -z "$4" ]] && { echo "Usage: $0 delete-check-item <card_id> <checklist_id> <item_id>" >&2; exit 1; }
        kaiten DELETE "/cards/$2/checklists/$3/items/$4"
        ;;
    help|--help|-h|*)
        show_help
        ;;
esac
