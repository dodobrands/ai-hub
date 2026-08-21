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
│   ├── time-login.md             # /ai-hub:time-login — автологин через браузерный MCP
│   └── time-connector.md         # /ai-hub:time-connector — проверка и запуск коннектора
├── connector/                     # Claude Code Channel connector (TypeScript, bun / node ≥ 22.6)
│   ├── server.ts                 # MCP stdio server: inbound → <channel>, tools reply/react, permission relay
│   ├── src/                      # config, whitelist, classify, chunk, mattermost (REST+WS), instructions
│   └── test/                     # node:test юниты + bun-only e2e с фейковым Mattermost
├── scripts/
│   ├── time.sh                   # HTTP-клиент, dual auth (Layer 1)
│   ├── time-login.sh             # Интерактивный логин (терминал, fallback) + check
│   ├── time-extract-token-from-storage.sh  # Извлечение токена из storage-state (Playwright MCP)
│   ├── time-save-token-from-clipboard.sh   # Сохранение из clipboard (DevTools MCP)
│   ├── time-channels.sh          # Каналы (Layer 2)
│   ├── time-messages.sh          # Сообщения (Layer 2)
│   ├── time-helpers.sh           # Shared helpers: permalink parsing, batch user resolve
│   └── time-connector.sh         # Лаунчер коннектора: .env → team-config → bun/node → server.ts
└── tests/                         # bats: extract_post_id, лаунчер коннектора
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

## Connector — интерактивный бот в Time (Claude Code Channels)

Опциональная надстройка над клиентом: коллеги пишут боту в Time, а отвечает им **твоя запущенная
сессия Claude Code**. Неинтерактивные скрипты выше работают независимо и не меняются.

Основано на **Claude Code Channels** (research preview): `connector/server.ts` — MCP-сервер, который
держит WebSocket к Time и пушит входящие в сессию как `<channel …>`; Claude отвечает MCP-тулом
`reply`. Работает только пока сессия открыта; ответы уходят от имени бота.

### Что доставляется в сессию

| Вид (`kind`) | Когда | Куда уходит ответ |
|---|---|---|
| `dm` | личное сообщение боту | в ту же ЛС, плоским сообщением (тред — только если собеседник сам пишет в треде) |
| `mention` | `@имя-бота` в канале, где бот состоит | reply под сообщением-триггером (тред) |
| `thread` | ответ в треде, корень которого написал бот, или в котором бот уже отвечал в этой сессии | в тот же тред |

Всё остальное (посты в каналах без упоминания, system-посты, собственные посты бота) игнорируется.

### Требования

- Claude Code с авторизацией Anthropic (claude.ai / Console API key; Bedrock/Foundry не поддерживают Channels).
  Для Team/Enterprise админ должен включить Channels (`channelsEnabled`).
- `bun` (предпочтительно) или Node.js ≥ 22.6.
- В `.env`: `TIME_BASE_URL` и **`TIME_BOT_TOKEN`** (токен бот-аккаунта; личный `TIME_TOKEN` не подходит).

### Токен бота и права

Коннектору нужен **Bot Account** Time: Menu → Integrations → Bot Accounts → Add Bot Account.
Если у тебя нет прав создавать ботов — запроси токен у администратора Time в своей компании.
Боту нужны права на сообщения:

- при создании — галочка **«Post to channels»** (`post:all`), иначе `reply` будет получать `403`;
- бот **видит посты канала только если добавлен в канал** — `/invite @имя-бота` в нужных каналах
  (иначе @упоминания до коннектора не дойдут); ЛС работают без приглашений;
- реакции (`react`) — обычные права участника.

Токен кладётся в `.env` из терминала, не через чат:
```bash
bash integrations/hub-meta/scripts/env-manager.sh set TIME_BOT_TOKEN <token>
```

### Whitelist

Отвечать боту могут только пользователи из whitelist — **для всех видов входящих** (ЛС,
@упоминания, треды). Остальные молча дропаются (строка `drop: …` в stderr сервера / debug-логе
Claude Code). Пустой whitelist = дропается всё (сервер предупредит при старте).

Приоритет источников:
1. `team-config.json` → `time.connector.allowed_users: ["j.doe", "a.smith"]` (overlay-конфиг команды; пустой массив = не задано);
2. `.env` → `TIME_CONNECTOR_ALLOWED_USERS=j.doe,a.smith`.

Username'ы резолвятся в id при старте и раз в 10 минут; нераспознанные попадут в warning.

### Запуск

Канал подключается **флагом при старте `claude`**, из запущенной сессии его включить нельзя.
`/ai-hub:time-connector` проверяет предпосылки (`print-env`, `check`) и печатает нужную команду.

Проверка без MCP:
```bash
bash integrations/time/scripts/time-connector.sh check
```

Запуск одинаков для всех раскладок (клон, overlay, plugin-cache): сервер регистрируется один раз
на уровне пользователя, затем `claude` стартует с флагом:

```bash
# путь: integrations/time/scripts в клоне/overlay или ~/.claude/plugins/cache/ai-hub/time/<ver>/scripts
claude mcp add --scope user time-connector -- bash "<путь>/time-connector.sh" serve
claude --dangerously-load-development-channels server:time-connector
```

Коннектор сознательно **не** объявлен в plugin-уровневом `.mcp.json`: иначе он стартовал бы в каждой
сессии с плагином `time` — без флага channels Claude Code игнорирует входящие, а бот при этом уже
«акает» коллегам реакцией и typing'ом, и N сессий = N ботов на один токен. Один коннектор на бота.
После обновления плагина путь в кеше меняется — `/ai-hub:time-connector` перерегистрирует сервер.

При старте с dev-флагом Claude Code показывает предупреждение — это ожидаемо. Проверка: `/mcp` →
`time-connector` connected, тулы `reply`, `react`.

Зависимости `connector/node_modules` ставятся автоматически при первом запуске (`bun install` /
`npm install`, вывод уходит в stderr).

### Как это выглядит в сессии

```
<channel source="…time-connector" kind="mention" post_id="…" channel_id="…" root_id="…"
         user="j.doe" user_id="…" team="your-team" channel="dev" permalink="https://…/pl/…" ts="…">
@claude-bot что с релизом?
</channel>
```

Claude отвечает `reply(channel_id, text, root_id)` — `root_id` берётся из тега (пустой = плоское
сообщение в ЛС). Длинные ответы режутся на несколько постов в том же треде. `react(post_id, emoji)` —
для коротких ack. Перед доставкой коннектор шлёт typing-индикатор и ставит реакцию `eyes`
(отключается `TIME_CONNECTOR_ACK_REACTION=`).

### Разрешения на tool-коллы (permission relay)

Когда Claude запрашивает разрешение на инструмент, коннектор отправляет запрос **в ЛС последнему
написавшему** (не в тред/канал, чтобы не засорять обсуждение): `🔐 Claude просит разрешение: Bash …
Ответь yes <код> / no <код>`. Ответ принимается только в ЛС и только от этого пользователя; такие
сообщения не форвардятся как промпты. Если входящих из Time ещё не было — разрешение подтверждается
в терминале как обычно.

### Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `TIME_BOT_TOKEN` | — | токен бот-аккаунта (обязательно) |
| `TIME_BASE_URL` | `https://your-company.time-messenger.ru` | адрес Time |
| `TIME_CONNECTOR_ALLOWED_USERS` | — | whitelist, если нет в `team-config.json` |
| `TIME_TEAM_CONFIG` | авто (`hub_team_config`: overlay root → git toplevel → корень репо) | путь к `team-config.json` |
| `TIME_CONNECTOR_RUNTIME` | авто (`bun` → `node`) | принудительно `bun` или `node` |
| `TIME_CONNECTOR_ACK_REACTION` | `eyes` | реакция-ack на входящее, пусто — отключить |
| `TIME_CONNECTOR_CHUNK_LIMIT` | `16000` | максимальная длина одного поста |
| `TIME_CONNECTOR_IGNORE_BOTS` | `true` | игнорировать сообщения других ботов |

### Ограничения v1

- Вложения не скачиваются (в теге только `file_count`); истории сообщений нет — при необходимости
  Claude использует `time-messages.sh thread <root_id>`.
- После рестарта сервера follow-up в треде, который начал человек (ответ на @упоминание), требует
  нового @упоминания; треды с корнем от бота подхватываются всегда.
- Две сессии с одним токеном бота получат и ответят на одно и то же сообщение — запускай один коннектор на бота.
- Channels — research preview: флаги и протокол могут измениться.

### Troubleshooting коннектора

| Симптом | Причина | Решение |
|---|---|---|
| `blocked by org policy` при старте | Channels выключены для организации | админ: `channelsEnabled: true` |
| `ws: authentication failed` | токен неверный/отозван | `time-connector.sh check`, обнови `TIME_BOT_TOKEN` |
| `error:token_invalid` в `check` | токен не принят (401) | то же |
| бот молчит на @упоминание в канале | бот не в канале / юзер не в whitelist / сессия без флага | `/invite @бот`, проверь whitelist, перезапусти `claude` с флагом |
| `reply failed … 403` | нет прав постить | права «Post to channels» у бота, членство в канале |
| `no suitable runtime` | нет bun / node ≥ 22.6 | поставь bun или обнови Node |
| ошибки зависимостей | битый `node_modules` | `rm -rf integrations/time/connector/node_modules` и перезапусти |
| тесты | — | `bash tests/time-connector-unit.sh`, `bats integrations/time/tests/` |

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
