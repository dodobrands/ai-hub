# Kaiten API Reference for LLM Agents

Документация основных endpoints Kaiten API для использования LLM агентами.

**Base URL:** `https://{your-domain}.kaiten.ru/api/latest`  
**Authentication:** Bearer Token в заголовке `Authorization: Bearer {token}`  
**Content-Type:** `application/json`

---

## Аутентификация

Все запросы требуют API токен. Получить токен можно в настройках профиля Kaiten.

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
     -H "Content-Type: application/json" \
     https://your-domain.kaiten.ru/api/latest/...
```

---

## Основные сущности

### Spaces (Пространства)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/spaces` | Создать пространство |
| GET | `/spaces` | Получить список пространств |
| GET | `/spaces/{id}` | Получить пространство |
| PATCH | `/spaces/{id}` | Обновить пространство |
| DELETE | `/spaces/{id}` | Удалить пространство |

### Boards (Доски)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/spaces/{space_id}/boards` | Создать доску |
| GET | `/spaces/{space_id}/boards` | Получить список досок |
| GET | `/boards/{id}` | Получить доску |
| PATCH | `/boards/{id}` | Обновить доску |
| DELETE | `/boards/{id}` | Удалить доску |

### Columns (Колонки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/boards/{board_id}/columns` | Создать колонку |
| GET | `/boards/{board_id}/columns` | Получить список колонок |
| PATCH | `/columns/{id}` | Обновить колонку |
| DELETE | `/columns/{id}` | Удалить колонку |

### Lanes (Дорожки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/boards/{board_id}/lanes` | Создать дорожку |
| GET | `/boards/{board_id}/lanes` | Получить список дорожек |
| PATCH | `/lanes/{id}` | Обновить дорожку |
| DELETE | `/lanes/{id}` | Удалить дорожку |

---

## Cards (Карточки) ⭐ Основной функционал

### CRUD операции

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards` | Создать карточку |
| GET | `/cards` | Получить список карточек (с фильтрами) |
| GET | `/cards/{id}` | Получить карточку |
| PATCH | `/cards/{id}` | Обновить карточку |
| PATCH | `/cards/batch` | Массовое обновление карточек |
| DELETE | `/cards/{id}` | Удалить карточку |
| GET | `/cards/{id}/history` | История перемещений карточки |

### Создание карточки

```json
POST /cards
{
  "title": "Название задачи",
  "board_id": 123,
  "column_id": 456,
  "lane_id": 789,
  "description": "Описание задачи",
  "type_id": 1,
  "size_text": "3",
  "due_date": "2024-12-31",
  "properties": {
    "property_id": "value"
  }
}
```

### Обновление карточки (перемещение)

```json
PATCH /cards/{id}
{
  "column_id": 789,
  "lane_id": 101,
  "sort_order": 1
}
```

### Фильтрация и пагинация карточек

```
GET /cards?board_id=123&column_id=456&member_id=789&tag_id=101
GET /cards?board_id=123&offset=100&limit=100
```

**Важно:** API возвращает максимум 100 карточек за один запрос. Для получения всех карточек используйте параметры `offset` и `limit` для пагинации.

### Полный список query-параметров GET /cards

Источник: [developers.kaiten.ru/cards/retrieve-card-list](https://developers.kaiten.ru/cards/retrieve-card-list)

| Параметр | Тип | Описание |
|----------|-----|----------|
| `query` | string | **Текстовый поиск** по содержимому карточки |
| `search_fields` | string | Поля для поиска (уточняет `query`) |
| `board_id` | integer | Фильтр по доске |
| `space_id` | integer | Фильтр по пространству |
| `column_id` | integer | Фильтр по колонке |
| `column_ids` | string | Фильтр по нескольким колонкам (comma separated) |
| `lane_id` | integer | Фильтр по дорожке |
| `member_ids` | string | Фильтр по участникам (comma separated) |
| `owner_ids` | string | Фильтр по владельцам (comma separated) |
| `responsible_ids` | string | Фильтр по ответственным (comma separated) |
| `tag` | string | Фильтр по имени тега |
| `tag_ids` | string | Фильтр по ID тегов (comma separated) |
| `type_id` | integer | Фильтр по типу карточки |
| `type_ids` | string | Фильтр по нескольким типам (comma separated) |
| `states` | string | Фильтр по состояниям: 1-queued, 2-inProgress, 3-done |
| `condition` | integer | 1 — на доске, 2 — в архиве |
| `archived` | boolean | Флаг архивации |
| `created_before` / `created_after` | string | Фильтр по дате создания (ISO 8601) |
| `updated_before` / `updated_after` | string | Фильтр по дате обновления (ISO 8601) |
| `due_date_before` / `due_date_after` | string | Фильтр по дедлайну (ISO 8601) |
| `external_id` | string | Фильтр по внешнему ID |
| `additional_card_fields` | string | Доп. поля в ответе (напр. `description`) |
| `limit` | integer | Макс. карточек в ответе (default/max: 100) |
| `offset` | integer | Пропустить N записей |
| `order_by` | string | Поля сортировки (comma separated) |
| `order_direction` | string | Направление сортировки: `asc` / `desc` |
| `exclude_board_ids` | string | Исключить доски (comma separated) |
| `exclude_column_ids` | string | Исключить колонки (comma separated) |
| `exclude_lane_ids` | string | Исключить дорожки (comma separated) |
| `exclude_owner_ids` | string | Исключить владельцев (comma separated) |
| `exclude_card_ids` | string | Исключить карточки (comma separated) |

> **⚠️ Важно:** Параметр `query` работает с `space_id`, но **не сочетается с `board_id`** (возвращает 0 результатов). Для текстового поиска на конкретной доске используйте `space_id` + `query`, затем фильтруйте по `board_id` в ответе. Параметра `search` в API **не существует** — он молча игнорируется.

---

## Card Members (Участники карточки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/members` | Добавить участника |
| GET | `/cards/{card_id}/members` | Получить участников |
| PATCH | `/cards/{card_id}/members/{user_id}` | Обновить роль |
| DELETE | `/cards/{card_id}/members/{user_id}` | Удалить участника |

```json
POST /cards/{card_id}/members
{
  "user_id": 123,
  "type": 1  // 1 - responsible, 2 - member
}
```

---

## Card Comments (Комментарии)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/comments` | Добавить комментарий |
| GET | `/cards/{card_id}/comments` | Получить комментарии |
| PATCH | `/cards/{card_id}/comments/{id}` | Обновить комментарий |
| DELETE | `/cards/{card_id}/comments/{id}` | Удалить комментарий |

```json
POST /cards/{card_id}/comments
{
  "text": "Текст комментария"
}
```

---

## Card Tags (Теги карточки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/tags` | Добавить тег |
| GET | `/cards/{card_id}/tags` | Получить теги |
| DELETE | `/cards/{card_id}/tags/{tag_id}` | Удалить тег |

> **⚠️ Gotcha:** Тег добавляется **по имени**, не по id. Передавайте `{"name": "AI"}`, а не `{"tag_id": 123}` — иначе получите 400.

```json
POST /cards/{card_id}/tags
{"name": "Имя тега"}
```

---

## Card Checklists (Чек-листы)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/checklists` | Создать чек-лист |
| GET | `/cards/{card_id}/checklists` | Получить чек-листы |
| PATCH | `/cards/{card_id}/checklists/{id}` | Обновить чек-лист |
| DELETE | `/cards/{card_id}/checklists/{id}` | Удалить чек-лист |

### Checklist Items

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/checklists/{checklist_id}/items` | Добавить пункт |
| PATCH | `/cards/{card_id}/checklists/{checklist_id}/items/{id}` | Обновить пункт |
| DELETE | `/cards/{card_id}/checklists/{checklist_id}/items/{id}` | Удалить пункт |

```json
POST /cards/{card_id}/checklists/{checklist_id}/items
{
  "text": "Пункт чек-листа",
  "checked": false
}
```

---

## Card Files (Файлы)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| PUT | `/cards/{card_id}/files` | Прикрепить файл |
| PATCH | `/cards/{card_id}/files/{id}` | Обновить файл |
| DELETE | `/cards/{card_id}/files/{id}` | Открепить файл |

---

## Card Blockers (Блокировки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/blockers` | Заблокировать карточку |
| GET | `/cards/{card_id}/blockers` | Получить блокировки |
| PATCH | `/cards/{card_id}/blockers/{id}` | Обновить блокировку |
| DELETE | `/cards/{card_id}/blockers/{id}` | Снять блокировку |

```json
POST /cards/{card_id}/blockers
{
  "reason": "Причина блокировки",
  "blocker_card_id": 123
}
```

> **Два вида блокеров:**
> - С `blocker_card_id` — связывает две карточки: текущая заблокирована другой (зависимость)
> - Только с `reason` — текстовый блокер без привязки к карточке

---

## Card Time Logs (Учёт времени)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/time-logs` | Добавить запись времени |
| GET | `/cards/{card_id}/time-logs` | Получить записи времени |
| PATCH | `/cards/{card_id}/time-logs/{id}` | Обновить запись |
| DELETE | `/cards/{card_id}/time-logs/{id}` | Удалить запись |

---

## Card Children (Дочерние карточки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/children` | Добавить дочернюю карточку |
| GET | `/cards/{card_id}/children` | Получить дочерние карточки |
| DELETE | `/cards/{card_id}/children/{child_id}` | Удалить связь |

### Привязка дочерней карточки к родителю

```json
POST /cards/{parent_card_id}/children
{
  "card_id": <child_card_id>
}
```

> **⚠️ Важно:** Тело запроса содержит `card_id` (ID дочерней карточки) — одиночное число, **не массив**.  
> Распространённая ошибка: `{"children_ids": [...]}` или `{"parent_ids": [...]}` — поля с такими именами игнорируются, запрос возвращает `200`, но связь **не создаётся**.  
> `403` к телу запроса отношения не имеет — это ошибка доступа (токен/права на карточку), а не формата.

```bash
# Пример: привязать карточку <child_id> к родителю <parent_id>
curl -X POST "https://{domain}/api/latest/cards/<parent_id>/children" \
  -H "Authorization: Bearer {token}" \
  -H "Content-Type: application/json" \
  -d '{"card_id": <child_id>}'
```

Ответ: `200` с объектом дочерней карточки, в котором `parents_ids` содержит ID родителя.

---

## Card External Links (Внешние ссылки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/external-links` | Добавить ссылку |
| GET | `/cards/{card_id}/external-links` | Получить ссылки |
| PATCH | `/cards/{card_id}/external-links/{id}` | Обновить ссылку |
| DELETE | `/cards/{card_id}/external-links/{id}` | Удалить ссылку |

---

## Users (Пользователи)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/users` | Получить список пользователей |
| GET | `/users/current` | Получить текущего пользователя |
| PATCH | `/users/{id}` | Обновить пользователя |

---

## Tags (Теги)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/tags` | Создать тег |
| GET | `/tags` | Получить список тегов |

---

## Custom Properties (Кастомные свойства)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/company/custom-properties` | Список всех свойств компании |
| GET | `/company/custom-properties/{id}/select-values` | Значения select-свойства |
| POST | `/properties` | Создать свойство |
| GET | `/properties/{id}` | Получить свойство |
| PATCH | `/properties/{id}` | Обновить свойство |
| DELETE | `/properties/{id}` | Удалить свойство |

> **Формат значений свойств:** `"id_{property_id}": [{select_value_id}]` для select-свойств. Для получения ID свойств: `GET /company/custom-properties`, для значений select: `GET /company/custom-properties/{id}/select-values`.

> **⚠️ Gotcha:** Нативного API для "related cards" (связанные карточки) не существует. Для связывания карточек используйте `external-links` с URL на карточку:
>
> ```json
> POST /cards/{id}/external-links
> {"url": "https://domain.kaiten.ru/space/{space}/boards/card/{card_id}", "description": "Связанная задача"}
> ```

---

## Card Types (Типы карточек)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/card-types` | Создать тип |
| GET | `/card-types` | Получить список типов |
| GET | `/card-types/{id}` | Получить тип |
| PATCH | `/card-types/{id}` | Обновить тип |
| DELETE | `/card-types/{id}` | Удалить тип |

---

## Sprints (Спринты)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/sprints` | Получить список спринтов |
| GET | `/sprints/{id}/summary` | Получить сводку спринта |

---

## Timesheet (Табель)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/timesheet` | Получить табель |

---

## Rate Limits

- **Лимит:** 100 запросов в минуту
- При превышении возвращается HTTP 429

---

## Типичные сценарии для LLM агента

### 1. Создать задачу и назначить исполнителя

```bash
# 1. Создать карточку
POST /cards
{"title": "Новая задача", "board_id": 123, "column_id": 456}

# 2. Назначить исполнителя
POST /cards/{card_id}/members
{"user_id": 789, "type": 1}
```

### 2. Переместить карточку в другую колонку

```bash
PATCH /cards/{id}
{"column_id": 789}
```

### 3. Добавить комментарий с прогрессом

```bash
POST /cards/{card_id}/comments
{"text": "Выполнено 50% работы"}
```

### 4. Создать чек-лист с пунктами

```bash
# 1. Создать чек-лист
POST /cards/{card_id}/checklists
{"name": "Подзадачи"}

# 2. Добавить пункты
POST /cards/{card_id}/checklists/{checklist_id}/items
{"text": "Пункт 1", "checked": false}
```

### 5. Найти карточки по фильтрам

```bash
GET /cards?board_id=123&member_id=456&tag_id=789
```

### 6. Текстовый поиск карточек

```bash
# Поиск по пространству (рекомендуется)
GET /cards?space_id=YOUR_SPACE_ID&query=%D0%BF%D0%B5%D1%80%D0%B5%D0%B2%D0%BE%D0%B4

# ⚠️ query + board_id НЕ работает — используйте space_id
```

---

## Коды ошибок

| Код | Описание |
|-----|----------|
| 200 | Успех |
| 201 | Создано |
| 400 | Неверный запрос |
| 401 | Не авторизован |
| 403 | Доступ запрещён |
| 404 | Не найдено |
| 429 | Превышен лимит запросов |
| 500 | Ошибка сервера |
