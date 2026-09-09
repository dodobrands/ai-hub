# Time (Mattermost) Integration

Клиент для Time (Mattermost API v4) с двумя режимами авторизации: бот и личный аккаунт.

## Структура

```
integrations/time/
├── .cache/                        # Локальный кэш каналов и storage-state (gitignored)
├── .time-signature                # Подпись сообщений (gitignored)
├── .claude-plugin/plugin.json
├── README.md
├── commands/
│   ├── time-chat.md              # /ai-hub:time-chat — каналы/сообщения
│   └── time-login.md             # /ai-hub:time-login — автологин через браузерный MCP
└── scripts/
    ├── time.sh                   # HTTP-клиент, dual auth (Layer 1)
    ├── time-login.sh             # Интерактивный логин (терминал, fallback) + check
    ├── time-extract-token-from-storage.sh  # Извлечение токена из storage-state (Playwright MCP)
    ├── time-save-token-from-clipboard.sh   # Сохранение из clipboard (DevTools MCP)
    ├── time-channels.sh          # Каналы (Layer 2)
    ├── time-messages.sh          # Сообщения (Layer 2)
    └── time-helpers.sh           # Shared helpers: permalink parsing, batch user resolve
```

## Быстрый старт

### 1. Настрой авторизацию

**Личный аккаунт — Google SSO** (рекомендуется):
```
/ai-hub:time-login
```
Открывает браузер через MCP-сервер (Chrome DevTools MCP или Playwright MCP), юзер логинится через Google SSO, токен извлекается Bash-скриптом из storage-state файла и сохраняется в `.env`. Токен **не проходит через LLM**.

При повторном вызове сначала проверяет существующий токен — если валиден, браузер не запускается.

**Личный аккаунт — email/пароль (fallback):**
```bash
./integrations/time/scripts/time-login.sh
```
Интерактивный логин через терминал.

**Bot Account** (опционально, для автоматических постов):
```bash
# Time → Menu → Integrations → Bot Accounts → Add Bot Account
# Скопируй токен и добавь в .env:
echo 'TIME_BOT_TOKEN=your_bot_token' >> .env
```

Можно настроить оба — скрипты выберут нужный по контексту.

### 2. Проверь подключение

```bash
# Проверка (автовыбор режима)
integrations/time/scripts/time-channels.sh me | jq '{username, email}'

# Явно через бота
integrations/time/scripts/time-channels.sh --as bot me | jq '{username}'

# Явно через личный аккаунт
integrations/time/scripts/time-channels.sh --as me me | jq '{username, email}'
```

## Использование

### Двойная авторизация

Все скрипты принимают флаг `--as bot|me` первым аргументом:

```bash
# Автовыбор (bot если есть TIME_BOT_TOKEN, иначе me)
./time-channels.sh my-teams

# Явно от бота
./time-messages.sh --as bot send <channel_id> "Release v2.1.0 deployed"

# Явно от личного аккаунта
./time-messages.sh --as me send <channel_id> "Привет, подскажи по задаче?"
```

Альтернативно — через переменную окружения:
```bash
TIME_AS=me ./time-channels.sh my-channels <team_id>
```

### Когда какой режим

| Действие | Режим | Почему |
|----------|-------|--------|
| Чтение каналов/сообщений | `me` (предпочтительно) | Доступны все каналы пользователя |
| Вопрос коллеге | `me` | Личное обращение |
| Changelog / release notes | `bot` | Автоматическое уведомление |
| Результаты spike | `bot` | Обезличенный пост |
| Не уверен | Спросить пользователя | — |

### Каналы

```bash
# Мои команды
./time-channels.sh my-teams | jq '.[].display_name'

# Каналы в команде
./time-channels.sh my-channels <team_id>

# Найти канал (включая приватные, с кэшем 30 мин)
./time-channels.sh find <team_id> "my-team"

# Поиск канала (API, только публичные)
./time-channels.sh search <team_id> "my-team"

# Участники канала
./time-channels.sh members <channel_id>

# Очистить кэш каналов
./time-channels.sh cache-clear
```

### Сообщения

```bash
# Последние сообщения
./time-messages.sh posts <channel_id> 0 20

# Тред — принимает raw post_id или permalink URL
./time-messages.sh thread <post_id>
./time-messages.sh thread "https://your-company.time-messenger.ru/<team>/pl/<post_id>"

# Один пост — тоже принимает permalink
./time-messages.sh get <post_id_or_permalink>

# Поиск
./time-messages.sh search <team_id> "ключевое слово"
./time-messages.sh search "ключевое слово"   # team_id берётся из $TIME_TEAM_ID в .env

# Отправить сообщение
./time-messages.sh --as me send <channel_id> "Текст сообщения"

# Отправить с вложением (--file можно повторять)
./time-messages.sh --as me send <channel_id> "Текст" --file screenshot.png

# Ответить в тред
./time-messages.sh --as bot send <channel_id> "Ответ" <root_post_id>

# Информация о пользователе
./time-messages.sh user <user_id>

# Список или поиск пользователей
./time-messages.sh users                 # первые 50
./time-messages.sh users "orlov"          # поиск по term
./time-messages.sh users "" 0 100         # пагинация без поиска

# Direct messages с пользователем (auto-enriched)
./time-messages.sh dm @some.user 20
```

### Резолв username в выводе

Флаг `--resolve-users` (алиас `--enrich`) дописывает объект `user` рядом с `user_id` в каждом посте. Поддерживается для `posts`, `thread`, `search`, `my-posts`. Action `dm` обогащает автоматически.

```bash
./time-messages.sh posts <channel_id> --resolve-users | jq '.posts | to_entries[0].value | {message, user: .user.username}'
./time-messages.sh thread <post_id> --resolve-users
./time-messages.sh search <team_id> "release" --resolve-users
./time-messages.sh my-posts <channel_id> --resolve-users
```

Резолв батчевый — один запрос `POST /api/v4/users/ids` на все уникальные `user_id` в ответе. Результат кэшируется в `integrations/time/.cache/users.json` с TTL 7 суток. Если запрос упал, пост возвращается без `user` (warning в stderr, команда не валится).

### Через Claude Code

```
/ai-hub:time-chat найди канал my-team-dev
/ai-hub:time-chat покажи сообщения в канале my-team-dev
/ai-hub:time-chat напиши Пете уточнение по задаче
/ai-hub:time-chat запости changelog в канал releases
```

## Постфикс сообщений

По умолчанию исходящие сообщения отправляются **без постфикса**. При первом логине (`/ai-hub:time-login`) предлагается настроить опциональный постфикс.

**Ручная настройка:** создай файл `integrations/time/.time-signature` с нужным содержимым:
```bash
echo ' 🤖 sent via AI Hub' > integrations/time/.time-signature
```

**Убрать постфикс:** удали файл `.time-signature`.

Файл `.time-signature` — локальный, добавлен в `.gitignore`.

## Авторизация: детали

### MCP Browser Login (time-login.md)
- Основной способ. Использует браузерный MCP-сервер (не привязан к конкретному браузеру)
- Приоритет: Chrome DevTools MCP → Playwright MCP
- Извлекает HttpOnly cookie MMAUTHTOKEN через storage-state файл (Playwright) или clipboard (DevTools)
- Токен не проходит через LLM — только статусные сообщения
- Если MCP не настроен — предлагает установить Chrome DevTools MCP

### Bot Account
- Создаётся в Time: Menu → Integrations → Bot Accounts
- Токен постоянный, не протухает
- Сообщения приходят от имени бота
- Ограничен каналами, куда бот добавлен

### Личный аккаунт (session)
- Логин через `/ai-hub:time-login` (SSO) или `./time-login.sh` (терминал)
- Токен сохраняется как `TIME_TOKEN` в `.env`
- При 401 (токен просрочен) — перезапусти `/ai-hub:time-login`
- Доступны все каналы пользователя

### Автовыбор
Если `--as` не указан:
1. Есть `TIME_BOT_TOKEN` → бот
2. Есть `TIME_TOKEN` → личный
3. Ничего нет → подсказка запустить `/ai-hub:time-login`

## API Reference

- **Base URL:** `https://your-company.time-messenger.ru` (configure via `TIME_BASE_URL` in `.env`)
- **Auth:** `Authorization: Bearer <token>`
- **API:** Mattermost v4 compatible
- **Docs:** https://docs.time-messenger.ru/api/v4/

## Troubleshooting

| Ошибка | Причина | Решение |
|--------|---------|---------|
| `No auth configured` | Нет токенов в .env | Запусти `/ai-hub:time-login` |
| `HTTP 401` | Просроченный токен | Запусти `/ai-hub:time-login` |
| `HTTP 403` | Нет доступа к каналу | Бот не добавлен в канал / нет прав |
| `error:no_mmauthtoken` | Cookie не найдена в storage-state | Убедись что залогинился в Time в браузере MCP |
| Нет MCP | Браузерный MCP не настроен | Установи Chrome DevTools MCP или Playwright MCP (см. time-login.md) |
