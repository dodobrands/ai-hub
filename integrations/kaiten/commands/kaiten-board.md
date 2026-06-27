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
# resolve-kaiten-dir:start — первый существующий из кандидатов: плагин-кеш → overlay → standalone
KAITEN_SCRIPTS=$(ls -d "${CLAUDE_PLUGIN_ROOT:-/nope}/scripts" "$PWD"/integrations/*/integrations/kaiten/scripts "$PWD"/integrations/kaiten/scripts 2>/dev/null | head -1)
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
