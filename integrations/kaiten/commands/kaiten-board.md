---
name: kaiten-board
description: Export or inspect a Kaiten board — columns, cards, structure
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "AskUserQuestion"]
---

# Kaiten Board — экспорт и просмотр доски

Экспортирует карточки и структуру доски Kaiten в Markdown или выводит сводку.

## Trigger

Активируй при любом из условий:

- URL доски: `https://<domain>.kaiten.ru/space/<space_id>/board/<board_id>`
- Запрос вида «покажи доску», «экспортируй спринт», «что в бэклоге» + ссылка или board_id
- Запрос получить список карточек / колонок на доске Kaiten

## Резолвинг каталога скриптов

Каталог скриптов резолвится так, чтобы команда работала из **любого** репозитория
(standalone-клон, subtree-overlay, marketplace-install). Выполни строку-резолвер
перед вызовом скриптов; если bash-блоки запускаются отдельными shell'ами и
переменная между ними не сохраняется — повтори её в начале нужного блока.

```bash
# resolve-kaiten-dir:start — плагин-кеш, иначе поиск по форме пути от корня репозитория.
# Без glob-ов: в zsh несовпавший шаблон обрывает всю подстановку, и до следующих
# кандидатов дело не доходит (см. tests/path-resolution.sh).
KAITEN_SCRIPTS=""
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/kaiten-cards.sh" ] && KAITEN_SCRIPTS="$CLAUDE_PLUGIN_ROOT/scripts"
[ -n "$KAITEN_SCRIPTS" ] || KAITEN_SCRIPTS=$(find "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" -maxdepth 6 -type d -path '*/integrations/kaiten/scripts' 2>/dev/null | sort | head -1)
# resolve-kaiten-dir:end
```

## Получение board_id

- Из ссылки `https://<domain>.kaiten.ru/space/<space_id>/board/<board_id>` — числовой сегмент после `/board/`.
- Если есть `team-config.json` — используй `.kaiten.boards.sprint.id` или `.kaiten.boards.business_backlog.id`.

## Экспорт доски в Markdown

```bash
# Экспорт всех не-архивных карточек в файл
"$KAITEN_SCRIPTS/kaiten-export-board.sh" <board_id> board.md

# Или без файла — вывод в stdout
"$KAITEN_SCRIPTS/kaiten-export-board.sh" <board_id>
```

Экспорт включает: колонки, карточки по колонкам, описания, чек-листы, Affected Services (если задан `PROPERTY_ID` или `team-config.json`).

## Просмотр структуры доски

```bash
# Информация о доске
"$KAITEN_SCRIPTS/kaiten-spaces.sh" board <board_id>

# Колонки доски
"$KAITEN_SCRIPTS/kaiten-spaces.sh" columns <board_id>

# Дорожки (lanes)
"$KAITEN_SCRIPTS/kaiten-spaces.sh" lanes <board_id>
```

## Список карточек на доске

```bash
"$KAITEN_SCRIPTS/kaiten-cards.sh" list <board_id>
```

## Список досок в пространстве

```bash
# Все доски пространства (default: $KAITEN_SPACE из .env)
"$KAITEN_SCRIPTS/kaiten-spaces.sh" boards [space_id]
```

## Настройка

В `.env` должны быть:

```bash
KAITEN_TOKEN=your_api_token
KAITEN_DOMAIN=your_domain.kaiten.ru
KAITEN_SPACE=your_space_id   # опционально, для команд без явного space_id
```

| Ошибка | Причина |
|--------|---------|
| 401 | Неверный или истёкший токен |
| 404 | Неверный board_id или домен |
| 429 | Превышен лимит 100 req/min — подожди минуту |

$ARGUMENTS
