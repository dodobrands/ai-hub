---
name: kaiten-card
description: Read, comment, move, or update a Kaiten card by URL or ID
allowed-tools: ["Bash", "Read", "Glob", "Grep", "AskUserQuestion"]
---

# Kaiten Card — работа с карточкой

Читает, комментирует, перемещает и обновляет карточки Kaiten по ссылке или ID.

## Trigger

Активируй при любом из условий:

- URL карточки: `https://<domain>.kaiten.ru/space/<space_id>/card/<card_id>`
- Запрос вида «открой карточку», «посмотри задачу», «прокомментируй карточку» + ID или ссылка
- Запрос переместить/закрыть/назначить карточку в Kaiten

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

## Получение ID из ссылки

Ссылки вида `https://<domain>.kaiten.ru/space/.../card/<id>` — извлекай последний числовой сегмент как `card_id`.

## Чтение карточки

```bash
# Получить карточку целиком
"$KAITEN_SCRIPTS/kaiten-cards.sh" get <card_id>

# Получить комментарии
"$KAITEN_SCRIPTS/kaiten-cards.sh" comments <card_id>

# Получить чек-листы
"$KAITEN_SCRIPTS/kaiten-cards.sh" checklists <card_id>
```

После чтения выведи: заголовок, статус (колонка), описание, ответственных, чек-листы (если есть), последние комментарии.

## Добавить комментарий

```bash
"$KAITEN_SCRIPTS/kaiten-cards.sh" comment <card_id> "Текст комментария"
```

## Переместить в колонку

Если `column_id` не известен — сначала получи список колонок доски:

```bash
"$KAITEN_SCRIPTS/kaiten-spaces.sh" columns <board_id>
```

Если есть `team-config.json` — используй колонки оттуда (`.kaiten.boards.sprint.columns.*`).

```bash
"$KAITEN_SCRIPTS/kaiten-cards.sh" move <card_id> <column_id>
```

## Назначить ответственного

```bash
# Получить участников карточки
"$KAITEN_SCRIPTS/kaiten-cards.sh" members <card_id>

# Список пользователей пространства
"$KAITEN_SCRIPTS/kaiten-spaces.sh" users

# Назначить
"$KAITEN_SCRIPTS/kaiten-cards.sh" assign <card_id> <user_id>
```

## Обновить поля карточки

```bash
# Изменить заголовок / описание / размер / тип
"$KAITEN_SCRIPTS/kaiten-cards.sh" update <card_id> '{"title": "Новый заголовок"}'
"$KAITEN_SCRIPTS/kaiten-cards.sh" update <card_id> '{"description": "Новое описание"}'
```

## Поиск карточек

```bash
"$KAITEN_SCRIPTS/kaiten-cards.sh" search "<текст>" [space_id]
```

## Привязка к родительской карточке

```bash
# Привязать карточку CHILD_ID к родителю PARENT_ID
curl -X POST "https://{KAITEN_DOMAIN}/api/latest/cards/{PARENT_ID}/children" \
  -H "Authorization: Bearer {KAITEN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"card_id": CHILD_ID}'
```

> **⚠️ Критичное замечание:** Тело — `{"card_id": <child_id>}` (не `children_ids`, не массив).  
> Поля с другими именами (`children_ids`, `parent_ids`) игнорируются: запрос вернёт `200`, но связь не создастся. `403` — отдельная история (нет прав/токен), не про формат тела.

Проверка успеха: в ответе `parents_ids` должен содержать ID родителя.

## Работа с чек-листами

```bash
# Создать чек-лист
"$KAITEN_SCRIPTS/kaiten-cards.sh" checklist <card_id> "Название"

# Добавить пункт
"$KAITEN_SCRIPTS/kaiten-cards.sh" check-item <card_id> <checklist_id> "Пункт"

# Отметить выполненным
"$KAITEN_SCRIPTS/kaiten-cards.sh" toggle-check-item <card_id> <checklist_id> <item_id> true
```

## Настройка

В `.env` должны быть:

```bash
KAITEN_TOKEN=your_api_token
KAITEN_DOMAIN=your_domain.kaiten.ru
```

| Ошибка | Причина |
|--------|---------|
| 401 | Неверный или истёкший токен |
| 404 | Неверный card_id или домен |
| 429 | Превышен лимит 100 req/min — подожди минуту |

$ARGUMENTS
