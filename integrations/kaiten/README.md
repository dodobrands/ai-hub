# Kaiten Integration

Универсальный CLI-клиент для работы с [Kaiten API](https://www.kaiten.ru/). Не привязан к конкретной команде или проекту — можно подключить к любому пространству.

## Структура

```
├── docs/
│   └── KAITEN_API.md           # Документация API endpoints
├── scripts/
│   ├── kaiten.sh               # Универсальный CLI для любых API-вызовов
│   ├── kaiten-cards.sh         # Работа с карточками (CRUD, комментарии, чек-листы)
│   ├── kaiten-spaces.sh        # Пространства, доски, колонки
│   ├── kaiten-config.space.sh  # Конфигурация пространства по умолчанию
│   └── kaiten-export-board.sh  # Экспорт доски
└── README.md
```

## Быстрый старт

### 1. Настройка токена

```bash
# В .env в корне репозитория (или экспортируйте переменные окружения)
KAITEN_TOKEN=your_api_token_here
KAITEN_DOMAIN=your_domain.kaiten.ru
```

> Токен можно получить в Kaiten: Настройки профиля → API / Интеграции → Создать токен.

### 2. Права на запуск

```bash
chmod +x integrations/kaiten/scripts/*.sh
```

### 3. Проверка подключения

```bash
./integrations/kaiten/scripts/kaiten-spaces.sh me
```

## Использование

### Универсальный API-клиент (`kaiten.sh`)

Обёртка над `curl` для любых запросов к Kaiten REST API:

```bash
./kaiten.sh GET /cards/123
./kaiten.sh POST /cards '{"title": "Задача", "board_id": 1, "column_id": 2}'
./kaiten.sh PATCH /cards/123 '{"column_id": 5}'
./kaiten.sh DELETE /cards/123
```

### Карточки (`kaiten-cards.sh`)

```bash
# Список карточек на доске
./kaiten-cards.sh list <board_id>

# Получить карточку
./kaiten-cards.sh get <card_id>

# Создать карточку
./kaiten-cards.sh create <board_id> <column_id> "Название" "Описание"

# Переместить в другую колонку
./kaiten-cards.sh move <card_id> <column_id>

# Комментарий
./kaiten-cards.sh comment <card_id> "Текст"

# Назначить ответственного
./kaiten-cards.sh assign <card_id> <user_id>

# Чек-лист
./kaiten-cards.sh checklist <card_id> "Название чек-листа"
./kaiten-cards.sh check-item <card_id> <checklist_id> "Пункт"
```

### Пространства и доски (`kaiten-spaces.sh`)

```bash
./kaiten-spaces.sh spaces            # Список пространств
./kaiten-spaces.sh boards <space_id> # Доски в пространстве
./kaiten-spaces.sh columns <board_id> # Колонки на доске
```

### Блокеры

```bash
./kaiten-cards.sh blockers <card_id>              # список блокировок
./kaiten-cards.sh block <card_id> "Причина"       # текстовый блокер
./kaiten-cards.sh block <card_id> --card <id>     # блок другой карточкой (зависимость)
./kaiten-cards.sh unblock <card_id> <blocker_id>  # снять блокировку
```

Два вида блокеров: текстовая причина (`reason`) или зависимость от другой карточки
(`blocker_card_id`). `blocker_id` для снятия берётся из вывода `blockers`. Низкоуровнево
то же доступно через `kaiten.sh` (`GET/POST/DELETE /cards/<id>/blockers[/<blocker_id>]`).

### Планируемые связи (порядок работ)

```bash
./kaiten-cards.sh relations <card_id>              # предшественники/последователи карточки
./kaiten-cards.sh relate <pred_id> <succ_id>       # pred идёт ПЕРЕД succ (тип end-start)
./kaiten-cards.sh relate <pred_id> <succ_id> <type> # явный тип связи
./kaiten-cards.sh unrelate <pred_id> <succ_id>     # удалить связь pred -> succ
```

Планируемая связь (`planned-relation`, тип `end-start`) задаёт **порядок работ**: предшественник
идёт перед последователем. Это мягкая зависимость таймлайна, а не жёсткий блок (для жёсткого —
`block`). **У обеих карточек должны быть плановые даты** (`planned_start`/`planned_end`) — иначе
Kaiten отклонит связь; проставь их через `update` (политику дат-заглушек держи в
скриптах-потребителях). Подробнее — [docs/KAITEN_API.md](./docs/KAITEN_API.md#card-planned-relations-планируемые-связи).

## API Reference

Полная документация endpoints — в [docs/KAITEN_API.md](./docs/KAITEN_API.md).

| Ресурс | Описание |
|--------|----------|
| `/spaces` | Пространства |
| `/boards` | Доски |
| `/columns` | Колонки |
| `/lanes` | Дорожки |
| `/cards` | Карточки |
| `/users` | Пользователи |
| `/tags` | Теги |
| `/properties` | Кастомные свойства |

### Rate Limits

- 100 запросов в минуту
- При превышении — HTTP 429
- **Клиентский троттлинг** (opt-in): env `KAITEN_RATE=min|max` — пауза перед запросом. `max`=0.6с ≈100 req/мин (безопасно для bulk, соответствует лимиту); `min`=0.2с ≈300 req/мин — только для коротких серий, **не** для sustained-нагрузки. Дефолт — без паузы (интерактивные вызовы пейсятся сами).

### Таймауты

- Соединение — 10с (`--connect-timeout`), весь запрос — 30с (`--max-time`).
- При таймауте/сетевой ошибке `kaiten.sh` завершается с ошибкой (`exit 1`), а не виснет.

## Troubleshooting

| Ошибка | Причина |
|--------|---------|
| 401 | Неверный или истёкший токен в `.env` |
| 404 | Неверный домен или endpoint |
| 429 | Превышен лимит запросов — подождите минуту |
| `curl не смог выполнить …` | Таймаут (>30с) или нет соединения (>10с) — API недоступен/сеть; повторите |
