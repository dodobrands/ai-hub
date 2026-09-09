# Buildin Bot API Integration

Интеграция с [Buildin.ai](https://buildin.ai) через **Official Bot API** (`api.buildin.ai/v1/`).

В отличие от `buildin/` (UI API, JWT из Google SSO), эта интеграция использует бот-токен и Notion-подобный REST API.

## Сравнение с UI API (buildin/)

| | buildin (UI API) | buildin-bot-api (Official API) |
|---|---|---|
| Base URL | `buildin.ai/api/` | `api.buildin.ai/v1/` |
| Auth | JWT из Google SSO (`BUILDIN_UI_TOKEN`) | Bot token (`BUILDIN_BOT_TOKEN`) |
| Доступ | Все страницы пользователя | Только расшаренные боту страницы |
| Логин | Browser SSO → cookie extraction | Токен из Settings → Integrations |
| API стиль | Internal UI API (transactions) | Notion-подобный REST (CRUD) |
| Поиск | UI search (низкое качество) | `/v1/search` (с пагинацией) |
| Запись | Transaction protocol (complex) | Simple CRUD (create page, append blocks) |

## Структура

```
integrations/buildin-bot-api/
├── .claude-plugin/
│   └── plugin.json
├── scripts/
│   ├── buildin-bot.sh            # Level 1: HTTP-клиент (curl + Bearer bot token)
│   ├── buildin-bot-pages.sh      # Level 2: Страницы (get, read, create, update, archive, search)
│   └── buildin-bot-blocks.sh     # Level 2: Блоки (get, children, append, update, delete)
├── commands/
│   └── buildin-bot-read.md       # Скилл: чтение страницы через Bot API
└── README.md
```

## Быстрый старт

### 1. Получить токен

1. Зайти в Buildin → Settings → Integrations
2. Создать новую бот-интеграцию
3. Скопировать токен

### 2. Сохранить токен

```bash
bash integrations/hub-meta/scripts/env-manager.sh set BUILDIN_BOT_TOKEN <your-token>
```

### 3. Проверить подключение

```bash
./integrations/buildin-bot-api/scripts/buildin-bot.sh GET /v1/users/me
```

### 4. Расшарить страницы боту

Bot API видит только страницы, к которым бот явно добавлен. Зайди на нужную страницу → Share → добавь бота.

## Использование

### Чтение

```bash
# Метаданные страницы (JSON)
./integrations/buildin-bot-api/scripts/buildin-bot-pages.sh get <page_id|url>

# Страница как markdown
./integrations/buildin-bot-api/scripts/buildin-bot-pages.sh read <page_id|url>
```

### Создание и редактирование

```bash
# Создать дочернюю страницу
./integrations/buildin-bot-api/scripts/buildin-bot-pages.sh create <parent_id> "Заголовок"

# Обновить заголовок
./integrations/buildin-bot-api/scripts/buildin-bot-pages.sh update <page_id> "Новый заголовок"

# Архивировать
./integrations/buildin-bot-api/scripts/buildin-bot-pages.sh archive <page_id>
```

### Поиск

```bash
# Поиск страниц (до 20 результатов)
./integrations/buildin-bot-api/scripts/buildin-bot-pages.sh search "RFC template" 20
```

### Блоки

```bash
# Получить блок
./integrations/buildin-bot-api/scripts/buildin-bot-blocks.sh get <block_id>

# Дочерние блоки
./integrations/buildin-bot-api/scripts/buildin-bot-blocks.sh children <page_id>

# Добавить текстовый параграф
./integrations/buildin-bot-api/scripts/buildin-bot-blocks.sh append-text <page_id> "Новый параграф"

# Добавить блоки (JSON)
./integrations/buildin-bot-api/scripts/buildin-bot-blocks.sh append <page_id> \
  '[{"type": "heading_2", "data": {"rich_text": [{"type": "text", "text": {"content": "Section"}}]}}]'

# Обновить блок
./integrations/buildin-bot-api/scripts/buildin-bot-blocks.sh update <block_id> \
  '{"type": "paragraph", "data": {"rich_text": [{"type": "text", "text": {"content": "Updated"}}]}}'

# Удалить блок
./integrations/buildin-bot-api/scripts/buildin-bot-blocks.sh delete <block_id>
```

## API Reference

Base URL: `https://api.buildin.ai`, auth: `Authorization: Bearer $BUILDIN_BOT_TOKEN`

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | /v1/users/me | Информация о создателе бота |
| GET | /v1/pages/{id} | Метаданные страницы |
| POST | /v1/pages | Создать страницу |
| PATCH | /v1/pages/{id} | Обновить свойства / архивировать |
| GET | /v1/blocks/{id} | Получить блок |
| GET | /v1/blocks/{id}/children | Дочерние блоки (с пагинацией) |
| PATCH | /v1/blocks/{id}/children | Добавить дочерние блоки |
| PATCH | /v1/blocks/{id} | Обновить блок |
| DELETE | /v1/blocks/{id} | Удалить блок |
| POST | /v1/search | Поиск страниц (с пагинацией) |
| POST | /v1/pages/search | Поиск страниц (альтернативный) |
| POST | /v1/databases | Создать базу данных |
| GET | /v1/databases/{id} | Получить базу данных |
| PATCH | /v1/databases/{id} | Обновить базу данных |
| POST | /v1/databases/{id}/query | Запросить записи базы данных |

## Типы блоков

`paragraph`, `heading_1`, `heading_2`, `heading_3`, `bulleted_list_item`, `numbered_list_item`, `to_do`, `quote`, `toggle`, `code`, `callout`, `divider`, `image`, `file`, `bookmark`, `embed`, `equation`, `link_to_page`, `column_list`, `column`, `table`, `table_row`, `child_page`, `child_database`

## Формат rich_text

```json
[
  {
    "type": "text",
    "text": {"content": "Hello ", "link": null},
    "annotations": {"bold": false, "italic": false, "code": false, "strikethrough": false},
    "plain_text": "Hello "
  },
  {
    "type": "text",
    "text": {"content": "world", "link": {"url": "https://example.com"}},
    "annotations": {"bold": true},
    "plain_text": "world"
  }
]
```

## Ошибки

| HTTP | Code | Причина |
|------|------|---------|
| 401 | unauthorized | Невалидный или просроченный токен |
| 403 | forbidden | Бот не имеет доступа к странице (нужно расшарить) |
| 404 | not_found | Страница/блок не существует |
| 429 | rate_limit | Превышен лимит запросов |
| 500 | internal_error | Ошибка на стороне Buildin (напр., /v1/search иногда 500) |

## Известные ограничения

- **Поиск /v1/search — СЛОМАН (стабильно 500), подкоманда `search` заглушена** (`exit 2` с подсказкой). Не начинай задачу с поиска: читай по page_id/URL, спрашивай URL у пользователя, либо используй UI API `buildin/` (shadow-индекс + обход дерева `buildin-nav children`).
- **Доступ** — бот видит только расшаренные ему страницы (403 для остальных).
- **Нет API пространств** — `/v1/spaces` не существует.
- **SDK** — [next-space/buildin-api-sdk](https://github.com/next-space/buildin-api-sdk) (Java + TypeScript, OpenAPI spec).
