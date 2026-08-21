# Kaiten API Reference for LLM Agents

Документация основных endpoints Kaiten API для использования LLM агентами.

**Base URL:** `https://{your-domain}.kaiten.ru/api/latest`  
**Authentication:** Bearer Token в заголовке `Authorization: Bearer {token}`  
**Content-Type:** `application/json`

`/api/v1/...` и `/api/latest/...` — алиасы одной версии, ответы совпадают (замер).

**Пометки в тексте:** «замер» — проверено запросами к живому API; остальное — по официальной документации [developers.kaiten.ru](https://developers.kaiten.ru). Разделы с пометкой **BETA** Kaiten прямо обещает менять: «parameters, attributes, and response formats are subject to change».

---

## Аутентификация

Все запросы требуют API токен. Получить токен можно в настройках профиля Kaiten.

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
     -H "Content-Type: application/json" \
     https://your-domain.kaiten.ru/api/latest/...
```

---

## Общие правила (читать до первого запроса)

### Запись: 200 не значит «записалось»

> **⚠️ Неизвестное поле верхнего уровня в `PATCH` игнорируется молча.** Замер: `PATCH /cards/{id} {"nonexistent_field_xyz": 123}` → **200**, при этом `version` не вырос, `updated` не сдвинулся, поля в ответе нет. Ответ неотличим от успешной записи. Надёжный признак того, что запись состоялась, один — **рост `version`** (и сдвиг `updated`).

> **⚠️ А вот `properties` и теги валидируются схемой и честно отдают 400.** Замеры: `{"properties": {"id_999999999": [1]}}` → 400 `properties should NOT have additional properties`; `{"properties": {"id_{валидный_id}": "не-массив"}}` → 400 `should be array … should match exactly one schema in oneOf`; `POST /cards/{id}/tags {"tag_id": 999}` → 400 `Tag should have required property 'name'` (тег не создан). То есть отсутствие 400 ничего не доказывает, а его наличие — доказывает: **после записи результат надо сверять**.

> **⚠️ `properties` валидируются по компании, а не по доске.** Свойство, которое существует в компании, но не подключено к доске карточки, записывается с кодом **200** и реально сохраняется — но в интерфейсе этой доски его не видно (замер). Это опаснее игнора: тихая запись «в никуда». Перед записью сверяйся со списком свойств доски (`card_properties`), а не полагайся на 400. Гасится тем же PATCH со значением `null`.

**Сверочный GET после записи не нужен.** Ответ `PATCH /cards/{id}` — это уже обновлённая карточка: 78 плоских полей ответа побайтово совпали с последующим `GET /cards/{id}` (замер). `GET` отдаёт 91 поле, разница — только развёрнутые сущности (`board`, `column`, `lane`, `type`, `members`, `files`, `children`, `parents`, `external_links`, `email`, `cardRole`, `card_permissions`, `in_workflow`). `properties`, `tag_ids`, `tags`, `version`, `updated` в ответе PATCH есть.

### Числовые id и UUID

Большая часть API адресуется числовым `id`, но часть маршрутов понимает **только UUID** (поле `uid` соответствующей сущности); с числовым id они отдают `404`.

| Раздел | Что в пути |
|--------|------------|
| Итерации | `space_uid`, `card_uid` |
| Шаблоны чек-листов пространства | `space_uid` |
| Автоматизации | `automation_uid` |
| Документы, папки документов, дерево сущностей | `uid`, `parent_entity_uid` |
| Файлы с ограниченным доступом | `card_uid`, `comment_uid`, `property_uid`, `id` файла |
| Справочники (custom directories) | `directory_id`, `field_id`, `record_id` |
| Роли доступа к пространству | `role_id` — строка-UUID |

Обратное тоже верно: обычные карточные маршруты UUID не понимают — `GET /cards/{card_uid}` → `404` (замер).

### Лимиты выдачи

«Максимум 100 записей» — не универсальное правило.

| Endpoint | `limit` по умолчанию / максимум |
|----------|-------------------------------|
| `/cards` | 100 / 100 |
| `/users`, `/company/users` | 100 / 100 |
| `/company/custom-directories/{id}/records` | 100 / 100 |
| `/time-logs` (табель) | 100 / **200** |
| `/company/custom-directories` | 200 / **200** |
| `/company/custom-properties` | 100 / **500** (замер: `limit=500` вернул 500) |
| `/audit-logs` | 100 / **500** |
| `/tree-entities` | 500 / **500** |

Всё, что больше максимума, молча обрезается: `GET /users?limit=200` вернёт 100, а не ошибку.

### Коды ответов, которые значат не то, что кажется

| Код | Что он на самом деле означает |
|-----|-------------------------------|
| `402` | Фича не входит в тариф компании (`{"message": "Your tariff doesn't include '…' feature"}`), а не ошибка тела запроса |
| `403` | Нехватка прав, **или** настройка компании (см. `code` в теле), **или** проверка доступа, которая идёт **до** валидации тела: `POST /cards/{id}/checklists/{несуществующий}/items` → 403, а не 404 |
| `405` | Путь существует, но метод не поддерживается (у 404 путь не существует вовсе) |
| `429` | Тело — `text/html`, не JSON; парсеры ответа на этом ломаются |
| `500` | Иногда просто отсутствие валидации внешнего ключа (пример — неизвестный `policy_id` у чек-листа) |

### Прочие общие правила

- **`anyOf` в схемах PATCH:** почти каждый PATCH требует хотя бы одно поле из фиксированного списка, пустое тело отвергается с 400. Полезный приём разведки: `PATCH` с телом `{}` возвращает перечень допустимых ключей вашей версии Kaiten.
- **`DELETE` структуры доски требует `{"force": true}`** (доска, колонка, подколонка, дорожка), иначе 400 `… should be deleted with force`. С `force` удаление каскадное и необратимое.
- **`-1` в настройках колонок и дорожек — это «выключено»**, а не «минус один день». Проверка «настройка задана» — `> 0`, а не `!= null`.

---

## Основные сущности

### Иерархия

```
Space (пространство)          /spaces/{space_id}
└── Board (доска)             /spaces/{space_id}/boards/{id}
    ├── Column (колонка)      /boards/{board_id}/columns/{id}
    │   └── Subcolumn         /columns/{column_id}/subcolumns/{id}
    └── Lane (дорожка)        /boards/{board_id}/lanes/{id}
```

Карточка живёт в пересечении «колонка × дорожка» одной доски: `board_id` + `column_id` + `lane_id`. Подколонка — та же сущность колонки с заполненным `column_id` (ссылка на родительскую колонку), отдельного типа у неё нет. Пространства складываются в дерево через `parent_entity_uid` вместе с документами, папками и story map (см. Tree entities).

> **⚠️ Префикс пути обязателен и несимметричен.** Замеры: `PATCH /columns/{id}` → **404**, `PATCH /lanes/{id}` → **404**, `PATCH /boards/{id}` → **405**. Колонки и дорожки правятся только из-под доски, доска — только из-под пространства, а подколонки — из-под колонки без доски.

### Spaces (Пространства)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/spaces` | Создать пространство |
| GET | `/spaces` | Список пространств **с вложенными досками** |
| GET | `/spaces/{space_id}` | Одно пространство (досок в ответе нет) |
| PATCH | `/spaces/{space_id}` | Обновить пространство |
| DELETE | `/spaces/{space_id}` | Удалить пространство (возвращает `{"id": N}`, параметра `force` нет) |

```json
POST /spaces
{
  "title": "Team space",
  "external_id": "team-2026",
  "parent_entity_uid": "{uuid родителя в дереве}",
  "for_everyone_access_role_id": "{uuid роли}",
  "sort_order": 5.75
}
```

`title` — обязательный, 1–256. PATCH принимает `title`, `external_id`, `hidden_card_type_uids`, `settings`, `access` (`for_everyone` | `by_invite`), `parent_entity_uid` (перенос по дереву), `sort_order`; по схеме `anyOf` в теле обязано быть одно из первых трёх, то есть «поменять только `access`» без них не выйдет. Поле `allowed_card_type_ids` помечено Deprecated — вместо него `hidden_card_type_uids`.

> **⚠️ `GET /spaces` — тяжёлый:** в каждое пространство вложен массив досок, ни `limit`, ни фильтра по названию нет. Замер на крупной инсталляции: 331 пространство = **2.8 МБ** в одном ответе. Чтобы найти пространство по имени, дешевле `GET /tree-entities` (22 КБ).

### Boards (Доски)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/spaces/{space_id}/boards` | Создать доску |
| GET | `/spaces/{space_id}/boards` | Все доски пространства (без карточек) |
| GET | `/spaces/{space_id}/boards/{id}` | Доска + карточки, лежащие на ней |
| PATCH | `/spaces/{space_id}/boards/{id}` | Обновить доску |
| DELETE | `/spaces/{space_id}/boards/{id}` | Удалить доску (нужен `{"force": true}`) |
| GET | `/boards/{id}` | Доска без указания пространства — **со всеми карточками, включая архивные** |

```json
POST /spaces/{space_id}/boards
{
  "title": "Tasks",
  "columns": [
    {"title": "Sprint backlog", "type": 1},
    {"title": "In Progress",    "type": 2, "wip_limit": 5},
    {"title": "Done",           "type": 3, "archive_after_days": 120, "rules": 1}
  ],
  "lanes": [{"title": ""}],
  "default_card_type_id": 0,
  "auto_assign_enabled": true
}
```

Поля доски: `title` (обязательное, 1–128), `description`, `columns[]`, `lanes[]`, `top`/`left` (координаты на холсте пространства), `default_card_type_id`, `default_tags`, `first_image_is_cover`, `reset_lane_spent_time`, `automove_cards` (двигать карточку по состоянию дочерних), `backward_moves_enabled`, `move_parents_to_done`, `auto_assign_enabled` (автор становится участником при переносе карточки в колонку «в работе»/«готово»), `hide_done_policies`, `cell_wip_limits`, `card_properties`, `sort_order`, `external_id`, `type` (`1` — лежит на пространстве по координатам, `5` — приколота сбоку вкладкой), `move_from_space_id` (перенос доски в другое пространство).

> **⚠️ Пустой массив `columns` или `lanes` — ошибка, а не «создать без колонок».** Если ключ не передавать вовсе, Kaiten заведёт одну колонку и одну дорожку сам. Доска без колонки и дорожки не попадает в списочные ответы — её видно только запросом по id.

> **⚠️ Колонки и дорожки через `PATCH` доски не правятся** — их массивы принимает только `POST` при создании. Дальше только `/boards/{board_id}/columns` и `/boards/{board_id}/lanes`.

> **⚠️ `GET /boards/{id}` тянет всю доску целиком.** Замер: 8.2 МБ, 1081 карточка, 1.77 с — против 12 КБ и 0.29 с у `GET /spaces/{space_id}/boards`, где лежат те же настройки (`card_properties`, `default_card_type_id`, флаги) и ни одной карточки. Если нужны настройки, а не карточки — второй запрос дешевле в сотни раз.

> **⚠️ Встроенный в объект доски `columns[]` — короткая форма.** В нём есть `id`, `title`, `type`, `sort_order`, `col_count`, `column_id`, `rules`, `pause_sla`, `subcolumns[]` и **нет** `wip_limit`, `wip_limit_type`, `archive_after_days`, `card_hide_after_days`, `last_moved_warning_*`, `default_tags`. Замер: у колонки с WIP-лимитом 12 в объекте доски этого поля просто нет — читая `.columns[].wip_limit`, получишь `null` и решишь, что лимита нет. За лимитами — только `GET /boards/{board_id}/columns`.

### Columns (Колонки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/boards/{board_id}/columns` | Создать колонку |
| GET | `/boards/{board_id}/columns` | Колонки доски **вместе с подколонками** |
| PATCH | `/boards/{board_id}/columns/{id}` | Обновить колонку |
| DELETE | `/boards/{board_id}/columns/{id}` | Удалить колонку (нужен `force`) |

| Поле | Тип | Что значит |
|------|-----|------------|
| `title` | string | обязательное при POST, 1–128 |
| `type` | enum | `1` — очередь, `2` — в работе, `3` — готово |
| `wip_limit` | integer \| null | рекомендованный лимит; `null` — снять |
| `wip_limit_type` | enum | `1` — по числу карточек, `2` — по сумме размеров |
| `rules` | integer | битовая маска: `1` — нельзя вынести карточку с незакрытым чек-листом, `2` — показывать FIFO-порядок |
| `archive_after_days` | integer | автоархив через N дней; **работает только при `type: 3`** |
| `card_hide_after_days` | integer \| null | прятать карточки, не двигавшиеся N дней |
| `last_moved_warning_after_days` / `_hours` / `_minutes` | integer | когда на залежавшейся карточке появится предупреждение |
| `col_count` | integer | ширина колонки на экране |
| `sort_order` | number | > 0, абсолютная позиция |
| `prev_column_id` / `next_column_id` | integer \| null | только PATCH: переставить колонку относительно соседа; `null` — в начало / в конец |
| `default_tags` | string \| null | только PATCH: теги по умолчанию для новых карточек |
| `pause_sla` | boolean | останавливать таймер SLA в этой колонке |

```json
GET /boards/{board_id}/columns
[
  {"id": 1, "title": "Sprint backlog", "type": 1, "wip_limit": null, "rules": 0, "archive_after_days": -1, "subcolumns": []},
  {"id": 2, "title": "In Progress",    "type": 2, "wip_limit": 12,   "rules": 0, "archive_after_days": -1,
   "subcolumns": [
     {"id": 3, "title": "Doing",   "type": 2, "column_id": 2},
     {"id": 4, "title": "On hold", "type": 2, "column_id": 2}
   ]},
  {"id": 5, "title": "Done", "type": 3, "wip_limit": null, "rules": 1, "archive_after_days": 120, "subcolumns": []}
]
```

> **⚠️ `months_to_hide_cards` выведено из схем** — с конца августа 2026 колонки используют только `card_hide_after_days`.

> **⚠️ `402` на WIP-лимитах:** `{"message": "Your tariff doesn't include 'Wip limits' feature for columns"}`. Легко перепутать с ошибкой тела запроса. То же возможно у дорожек.

### Subcolumns (Подколонки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/columns/{column_id}/subcolumns` | Создать подколонку |
| GET | `/columns/{column_id}/subcolumns` | Подколонки колонки |
| PATCH | `/columns/{column_id}/subcolumns/{id}` | Обновить подколонку |
| DELETE | `/columns/{column_id}/subcolumns/{id}` | Удалить (нужен `force`) |

Поля те же, что у колонки. **Подколонки — единственная сущность структуры доски, которая адресуется без `board_id`.** Читать их удобнее не отдельным запросом, а из `GET /boards/{board_id}/columns`: там они уже вложены в `subcolumns[]` каждой колонки.

> **⚠️ WIP-лимит подколонки через API не задать** — ни в схеме POST, ни в PATCH нет `wip_limit` / `wip_limit_type`, хотя в ответе эти поля есть (всегда `null`). Лимит ставится только на родительскую колонку.

### Lanes (Дорожки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/boards/{board_id}/lanes` | Создать дорожку |
| GET | `/boards/{board_id}/lanes?condition=1` | Дорожки доски (`1` — живые, `2` — архивные, `3` — удалённые) |
| PATCH | `/boards/{board_id}/lanes/{id}` | Обновить дорожку |
| DELETE | `/boards/{board_id}/lanes/{id}` | Удалить (нужен `force`) |

Поля: `title` (обязательное при POST, 1–128), `sort_order`, `wip_limit`, `wip_limit_type`, `row_count`, `last_moved_warning_after_days` / `_hours` / `_minutes`; только в PATCH — `default_tags`, `default_card_type_id`, `condition`.

> **⚠️ Архивирование дорожки — это `PATCH {"condition": 2}`, а не `DELETE`.**

> **⚠️ У дорожек нет `prev_lane_id` / `next_lane_id`** — переставлять можно только через `sort_order`, дробное число между соседями придётся считать самому.

### `card_properties` доски — какие поля карточки обязательны

**Где читается:** `GET /spaces/{space_id}/boards`, `GET /spaces/{space_id}/boards/{id}`, `GET /boards/{id}`, `GET /spaces`.  
**Где пишется:** только `PATCH /spaces/{space_id}/boards/{id}`.

```json
"card_properties": [
  {"key": "size",      "required": true, "columnIds": [],     "cardTypeIds": [], "laneIds": []},
  {"key": "id_12345", "required": true, "columnIds": [678], "cardTypeIds": [], "laneIds": []}
]
```

| Поле | Смысл |
|------|-------|
| `key` | `"size"` — встроенная оценка карточки (поле `size_text`); `"id_{property_id}"` — кастомное свойство компании |
| `required` | требовать заполнения |
| `columnIds` | сузить требование до этих колонок. **Пустой массив = все колонки** |
| `cardTypeIds` | сузить до этих типов карточек. Пустой = все типы |
| `laneIds` | сузить до этих дорожек. Пустой = все дорожки |

**Правило разбора:** свойство обязательно для карточки, когда `required == true` **и** (`columnIds` пуст **или** содержит колонку карточки), и то же самое для `cardTypeIds` и `laneIds`. Чтение одного флага `required` даёт ложные срабатывания на досках, где требования сужены по колонкам.

> **⚠️ Доска может требовать свойство, отключённое на уровне компании.** У свойства `condition: "inactive"` поля в карточке просто нет, заполнить его невозможно. Список требований доски надо пересекать с активными свойствами из `GET /company/custom-properties`.

> **⚠️ `key` — не имя свойства.** Человекочитаемое название живёт только в `/company/custom-properties`; без сопоставления агент напишет в комментарий «не заполнено id_12345».

> **⚠️ Разбирай `card_properties` устойчиво к форме.** В примерах официальной документации поле показано одиночным объектом, тип описан как `null | array of objects`; на живом API приходит массив. Безопасный разбор — `.card_properties // [] | if type == "object" then [.] else . end`. И имейте в виду опечатку документации: в таблице ответа поле названо `columnsIds`, правильно — `columnIds`.

> **⚠️ Запись, судя по схеме, заменяет весь массив целиком** (merge-семантики нет, `null` очищает все правила): прочитать → изменить → отправить целиком. **Эмпирически не проверено** — первый раз пробуй на тестовой доске.

### Tree entities (дерево сущностей) — BETA

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/tree-entities` | Плоский список сущностей левого меню |
| GET | `/tree-entity-roles` | Роли доступа к сущностям дерева (только чтение) |

Один эндпоинт возвращает вперемешку четыре типа: `space`, `document`, `document_group` (папка), `story_map`. Связь родитель–потомок — через `parent_entity_uid`, путь до корня — в `path`. Параметры: `limit` (default/max 500), `offset`, `parent_entity_uid`, `levels_count` (**максимум 2**).

> **Зачем это агенту:** дешёвый поиск пространства по названию. Замер: `GET /spaces` = 2.8 МБ, `GET /tree-entities?limit=500` = 22 КБ. Фильтра по названию нет — отбирай на клиенте. У документов и папок числового `id` нет вовсе, только `uid`.

`GET /tree-entity-roles` отдаёт матрицу прав по типам сущностей вплоть до **отдельного кастомного свойства** (`permissions.space.card.properties.id_*`). Этим объясняется ситуация «токен видит карточку, но не видит одно её свойство» — это не баг скрипта.

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
| GET | `/cards/{id}/location-history` | История перемещений по колонкам и доскам |
| GET | `/cards/{id}/activity` | Лента событий карточки с авторами |
| GET | `/cards/{id}/allowed-users` | Кто имеет доступ к карточке |

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
    "id_{property_id}": [{select_value_id}]
  }
}
```

Полный список полей, которые принимают `POST /cards` и `PATCH /cards/{id}`: `title`, `asap`, `due_date`, `due_date_time_present`, `sort_order`, `description`, `expires_later`, `size_text`, `board_id`, `column_id`, `lane_id`, `owner_id`, `type_id`, `service_id`, `blocked`, `condition`, `external_id`, `text_format_type_id`, `sd_new_comment`, `owner_email`, `prev_card_id`, `estimate_workload`, `properties`. Всё остальное — молча игнорируется (см. «Общие правила»).

> **⚠️ Ключ свойства — обязательно `id_{property_id}`**, значение для `select` — массив id значений даже при одиночном выборе. Любой другой ключ отбивается с 400.

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

> **⚠️ Архив выпадает из выдачи.** Если у колонки «Готово» настроен `archive_after_days`, карточки старше этого срока уезжают в архив и в `GET /cards` без `archived=true` их нет. Метрики на длинном горизонте без этого флага занижены.

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

> **⚠️ Фильтра по значению кастомного свойства нет.** `GET /cards?id_{property_id}=<value_id>` молча игнорируется. Единственный способ спросить «какие карточки носят это значение» — выгрузить карточки и отфильтровать на клиенте (исключение — записи справочников, см. Custom Directories).

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
  "type": 1  // 1 - member (участник), 2 - responsible (ответственный)
}
```

Перед назначением ответственного стоит убедиться, что человек вообще видит карточку: `GET /cards/{card_id}/allowed-users` (параметры `type` = `sd-owners` | `virtual-users` | `mention`, `search`, `role`, `orderBy`, `limit`/`offset`). Возвращает урезанный профиль без прав и ролей.

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

Длина текста — до 4096 символов (замер), при превышении 400 `Comment text must not exceed 4096 characters`. У комментария есть `uid` — он нужен для файлов с ограниченным доступом.

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
| GET | `/cards/{card_id}/checklists/{id}` | Получить один чек-лист |
| PATCH | `/cards/{card_id}/checklists/{id}` | Обновить чек-лист или перенести его на другую карточку |
| DELETE | `/cards/{card_id}/checklists/{id}` | Снять чек-лист с карточки |

> **⚠️ Списочного `GET /cards/{card_id}/checklists` нет** — замер даёт **405** (путь есть, метод не поддерживается). Чек-листы карточки приходят в теле `GET /cards/{id}` в поле `checklists`; у карточки без чек-листов поля может не быть, а `?additional_card_fields=checklists` возвращает `null`.

### Создание чек-листа

```json
POST /cards/{card_id}/checklists
{
  "name": "Подзадачи",
  "sort_order": 1
}
```

Валидация — `anyOf`: обязателен `name` (1–1024) **или** `source_share_id`. Дополнительно принимаются `items_source_checklist_id` (скопировать пункты другого чек-листа), `exclude_item_ids` и недокументированный `policy_id`.

| | Расшаривание (`source_share_id`) | Копирование (`items_source_checklist_id`) |
|---|---|---|
| id чек-листа | **тот же** | новый |
| id пунктов | **те же** | новые |
| отметки `checked` | общие для всех карточек | сбрасываются в `false` |
| правка пункта | видна на всех карточках | локальная |

Расшаренные чек-листы карточки перечислены в её поле `parent_checklist_ids`. `DELETE /cards/{card_id}/checklists/{id}` снимает чек-лист **только с этой карточки** — на остальных он остаётся вместе с пунктами и отметками (замер). `source_share_id` без прав на исходный чек-лист → 403.

`PATCH` чек-листа принимает, помимо `name` и `sort_order`, поле **`card_id` — это перенос чек-листа на другую карточку**.

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
  "checked": false,
  "sort_order": 1,
  "due_date": "2026-08-25",
  "responsible_id": 123456
}
```

`text` — 1–4096, обязателен при создании. `due_date` — `YYYY-MM-DD` или `null`. `PATCH` требует хотя бы одно из `text`, `checked`, `due_date`, `sort_order`, `responsible_id`, `checklist_id`; **`checklist_id` в теле переносит пункт в другой чек-лист**.

### Карточко-независимые маршруты

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/checklists/{id}?only_shared_cards={bool}` | Карточки, на которых висит этот чек-лист |
| POST | `/checklists/{checklist_id}/items` | Добавить пункт |
| PATCH | `/checklists/{checklist_id}/items/{id}` | Изменить пункт |
| DELETE | `/checklists/{checklist_id}/items/{id}` | Удалить пункт |

Схема тела совпадает с карточными маршрутами — это тот же обработчик без карточки в пути. Удобно, когда скрипт знает id чек-листа, но не знает карточку. `GET /checklists/{id}` возвращает **массив полных объектов карточек**, а не сам чек-лист; параметр `only_shared_cards` обязателен (без него 400), но на видимый результат не влияет (замер).

---

## Space Template Checklists (шаблоны чек-листов пространства)

Именованные заготовки чек-листов, живущие **в пространстве**. Из них в интерфейсе собираются чек-листы карточек.

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/spaces/{space_uid}/template-checklists` | Создать шаблон |
| GET | `/spaces/{space_uid}/template-checklists` | Список шаблонов **вместе с пунктами** |
| PATCH | `/spaces/{space_uid}/template-checklists/{uid}` | Переименовать / переставить |
| DELETE | `/spaces/{space_uid}/template-checklists/{uid}` | Удалить шаблон |
| POST | `/spaces/{space_uid}/template-checklists/{uid}/items` | Добавить пункт |
| PATCH | `/spaces/{space_uid}/template-checklists/{uid}/items/{item_uid}` | Изменить пункт |
| DELETE | `/spaces/{space_uid}/template-checklists/{uid}/items/{item_uid}` | Удалить пункт |

`name` — 1–512, обязателен при создании шаблона; `text` пункта — 1–4096; `sort_order` > 0. `DELETE` возвращает `{"uid": "..."}`.

> **⚠️ `space_uid` — это UUID, а не числовой id пространства** (с числовым — 404). UUID берётся из `GET /spaces` → поле `uid`.

> **⚠️ Серверного «применить шаблон к карточке» не существует.** Перебором (замер): `GET /template-checklists/{id}` → 404, `GET /cards/{id}/template-checklists` → 404, `POST /cards/{id}/checklists/from-template` → 404, `POST /spaces/{uid}/template-checklists/{uid}/apply` → 404, `GET /spaces/{uid}/template-checklists/{uid}` → 405. Копировать пункты приходится на клиенте: прочитать шаблон → `POST /cards/{id}/checklists` → по одному `POST` на каждый пункт.

> **⚠️ `items_source_checklist_id` шаблон не принимает** — это id **карточного** чек-листа; id шаблона там даёт 403. Недокументированный `policy_id` принимается и сохраняется, но **пунктов не копирует**; несуществующий `policy_id` роняет запрос в **500**. Единственная его польза — потом понять, из какого шаблона собран чек-лист; код должен переживать его исчезновение.

В ответе у шаблона и у каждого пункта, кроме `uid`, приходит недокументированный числовой `id` — это и есть `policy_id` карточного чек-листа.

Автоподстановка шаблона при попадании карточки в колонку настраивается **автоматизацией** (действие `add_template_checklists`), а не этими маршрутами.

---

## Card Files (Файлы)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| PUT | `/cards/{card_id}/files` | Прикрепить файл (multipart, одно поле `file`, один файл на запрос) |
| GET | `/cards/{card_id}/files` | Список файлов карточки |
| PATCH | `/cards/{card_id}/files/{id}` | Обновить файл (`card_cover`) |
| DELETE | `/cards/{card_id}/files/{id}` | Открепить файл |

```bash
curl -X PUT "https://{domain}/api/latest/cards/{card_id}/files" \
  -H "Authorization: Bearer {token}" \
  -F "file=@/path/to/report.md"
```

Ответ — объект файла: `id`, `name`, `size`, `type`, `url`, `card_id`, `comment_id`, `author_id`, `card_cover`, `sort_order`, `deleted`, `external`, `created`, `updated`.

**Значения `type`:** `1` — обычное вложение карточки, `2–6` — внешние облака (googleDrive, dropBox, box, oneDrive, Яндекс.Диск), `7` — письмо из комментария, `8` — вложение комментария, `11` — файл с ограниченным доступом.

> **⚠️ Ссылка из `url` публична.** Замер: запрос к `https://files.kaiten.ru/<uuid>.<ext>` **без заголовка Authorization** возвращает 200 и сам файл. Ссылки на вложения нельзя класть в отчёты, spike-файлы и комментарии за пределами Kaiten.

> **⚠️ `403` здесь двусмысленный.** Кроме нехватки прав он означает, что компания включила запрет старой загрузки: тело `{"code": "PUBLIC_API_LEGACY_FILE_UPLOAD_DISABLED", "message": "Uploading files outside of restricted file access is disabled for the public API by company settings."}`. Запрет касается только multipart-загрузок (`POST|PUT /cards/{id}/files`, `POST|PUT /cards/{id}/comments` и `PATCH` комментария с `files[]`); правка текста комментария, переименование и удаление файла продолжают работать. Скрипты обязаны проверять HTTP-код: иначе прикрепление тихо не произойдёт.

### Restricted Access Files (файлы с ограниченным доступом) — BETA

Новая модель файлов, которая заменит текущую. Постоянной публичной ссылки у файла нет: права проверяются по родительской сущности, а на скачивание выдаётся временная подписанная ссылка. Включается настройкой **уровня компании**; ранее загруженные файлы автоматически не конвертируются.

Три семейства маршрутов — по родительской сущности файла:

| Родитель | Базовый путь |
|----------|--------------|
| Карточка | `/cards/{card_uid}/files` |
| Комментарий | `/cards/{card_uid}/comments/{comment_uid}/files` |
| Кастомное свойство | `/cards/{card_uid}/custom-properties/{property_uid}/files` |

На каждом из них — одни и те же пять операций:

| Метод | Путь | Описание |
|-------|------|----------|
| POST | базовый путь | Загрузить файл (multipart, поле `file`) |
| GET | `.../{id}` | Метаданные + подписанная ссылка в поле `url` |
| GET | `.../{id}/content` | 302 на подписанную ссылку (`?download=true` — отдать вложением) |
| PATCH | `.../{id}` | Переименовать / сделать обложкой |
| DELETE | `.../{id}` | Удалить |

**Все идентификаторы в пути — UUID.** `card_uid` берётся из `GET /cards/{card_id}` (поле `uid`), `comment_uid` — из комментария, `property_uid` — из `GET /company/custom-properties`.

> **⚠️ Самая опасная ловушка миграции: загрузка не падает при неправильном идентификаторе.** `POST` с числовым `card_id` вернёт 200 — запрос уйдёт на старый маршрут и создаст обычный файл с постоянной публичной ссылкой. Проверять надо не код ответа, а то, что в пути стоит UUID.

> **⚠️ Подписанная ссылка живёт секунды** (в примере документации `X-Amz-Expires=15`). Запрашивать её надо непосредственно перед скачиванием; кэшировать, сохранять в базу или класть в отчёт нельзя. Токен Kaiten нужен только для запроса к Kaiten — на саму подписанную ссылку его отправлять не надо.

| Признак | Текущий файл | Файл с ограниченным доступом |
|---------|--------------|------------------------------|
| `type` | `1` / `8` | `11` |
| `id` | число | **UUID-строка** |
| `size` | число | **строка** |
| `entity_type` | нет | `card` / `comment` / `custom_property` |
| `url` | постоянная публичная ссылка | нет поля |

Массив `files` карточки может содержать файлы обоих поколений одновременно, поэтому `id` файла надо считать непрозрачной строкой. Новые коды ответов: `413` — файл больше лимита инсталляции, `422` — файл признан вредоносным (антивирус), приходит на `GET /{id}` и `GET /{id}/content`.

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

```json
POST /cards/{card_id}/time-logs
{
  "role_id": -1,
  "time_spent": 90,
  "for_date": "2026-08-20",
  "comment": "Разбор задачи"
}
```

| Поле | Ограничения |
|------|-------------|
| `role_id` | **обязательное.** Предопределённая роль `-1` — Employee, остальные — из `GET /user-roles` |
| `time_spent` | **обязательное**, минуты, минимум 1 |
| `for_date` | **обязательное**, `YYYY-MM-DD` |
| `comment` | до 4096 |

> **⚠️ `user_id` задать нельзя** — время всегда пишется на владельца токена (`author_id` — кто внёс запись, `user_id` — кому засчитано). Списать время за коллегу через API не выйдет.

> **⚠️ `for_date` возвращается по-разному:** в POST/PATCH — полным ISO (`"2026-08-20T00:00:00.000Z"`), в GET — как `"2026-08-20"`. Строки сравнивать напрямую нельзя.

`GET` принимает `for_date` и `personal` (boolean). Все методы, кроме GET, отдают `402`, если тариф не включает Time logs. Суммарные значения доступны и без этого раздела — в объекте карточки есть `time_spent_sum` и `time_blocked_sum` (минуты).

---

## Card Children (Дочерние карточки)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/cards/{card_id}/children` | Добавить дочернюю карточку |
| GET | `/cards/{card_id}/children` | Получить дочерние карточки |
| GET | `/cards/{card_id}/parents` | Получить родительские карточки |
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

Ссылка хранит только `url` (до 16384) и `description` (до 512). Заголовок страницы, картинку и прочее превью API не отдаёт и не подтягивает.

---

## Card SLA

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/cards/{card_id}/sla-rules-measurements` | Замеры времени по SLA-правилам карточки |

Единственный эндпоинт раздела: API для создания и правки самих SLA-правил и рабочих календарей не опубликовано, правила настраиваются в интерфейсе и вешаются на карточку действием автоматизации `card_add_sla`. Ответ — `calendars` (часовой пояс, рабочие дни, праздники) и `rulesTimeData` (`rule_id`, `actual_time` в секундах рабочего времени, `started`, `completed`, `last_calculated_at`).

> **⚠️ SLA существует только для обращений Service Desk.** На обычной карточке разработки эндпоинт отвечает **`400`** `{"message": "Only service desk request can have sla time data"}` — не пустым массивом, так что слепой разбор ответа падает. Архивная карточка → `400 "Cant't provide sla time data for archived card"` (опечатка со стороны Kaiten).

> **⚠️ Порог правила в ответе не приходит** — только фактически потраченное время. Понять «уложились или нет» одним этим эндпоинтом нельзя. Массового варианта нет: один запрос на карточку. Время карточки в колонке измеряется дешевле и надёжнее по `GET /cards/{id}/location-history`.

---

## Users (Пользователи)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/users` | Список пользователей, доступных вызывающему |
| GET | `/users/current` | Текущий пользователь (по токену) |
| PATCH | `/users/{id}` | Обновить личные настройки пользователя |

Параметры `GET /users`: `query` (поиск по `full_name`, `email`, `username`), `ids`, `type`, `access_type_permissions`, `include_inactive`, `limit` (default/max 100), `offset`.

> **⚠️ Пагинация обязательна:** `limit=200` молча вернёт 100 записей.

> **⚠️ `ids` молча теряет записи.** В ответ попадают только пользователи, видимые вам (состоящие в общих пространствах). Длина ответа не равна длине запрошенного списка, и отсутствие человека в выдаче не значит, что его нет в компании.

> **⚠️ `query` ищет по тому, что записано в профиле.** Кириллический и латинский варианты имени не связаны: если в профиле `Ivan Petrov`, запрос кириллицей не найдёт ничего. Надёжнее искать по email.

Ключевые поля: `id`, `uid`, `full_name`, `email`, `username` (то, чем упоминают через `@`), `role` (1 — владелец компании, 2 — пользователь, 3 — деактивирован), `permissions` (битовая маска прав, см. Groups), `apps_permissions` (0 — нет доступа, 1 — полный Kaiten без Service Desk, 2 — гость без SD, 4 — только SD, 5 — полный + SD, 6 — гость + SD), `external`, `activated`, `last_request_date`.

`PATCH /users/{id}` меняет только личные настройки профиля (`username`, `full_name`, `initials`, `password`, `lng`, `timezone`, `theme`, `default_space_id`, настройки уведомлений) — к работе с карточками отношения не имеет.

### Company Users

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/company/users` | Полный список пользователей компании |
| PATCH | `/company/users/{id}` | Изменить доступ (`apps_permissions`, `temporarily_inactive`) |
| DELETE | `/company/users/{id}` | Удалить виртуального пользователя |

Видит всю компанию и отдаёт больше данных, чем `/users`: `spaces` (где человек и с какой ролью), `groups`, `own_permissions` против унаследованных `permissions`, `work_time_settings`.

> **⚠️ Требует доступа к административному разделу «Участники» (бит `1` в `permissions`)** — обычному командному токену отдаёт `403`. Для задачи «найти человека» используйте `/users`.

> **⚠️ Фильтры (`query`, `group_ids`, `permissions`, …) работают только вместе с `for_members_section`.** Без него они игнорируются.

### Space Users (участники пространства)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/spaces/{space_id}/users` | Пригласить пользователя в пространство |
| GET | `/spaces/{space_id}/users` | Список участников с ролями |
| GET | `/spaces/{space_id}/users/{id}` | Участник |
| PATCH | `/spaces/{space_id}/users/{id}` | Сменить роль / настройки уведомлений |
| DELETE | `/spaces/{space_id}/users/{id}` | Удалить из пространства (может ответить `409` без тела) |

**Преднастроенные роли доступа** передаются строкой-UUID в `role_id`:

| Роль | UUID | Числовой `own_role` |
|------|------|---------------------|
| reader (комментатор) | `06ccb31f-426b-4fa3-b7e5-861daee95696` | 1 |
| writer | `a431ed00-1b32-4cc7-92b6-85e4bc7de40e` | 2 |
| admin | `07ea3efc-a004-4d31-8683-4bb2084e209b` | 3 |

В `POST` обязателен только `email`; `PATCH` требует минимум `role_id` **или** `space_group_id`. `GET` принимает `include_inherited_access` и `inactive`.

> **⚠️ Различайте `own_*` и обычные поля.** `own_role_ids` / `own_access_mod` — что выдано человеку лично; `role_ids` / `access_mod` — с учётом наследования от родительского пространства и групп. Снимая доступ, можно убрать только личную выдачу и оставить унаследованную.

**Зачем агенту:** `GET /spaces/{space_id}/users` — готовый ответ на «кто в пространстве и с какой ролью», замена ручному сопоставлению имён при назначении ответственных. Роль `3` (admin) в пространстве нужна для чтения его вебхуков.

### User Roles (должности)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/user-roles` | Создать роль |
| GET | `/user-roles` | Список ролей |
| GET | `/user-roles/{role_id}` | Получить роль |
| PATCH | `/user-roles/{role_id}` | Переименовать |
| DELETE | `/user-roles/{role_id}` | Удалить (**требует тело** `{"replace_role_id": N}`) |

Единственное поле — `name` (1–64), уникальное в компании. Предопределённая роль `Employee` имеет `id: -1`.

> **⚠️ Это не роли доступа к пространству, а должности** (для учёта времени и ресурсов). UUID ролей доступа (`reader` / `writer` / `admin`) в этом списке отсутствуют — подставлять `uid` из `/user-roles` в `role_id` при приглашении в пространство нельзя.

### Groups (группы)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST \| GET \| PATCH \| DELETE | `/company/groups[/{uid}]` | CRUD групп |
| POST \| GET \| DELETE | `/groups/{group_uid}/users[/{user_id}]` | Участники группы |
| POST \| GET \| DELETE | `/groups/{group_uid}/admins[/{user_id}]` | Админы группы |
| POST \| GET \| PATCH \| DELETE | `/company/groups/{group_uid}/entities[/{uid}]` | Доступ группы к сущностям (`space`, `document`, `document_group`, `story_map`) |

> **⚠️ Разные префиксы:** сама группа и её сущности — под `/company/groups/...`, а пользователи и админы группы — под `/groups/{group_uid}/...` **без** `company`. Легко перепутать и получить 404.

> **⚠️ `402`, если тариф не включает группы.** Ещё одна частая ошибка — `400 "Only paid user can be added to groups"`.

**Битовая маска `permissions`** (объясняет и поле `permissions` в профиле пользователя, и `403` на административных маршрутах):

| Право | Значение | Право | Значение |
|-------|----------|-------|----------|
| Админ-раздел «Участники» | 1 | Приглашать пользователей в компанию | 1024 |
| Админ-раздел «Биллинг» | 2 | Настройки Service Desk | 2048 |
| Админ-раздел «Настройки компании» | 4 | Создавать кастомные свойства | 4096 |
| Админ-раздел «Пространства» | 16 | Публичный доступ к карточкам | 8192 |
| Админ-раздел «Типы карточек» | 32 | Карточки → обращения SD | 16384 |
| Админ-раздел «Табели» | 64 | Админ-раздел «Журнал действий» | 32768 |
| Читать чужие записи в табеле | 128 | Планирование ресурсов | 65536 |
| Админ-раздел «Экспорт данных» | 256 | Админ-раздел «Календари» | 131072 |
| Админ-раздел «Теги» | 512 | Аналитика / обращения Service Desk | 262144 / 524288 |

---

## Tags (Теги)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/tags` | Создать тег |
| GET | `/tags` | Получить список тегов |
| POST | `/cards/{card_id}/tags` | Повесить тег на карточку (по `name` или `id`) |
| DELETE | `/cards/{card_id}/tags/{tag_id}` | Снять тег с карточки |

> **⚠️ Переименования и удаления тега нет.** `PATCH /tags/{id}` и `DELETE /tags/{id}` не существуют: заведённое имя остаётся навсегда, опечатку исправить нечем. Проверяйте имя до создания.

**`POST /tags` идемпотентен по имени** (замер): повторный запрос с тем же `name` возвращает тот же `id` и прежний `created`, дубль не заводится. То же и у `POST /cards/{id}/tags` — тег с существующим именем подхватывается, а не создаётся заново.

> **⚠️ Тег, не привязанный ни к одной карточке, не виден ни в `GET /tags`, ни в поиске `?query=`** (замер). Цепочка: создали тег через `POST /tags` — в списке его нет; повесили на карточку — появился; сняли с последней карточки — снова пропал. Интерфейс ведёт себя так же и предлагает «Создать тег» для имени, которое на самом деле уже существует. Поэтому: заводить теги заранее бессмысленно, а проверять существование перед созданием надёжнее повторным `POST` (вернёт существующий `id`), чем поиском по списку.

Поиск `GET /tags?query=` работает по подстроке: `query=Glovo` находит и `Glovo`, и `mlc:aggregators:glovo-ng`.

---

## Custom Properties (Кастомные свойства)

> **⚠️ Маршрутов `/properties/*` не существует** (замер: 404). Настоящий префикс — `/company/custom-properties`.

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/company/custom-properties` | Создать свойство (общее на компанию) |
| GET | `/company/custom-properties` | Список свойств компании (поиск, пагинация) |
| GET | `/company/custom-properties/{id}` | Получить свойство |
| PATCH | `/company/custom-properties/{id}` | Обновить свойство |
| DELETE | `/company/custom-properties/{id}` | Погасить свойство (мягко, `condition: "removed"`) |

Параметры списка: `query` (поиск по имени), `compact`, `include_values`, `include_author`, `load_by_ids` + `ids`, `limit` (до 500), `offset`, `order_by` / `order_direction`.

> **Свойства общие на всю компанию, а не на пространство,** и имена не уникальны — дубли с одинаковым названием и разными типами обычное дело. Прежде чем заводить новое, ищите готовое: `GET /company/custom-properties?query=<кусок имени>` вместо выгрузки всего списка (на крупной инсталляции их больше тысячи).

### Типы свойств и форма значения на карточке

`type` задаётся **только при создании** и потом не меняется. Значение на карточке лежит в `properties["id_{property_id}"]`.

| Тип | Что это | Значение на карточке | Чем настраивается |
|-----|---------|----------------------|-------------------|
| `string` | Текст | `"строка"` | `multiline`, `data.restrictions.minLength/maxLength` |
| `number` | Число | `12` | `data.restrictions.min/max` |
| `date` | Дата | `{"date":"2026-06-22","time":null,"tzOffset":null}` | — |
| `email` | Почта | строка | — |
| `phone` | Телефон | строка | — |
| `url` | Ссылка | строка | — |
| `checkbox` | Галочка | `true` / `false` | — |
| `select` | Список | `[12345]` — **массив id значений даже при одиночном выборе** | `multi_select`, `colorful`, `values_creatable_by_users` + CRUD значений |
| `formula` | Вычисляемое поле | число, **только чтение** | `data.formula` |
| `catalog` | Многополевой справочник внутри свойства | id значения справочника | `fields_settings` + CRUD значений |
| `user` | Пользователь(и) | массив объектов пользователей | `multi_select` |
| `attachment` | Вложение | — | `data.restrictions.maxFilesCount`, `filesExtensions` |
| `vote` | Личный голос (виден только автору) | число | `vote_variant` + `data` |
| `collective_vote` | Командное голосование эмодзи/звёздами | — | `vote_variant` + `data` + CRUD голосов |
| `collective_score` | Командная оценка (каждый ставит своё) | строка, например `"3"` | `values_type` + CRUD оценок |

Формы значений сняты выгрузкой реальных карточек; для `catalog`, `attachment`, `collective_vote` и `phone` форма значения на карточке **не проверена**.

### Тело запроса

`name` (1–128), `type`, `show_on_facade`, `multiline`, `multi_select`, `colorful`, `values_creatable_by_users`, `values_type` (только `collective_score`), `vote_variant` (`rating` | `scale` | `emoji_set`, только `vote` / `collective_vote`), `color`, `fields_settings` (поля справочника типа `catalog`), `data`. Обязательность через `anyOf`: либо `name` + `type`, либо `formula` + `formula_source_card`.

`data` — тоже `anyOf`, ровно одна комбинация: `restrictions` (для `string` / `number` / `attachment`), `formula`, `emoji` + `count` (rating), `emojis` (emoji_set), `min` + `max` + `calculation_method` (scale).

`PATCH` дополнительно принимает `condition` (`active` | `inactive` — выключить свойство, не удаляя) и `is_used_as_progress`. `type` через PATCH не меняется.

**Формулы** лежат в `data.formula` и ссылаются на другие свойства **по имени**: `prop("Имя свойства")`. Поддерживаются арифметика, скобки, сравнения и тернарник. Формула видит только числовые свойства той же карточки — ни описания, ни чек-листов, ни дочерних карточек, ни истории.

> **⚠️ `DELETE` мягкий:** возвращает объект с `condition: "removed"`. Свойство пропадает из выбора, но проставленные значения на карточках остаются.

> **⚠️ `protected: true` — системное свойство:** PATCH и DELETE отдают 400 `Custom property is protected from updating` / `from removing`.

> **⚠️ В ответе полей больше, чем в схемах запроса** (`uid`, `directory_id`, `is_used_as_progress`, `calculation_method`, `import_uid`, `fts_version`). На запись рассчитывать нельзя: неизвестные поля верхнего уровня PATCH проглотит молча.

### Select Values (значения select-свойства)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST | `/company/custom-properties/{property_id}/select-values` | Создать значение |
| GET | `/company/custom-properties/{property_id}/select-values` | Список значений |
| GET | `/company/custom-properties/{property_id}/select-values/{id}` | Одно значение |
| PATCH | `/company/custom-properties/{property_id}/select-values/{id}` | Изменить значение |
| DELETE | `/company/custom-properties/{property_id}/select-values/{id}` | Удалить значение (см. предупреждение) |

```json
POST /company/custom-properties/{property_id}/select-values
{"value": "backend", "color": 8}
```

`value` — обязательное, 1–128. `PATCH` принимает `value`, `color`, `condition` (`active` | `inactive`), `sort_order`, `deleted`.

> **⚠️ Главная ловушка: без `v2_select_search=true` фильтры и `limit` молча игнорируются, а в выдаче лежат погашенные значения вперемешку с живыми.** Замер на свойстве со 108 значениями: `?limit=5` → 108, `?conditions=active` → 108, `?v2_select_search=true&limit=200` → 62 (только активные). Остальные параметры (`query`, `ids`, `conditions`, `order_by`, `limit`/`offset`) работают только вместе с этим флагом.

> **⚠️ `DELETE` отдаёт 403 даже автору значения. Гасить надо через `PATCH {"deleted": true}`** → в ответе `{"deleted": true, "condition": "removed"}`; обратно — `{"deleted": false}`.

> **⚠️ Дубль имени → 400** `Select value with this name already exists for property with id N`; сравнение точное, `Backend` и `backend` уживутся рядом. POST в свойство другого типа → 403.

### Catalog Values (значения свойства-справочника)

`POST | GET | PATCH | DELETE /company/custom-properties/{property_id}/catalog-values[/{id}]`. Значение — набор полей, а не строка: `{"value": {"{uuid поля}": "API"}}`, uuid берутся из `fields_settings` свойства. Фильтры (`query`, `conditions`, `limit`, `offset`) работают сразу, флага `v2_*` здесь нет. Удаление мягкое.

### Collective Score / Collective Vote (командные оценки и голоса)

Эти маршруты живут **на карточке**, а не на свойстве.

| Метод | Endpoint |
|-------|----------|
| POST \| GET \| PATCH | `/cards/{card_id}/custom-properties/{property_id}/collective-score-values[/{id}]` |
| POST \| GET \| PATCH \| DELETE | `/cards/{card_id}/custom-properties/{property_id}/collective-vote-values[/{id}]` |

`collective_score` — каждый участник ставит своё значение, `value` всегда строкой (1–512) независимо от `values_type`; `PATCH` с `null` обнуляет оценку, отдельного DELETE нет. `GET` — единственный способ увидеть, **кто** сколько поставил (`author_id` + развёрнутый `author`); в `properties["id_{pid}"]` карточки лежит просто строка.

`collective_vote` — голос задаётся ровно одним полем: `emoji_vote` (1–12 символов, для `vote_variant: emoji_set`) или `number_vote` (для `rating` / `scale`). `PATCH` меняет только `number_vote` — эмодзи-голос переставляется удалением и новым POST, причём **`DELETE` принимает тело** (`{"emoji_vote": "😄"}`), что нетипично для HTTP.

### Custom Property Tree Entities (к каким пространствам подключено свойство)

`POST | GET | DELETE /company/custom-properties/{property_id}/tree-entities[/{uid}]`, тело POST — `{"tree_entity_uid": "..."}`.

> **⚠️ Требует прав уровня компании** — обычному командному токену отдаёт `403` (замер), документированный `402` — отдельный случай (тариф). Ответ на «к каким доскам подключено свойство» через этот эндпоинт получить нельзя; остаётся обходить доски и читать их `card_properties`.

---

## Custom Directories (Справочники) — BETA

Справочник — отдельная сущность уровня компании: таблица со своими полями и записями, живущая вне карточек. Свойство карточки ссылается на неё, а сам справочник ведётся в одном месте. **Все идентификаторы здесь — UUID.**

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST \| GET \| PATCH \| DELETE | `/company/custom-directories[/{directory_id}]` | Справочники (DELETE мягкий) |
| POST \| GET \| PATCH \| DELETE | `/company/custom-directories/{directory_id}/fields[/{field_id}]` | Поля справочника |
| POST \| GET \| PATCH \| DELETE | `/company/custom-directories/{directory_id}/records[/{record_id}]` | Записи справочника |
| GET | `/company/custom-directories/{directory_id}/records/{record_id}/cards` | **Карточки, использующие эту запись** |

```json
POST /company/custom-directories
{
  "name": "Contacts",
  "multi_select": false,
  "allow_editing": false,
  "fields": [
    {"name": "Name", "type": "string", "required": true},
    {"name": "Email", "type": "email"}
  ]
}
```

```json
POST /company/custom-directories/{directory_id}/records
{"values": {"{uuid поля}": {"value_text": "Alice"}}}
```

**12 типов поля:** `string`, `number`, `date`, `email`, `url`, `phone`, `checkbox`, `select`, `user`, `catalog`, `directory_link`, `file`. Внутри значения — одно из типизированных полей: `value_text`, `value_number`, `value_date`, `select_value_uid`, `catalog_value_uid`, `user_uid`, `directory_record_id`. У POST/PATCH записей есть `response_profile` (`none` вернёт только `{id}` — экономит трафик при массовой заливке).

> **⚠️ `GET /records/{record_id}/cards` — единственный в Kaiten способ спросить «какие карточки носят это значение».** Для обычных `select`-свойств такого нет.

> **⚠️ `PATCH` справочника с `fields` заменяет список полей целиком** — поля, которых нет в массиве, гасятся. Отображаемое поле помечается `is_display: true` ровно у одного поля.

> **⚠️ Привязки полей `select`/`user`/`catalog` (`custom_property_uid`) и `directory_link` (`linked_directory_id`) через `POST /fields` не задаются** — только при создании или обновлении самого справочника.

> **⚠️ Ошибки этого раздела несут числовой `code`** (`1` — справочник не найден, `2` — запись не найдена, `4` — не заполнено обязательное поле, `6` — неверный тип поля). В остальном API кодов нет, только `message`. Удаление всюду мягкое (`condition: "removed"`), а удалить справочник, на который ссылается живое свойство, нельзя.

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
| GET | `/sprints` | Список спринтов компании |
| GET | `/sprints/{id}` | Полная сводка спринта: карточки, история их версий, кастомные свойства |

Параметры списка: `active` (boolean), `limit` (default/max 100), `offset`. У `/sprints/{id}` единственный параметр — `exclude_deleted_cards`.

Объект спринта: `id`, `uid`, `board_id` (спринт принадлежит **доске**), `title`, `goal`, `active`, `committed`, `velocity`, `velocity_details.by_members`, `children_committed`, `children_velocity`, `start_date`, `finish_date`, `actual_finish_date`, `archived`. В `/sprints/{id}` дополнительно приходят `cards` (полные объекты), `cardUpdates` (версии карточек во времени — готовый материал для burndown: видно и момент попадания карточки в спринт, и изменение оценки) и `customProperties`.

> **⚠️ Спринты в API только на чтение.** Ни POST, ни PATCH, ни DELETE для `/sprints` в документации нет — создать, закрыть или переименовать спринт можно только в интерфейсе.

> **⚠️ Требуется право `companyPermissions.entitiesTree`** (доступ к дереву сущностей компании) — обычному командному токену оба эндпоинта отдают `403` (замер).

> **⚠️ Назначить карточку в спринт через API нечем.** `sprint_id` есть в *ответе* `GET /cards`, но в схемах тела `POST /cards`, `PATCH /cards/{id}` и `PATCH /cards/batch` его нет. Неизвестные поля верхнего уровня PATCH глотает молча, поэтому `{"sprint_id": N}` выглядит успешным и не делает ничего.

---

## Iterations (Итерации) — BETA

Отдельная от спринтов сущность: **итерация живёт в пространстве**, не привязана к колонкам, а карточка попадает в неё отдельной записью-связкой. Платформа сама считает `committed` на старте и `velocity` на закрытии.

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET \| POST | `/spaces/{space_uid}/iterations` | Список / создать (создаётся со статусом `planned`) |
| GET \| PATCH \| DELETE | `/spaces/{space_uid}/iterations/{id}` | Получить / обновить / удалить (переводит в `removed`) |
| GET \| POST | `/spaces/{space_uid}/iterations/{iteration_id}/cards` | Записи о карточках итерации / добавить карточку |
| DELETE | `/spaces/{space_uid}/iterations/{iteration_id}/cards/{uid}` | Убрать карточку |
| GET | `/cards/{card_uid}/iterations-history` | В каких итерациях побывала карточка |

```json
POST /spaces/{space_uid}/iterations
{
  "title": "Итерация 2026-09-01",
  "goal": "Цель итерации",
  "start_date": "2026-09-01T00:00:00.000Z",
  "finish_date": "2026-09-14T00:00:00.000Z"
}
```

Жизненный цикл: `planned → active → closed`, обратных и «через ступеньку» переходов нет (`400 code 1`), активировать без дат нельзя (`code 2`). Закрытие с переносом хвостов:

```json
PATCH /spaces/{space_uid}/iterations/{id}
{
  "status": "closed",
  "actual_finish_date": "2026-09-14T18:00:00.000Z",
  "new_iteration_id": "{uuid следующей итерации}"
}
```

В ответ добавляется `moved_cards`. Статистика лежит в поле `data`: `committed` появляется при активации, `velocity` / `doneCount` / `totalCount` — при закрытии.

Карточку можно добавить только в `planned` или `active` итерацию и только если она активна и лежит на **основной доске пространства**. Если карточка уже состоит в другой активной итерации — она переезжает, второй связки не возникает. `DELETE` карточки не удаляет запись, а проставляет `removed_at` / `removed_by_uid`, то есть история «была в спринте и выпала» сохраняется.

> **⚠️ Везде UID, а не числовые id** (замер: с числовым `space_id` или `card_id` — 404). Фича тарифная: при выключенной отдаёт `402`.

> **⚠️ Числовые `code` в теле 400 локальны для эндпоинта** — `code 5` при удалении итерации и `code 5` при снятии карточки означают разное. Ориентируйся на пару «эндпоинт + код».

---

## Timesheet (Табель)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/time-logs` | Сводный табель по компании с фильтрами и группировкой |

> **⚠️ Пути `/timesheet` не существует** (замер: 404), несмотря на название раздела в документации.

`from` и `to` (`YYYY-MM-DD`) — обязательные, без них 400. Фильтры: `user_ids`, `group_ids`, `space_ids`, `board_ids`, `column_ids`, `card_ids`, `tag_ids`. Управление формой ответа: `group_by` (`0` — без группировки, `1` — по пользователю, `2` — по карточке), `with_daily_distribution`, `only_general_sum`, `limit` (до 200), `offset`.

В каждую запись табеля вложен **весь объект карточки** с доской, колонкой, дорожкой и владельцем — ответы очень тяжёлые, при массовой выгрузке сразу ставь `only_general_sum` или `group_by`. Требует прав уровня компании: обычному командному токену — `403` (замер).

---

## Automations (Автоматизации)

Автоматизация живёт **в пространстве**, а не на доске: привязка к доске и колонке задаётся условиями.

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/spaces/{space_id}/automations` | Список автоматизаций пространства |
| POST | `/spaces/{space_id}/automations` | Создать автоматизацию |
| PATCH | `/spaces/{space_id}/automations/{automation_uid}` | Обновить (тело без `type` — тип не меняется) |
| DELETE | `/spaces/{space_id}/automations/{automation_uid}` | Удалить |

| Поле | Описание |
|------|----------|
| `id` | UUID автоматизации |
| `name` | имя; в интерфейсе не обязательно, поэтому часто `null` |
| `type` | `on_action` — по событию, `on_date` — по дате, `on_demand` — по кнопке в карточке |
| `status` | `active`, `disabled`, `broken`, `removed` |
| `trigger` | что запускает; у `on_demand` — `null` |
| `conditions` | дерево условий (две вложенности групп с `clause`: `and` / `or`) |
| `actions` | что сделать с карточкой; порядок массива = порядок выполнения |
| `brokenLogs` | недокументированное: история поломок (`reason`, `subject`, `condition`, `subjectId`) |

**Триггеры (21, перечень проверен перебором):** `card_moved_in_path`, `card_created`, `comment_posted`, `card_user_added` (нужен `userIds`), `responsible_added` (`userIds`), `card_type_changed`, `card_state_changed`, `custom_property_changed`, `due_date_changed`, `checklist_item_checked`, `checklists_completed`, `child_cards_state_changed`, `tag_added`, `tag_removed`, `blocked`, `unblocked`, `blocker_added`, `due_date_on_date`, `checklist_item_due_date_on_date`, `custom_property_date_on_date`, `all_conditions_met`. Общее необязательное поле — `hasToFireOnCardCreation`. У датных триггеров в `trigger.data` — `variant`, `timezone`, `offset`, `offset_unit`.

**Действия и их обязательные `data`:**

| Действие | Обязательные `data` | Действие | Обязательные `data` |
|----------|---------------------|----------|---------------------|
| `add_assignee` / `remove_assignee` | — | `move_to_path` | `boardId`, `columnId`, `laneId` |
| `add_card_users` | — | `move_on_board` | `direction` (`next` / `prev`) |
| `remove_card_users` | `userIds`, `withResponsible` | `archive` | — |
| `add_user_groups` | `groupIds` | `add_child_card` / `add_parent_card` | `title` |
| `add_tag` | `tagNames` (**имена**) | `connect_parent_card` | `cardId` |
| `remove_tags` | `tagIds` (**id**) | `complete_checklists` | — |
| `add_property` | `propertyId` | `sort_cards` | `sortProperty` |
| `property_add_to_child_card` | `childLevel`, `customProperties` | `add_comment` | `text` |
| `add_size` | `size` | `card_add_sla` / `card_remove_sla` | `slaIds` |
| `add_timeline` | `startDate.apply_date_mode` | `change_type` (нет в документации) | `typeId` |
| `change_asap` | `asap` | `add_template_checklists` (нет в документации) | `checklistUids` |
| `add_due_date` / `remove_due_date` | `timezone`, `dueDate` / — | | |

```json
POST /spaces/{space_id}/automations
{
  "name": "Осмысленное имя",
  "type": "on_action",
  "trigger": {"type": "card_moved_in_path", "hasToFireOnCardCreation": false},
  "conditions": {
    "clause": "or",
    "conditions": [
      {"clause": "and", "conditions": [
        {"type": "new_path", "operator": "eq", "data": {"boardId": 1, "columnId": 2, "laneId": 3}}
      ]}
    ]
  },
  "actions": [{"type": "add_tag", "data": {"tagNames": ["AI"]}}]
}
```

Типы условий документация не перечисляет; подтверждены `new_path`, `path`, `card_type`, `tag`. Недокументированное `{"source_automation_id": "{uuid}"}` в POST копирует существующую автоматизацию.

> **⚠️ Несовместимое с триггером условие выбрасывается молча.** Ответ 200, а `conditions` в нём — `null`. Замер: `new_path` с триггером `card_moved_in_path` сохраняется, тот же `new_path` с `card_created` исчезает; опечатка в `type` условия даёт тот же эффект. Результат — автоматизация, срабатывающая на **каждой** карточке пространства. Всегда читай `conditions` в ответе и сверяй с отправленным.

> **⚠️ `DELETE` требует больше прав, чем создание.** Обычный токен участника создаёт и правит автоматизации, но на удаление получает `403` — откатить своё же создание нельзя, только погасить `PATCH {"status": "disabled"}` (в PATCH допустимы только `active` и `disabled`). Поэтому эксперименты с `POST` в живом пространстве недопустимы.

> **⚠️ `conditions: null` в PATCH не очищает условия** — поле игнорируется, старое дерево остаётся.

> **⚠️ Неизвестные поля верхнего уровня в PATCH дают 400** — в отличие от `PATCH /cards/{id}`, здесь схема строгая.

> **⚠️ Автоматизации ломаются молча.** Если доска, на которую ссылается условие, удалена, `status` становится `broken`, причина ложится в `brokenLogs`, и никаких уведомлений не приходит. Один `GET /spaces/{space_id}/automations` раз в спринт ловит и это, и ссылки на устаревшие доски.

> **⚠️ Вызвать внешний HTTP из автоматизации нельзя** — действий `webhook`, `send_email`, `notify` не существует. Также нет `add_checklist`, `unarchive`, `copy_card`, `create_card`, `add_time_log`, `change_state`, `add_blocker`.

`GET` списка **не возвращает** `created` и `updated` (они есть только в ответах POST/PATCH) — «когда автоматизацию правили» из списка не узнать, есть только `updater_id`.

---

## Webhooks — две разные механики

Под словом «webhook» в Kaiten скрываются две несвязанные вещи. Обе настраиваются в настройках **пространства** и действуют на всё пространство целиком.

| Что | Направление | Что делает |
|-----|-------------|-----------|
| **Webhooks** (входящие) | извне → в Kaiten | Даёт уникальный URL; POST с JSON на него **создаёт карточку**. Токен не нужен |
| **External Webhooks** (исходящие) | Kaiten → наружу | Kaiten шлёт POST на ваш URL при событиях в пространстве |

### Webhooks (входящие) — создать карточку без токена

Аутентификация — сам факт знания URL. Доска, колонка и тип карточки задаются **в интерфейсе при создании вебхука**, в теле их не выбрать: нужны две доски — заводите два вебхука. Поддерживаемые форматы входящего payload: Kaiten, Tilda, Jira, Airbrake, Sentry, Crashlytics.

```json
POST <your-webhook-url>
{
  "title": "Card title",
  "description": "Card Description",
  "asap": false,
  "due_date": "2026-05-04T00:00:00Z",
  "owner_id": 1,
  "members": [1, 2],
  "tags": ["bug"],
  "links": [{"url": "https://example.com", "description": "Link description"}],
  "properties": {"id_1": "test"}
}
```

`title` обязателен (1–1024), `description` — до 32768, `tags` — по именам (несуществующий тег будет создан), `links` уезжают во внешние ссылки, `properties` — в формате `id_{property_id}` (формы значений см. в разделе Custom Properties). Ответ — полный объект карточки.

> **⚠️ URL вебхука — это и есть секрет.** Кто его узнал, тот создаёт карточки в пространстве. Не класть в публичные репозитории и в клиентский код.

### External Webhooks (исходящие) — уведомления о событиях

Настраиваются в интерфейсе пространства. Через API документированных маршрутов управления нет; эмпирически найдены `GET /spaces/{space_id}/external-webhooks` и `GET /spaces/{space_id}/webhooks` — оба отвечают 200 только тем, у кого в пространстве **роль 3** (admin), остальным 403. Схемы тел POST/PATCH/DELETE не проверены.

Доставка — `POST` с JSON. Три формы payload: **add** — плоская модель сущности + `author`; **update** — `old` (полный объект до изменения), `changes` (только изменившиеся поля), `author`; **remove** — как add. `author` всегда усечён до `id`, `full_name`, `username`, `email`.

**События (22):**

| `event` | Когда |
|---------|-------|
| `card:add`, `card:update` | карточка создана / изменена |
| `block:add`, `block:update` | карточка заблокирована / блокировка изменена |
| `comment:add`, `comment:update`, `comment:remove` | комментарии |
| `card_time_log:add`, `card_time_log:update`, `card_time_log:remove` | записи времени |
| `tag:add`, `tag:update`, `tag:remove` | тег навешен на карточку / переименован сам тег / снят |
| `board:add`, `board:update` | доска создана / изменена |
| `file:add`, `file:update`, `file:remove` | файлы |
| `space:update` | пространство изменено |
| `card_member:add`, `card_member:update`, `card_member:remove` | участники карточки (`type`: 1 — member, 2 — responsible) |

> **⚠️ Имена событий времени не совпадают с оглавлением документации:** страницы называются `timelog:add` / `:update` / `:remove`, в поле `event` приходит `card_time_log:*`. Матчер, написанный по оглавлению, не поймает ни одного события.

> **⚠️ `card:remove` не существует.** Удаление карточки — это архивация, приходит как `card:update` с `changes: {"archived": true, "condition": 2}`. Нет также событий по колонкам, дорожкам, чек-листам, внешним ссылкам, дочерним карточкам, спринтам и итерациям.

> **⚠️ Ни подписи, ни ретраев, ни фильтрации.** В документации нет ни HMAC, ни signing secret, ни списка исходящих IP, ни гарантий доставки. Подписка идёт на всё пространство целиком — отсев событий на стороне приёмника. Практика: длинный случайный сегмент в URL как единственная аутентификация, быстрый 200 с обработкой в очереди, перезапрос сущности обычным API по `data.id` вместо доверия payload, дедупликация и сверочный опрос как страховка от потерь.

> **⚠️ `changes` содержит служебный шум** (`updated`, `version`, `counters_recalculated_at` меняются почти при любой правке), кастомные свойства приезжают в `changes.properties` **целиком**, включая неизменившиеся, а имён колонок и досок в payload нет вовсе — только числовые id.

---

## Documents (Документы Kaiten)

Вики-страницы внутри Kaiten, живущие в общем дереве компании рядом с пространствами. Тело хранится как ProseMirror-JSON.

| Метод | Endpoint | Описание |
|-------|----------|----------|
| POST \| GET | `/documents` | Создать / список и поиск (`query`, `limit`, `offset`, `version=2` — поиск через OpenSearch) |
| GET \| PATCH \| DELETE | `/documents/{document_uid}` | Получить (с телом `data`) / обновить / удалить (`archived: true`) |
| POST \| GET \| PATCH \| DELETE | `/document-groups[/{uid}]` | Папки документов |
| GET | `/document-schemas/{latest\|vN}` | Схема, которой валидируется `data` (`format=draft-06` или `prosemirror`) |

> **⚠️ В реальном ответе `data` приходит строкой с JSON внутри**, а не объектом — нужен второй разбор JSON. Полей `version`, `schema_version`, `archived`, `company_id` в ответе нет, зато есть недокументированные `author`, `updater`, `public_id`, `slug` (замер).

> **⚠️ Привязать документ к карточке нельзя** — связь односторонняя: внутри тела документа есть узлы `block_card_link` / `inline_card_link` со ссылкой на карточку.

> **⚠️ Удалить непустую папку или документ с вложенными сущностями нельзя** — 400 `has_child_entities_while_deleting`, рекурсивного удаления нет.

Практический сценарий для агента ровно один — **прочитать** существующий документ: найти `uid` через `GET /documents?query=…`, забрать `data` и вытащить из дерева узлы `type == "text"`. Писать документы через API дорого: конвертера из Markdown нет, дерево узлов придётся собирать руками.

---

## Audit Logs (Журнал аудита)

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | `/audit-logs` | События администрирования компании, от новых к старым |

Параметры: `from` / `to` (ISO 8601), `author_id`, `author_uid`, `categories`, `actions`, `id`, `limit` (default 100, **max 500**), `offset`.

**Категории:** `app`, `auth`, `user_profile`, `user_management`, `group_management`, `service_desk`, `publication`, `import`, `company_profile`. **Действия:** входы и выходы, смена пароля и почты, приглашения, активация/деактивация, изменение прав, передача владения, операции с группами, публикация и снятие публикации документов и карточек, публичные ссылки, импорты.

> **⚠️ Нужны админские права на раздел «Журнал действий», обычному токену — `403`** (замер), причём у всех кодов ошибок тело пустое: различать причину придётся по HTTP-коду.

> **⚠️ Это журнал администрирования, а не история карточек.** Событий по карточкам, доскам, комментариям и статусам здесь нет вовсе — за ними идут в `GET /cards/{id}/location-history` и `GET /cards/{id}/activity`.

> **⚠️ Пагинация по ленте, которая пополняется сверху:** при листании назад свежие события сдвигают окно, часть записей повторится или потеряется. Для стабильного обхода фиксируй окно через `from` / `to`.

---

## Лимиты полей

Сняты эмпирически: все пробы вернули **400** с текстом валидации, ни одна запись не применилась.

| Поле | Лимит |
|------|-------|
| `title` карточки | **1024** |
| `description` карточки | **32768** (nullable) |
| текст комментария | **4096** (сообщение не схемное: `Comment text must not exceed 4096 characters`) |
| `size_text` карточки | **267** (nullable) |
| `name` чек-листа | **1024** |
| `text` пункта чек-листа | **4096** |
| `url` внешней ссылки | **16384** |
| `description` внешней ссылки | **512** |

Смежные ограничения из схем документации: `name` шаблона чек-листа — 512, `comment` записи времени — 4096, `name` кастомного свойства — 128, `value` select-значения — 128, `title` пространства — 256, `title` доски / колонки / дорожки — 128, `name` должности — 64, `value` командной оценки — 512.

> **⚠️ Тексты, которые агент собирает динамически** (комментарий со списком находок, описание из шаблона), обрезай до лимита **до** отправки: иначе вместо содержательной ошибки получишь 400 в середине пакетной операции.

---

## Чего в API нет

Проверено — не искать и не пытаться:

| Чего нет | Что вместо |
|----------|-----------|
| **Связей «related cards»** — `/cards/{id}/relations` → 404 | Родитель–потомок (`/children`, `/parents`), блокеры или внешняя ссылка на карточку |
| **Реакций на карточки и комментарии** — `/cards/{id}/reactions` → 404 | — |
| **Шаблонов карточек** | Шаблоны есть только для чек-листов пространства (`/spaces/{space_uid}/template-checklists`) |
| **Превью внешних ссылок** | Внешняя ссылка хранит только `url` и `description` |
| **Назначения спринта через `PATCH /cards/{id}`** | `sprint_id` не входит в схему тела ни у одного из карточных маршрутов; в спринт карточка попадает только из интерфейса |
| **Фильтра карточек по значению кастомного свойства** | Выгрузить карточки и отфильтровать на клиенте; для записей справочника есть `GET /company/custom-directories/{id}/records/{record_id}/cards` |
| **Списочного `GET /cards/{id}/checklists`** — 405 | Чек-листы приходят в теле `GET /cards/{id}` |
| **`GET /cards/{id}/history`** — 404 | `GET /cards/{id}/location-history` и `GET /cards/{id}/activity` |
| **`GET /timesheet`** — 404 | `GET /time-logs` |
| **Маршрутов `/properties/*`** — 404 | `/company/custom-properties` |
| **`PATCH`/`DELETE` доски, колонки, дорожки по короткому пути** — 405/404 | Полный путь: `/spaces/{space_id}/boards/{id}`, `/boards/{board_id}/columns/{id}`, `/boards/{board_id}/lanes/{id}` |
| **Серверного «применить шаблон чек-листа»** | Копирование пунктов на стороне клиента |
| **Вызова внешнего HTTP из автоматизации** | Только исходящие вебхуки пространства |
| **API для SLA-правил и рабочих календарей** | Только чтение замеров по карточке |

Связать две карточки, когда нужна именно ссылка, а не иерархия:

```json
POST /cards/{id}/external-links
{"url": "https://{domain}/space/{space}/boards/card/{card_id}", "description": "Связанная задача"}
```

---

## Rate Limits

- **Лимит: 50 запросов в секунду.** Скользящее окно в одну секунду, бакет **общий на все эндпоинты** (не по одному на каждый).
- При превышении — `429` с телом `Too many requests, please try again later.` (content-type `text/html`, не JSON) и заголовком `Retry-After: 1`.
- В **каждом** ответе приходят заголовки — на них и стоит ориентироваться вместо пауз наугад:

| Заголовок | Значение |
|-----------|----------|
| `x-ratelimit-limit` | `50`, константа |
| `x-ratelimit-remaining` | остаток в текущем окне |
| `x-ratelimit-reset` | unix-время сброса, обычно now + 1 с |
| `retry-after` | `1`, только в ответах `429` |

Замеры (2026-08-20, боевая инсталляция): 120 последовательных запросов за 5 секунд — ни одного отказа; 70 одновременных — 51 успешный и 19 отказов; 35 параллельных на `/cards` плюс 35 на `/spaces` дают суммарно ~48 успешных, что и подтверждает общий бакет.

Практика для скриптов: параллелизм ниже 40 одновременных запросов, при `429` спать `Retry-After` секунд. Искусственные паузы между последовательными запросами не нужны — последовательный код физически не выбирает лимит.

> **⚠️ Бакет общий по токену.** Если тем же токеном одновременно работает другой агент или скрипт, `429` можно словить и на пятнадцатом последовательном запросе.

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

### 7. Прочитать настройки досок пространства дёшево

```bash
# card_properties, default_card_type_id, флаги — без единой карточки
GET /spaces/{space_id}/boards

# WIP-лимиты, подколонки и настройки устаревания — только здесь
GET /boards/{board_id}/columns
```

### 8. Проверить, что автоматизации пространства живы

```bash
GET /spaces/{space_id}/automations   # смотреть status != "active" и brokenLogs
```

---

## Коды ошибок

| Код | Описание |
|-----|----------|
| 200 | Успех |
| 201 | Создано |
| 400 | Неверный запрос (в теле — `message`, иногда числовой `code`) |
| 401 | Не авторизован (тело может быть строкой `Unauthorized`, не JSON) |
| 402 | Фича не входит в тариф компании |
| 403 | Доступ запрещён: права, настройка компании или проверка доступа до валидации тела |
| 404 | Не найдено (пути не существует) |
| 405 | Путь существует, но метод не поддерживается |
| 409 | Конфликт: занятый `key` / `hostname`, удаление участника пространства |
| 413 | Файл больше лимита инсталляции (restricted access files) |
| 422 | Файл признан вредоносным антивирусом |
| 429 | Превышен лимит запросов |
| 500 | Ошибка сервера (в том числе отсутствие валидации внешнего ключа) |
