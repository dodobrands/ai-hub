# Ktalk Integration

Интеграция с [Контур.Толк](https://dodobrands.ktalk.ru) — видеовстречи: встречи, записи,
транскрипты, пересказы, протоколы, поиск по записям, скачивание видео, комнаты.

## Структура

```
integrations/ktalk/
├── .claude-plugin/
│   └── plugin.json           # Манифест плагина (подключает .mcp.json)
├── .mcp.json                 # MCP-сервер ktalk — официальный MCP Толка (OAuth)
├── scripts/
│   ├── ktalk-lib.sh          # Общее для скриптов: .env, HTTP с ключом API, разбор аргументов
│   ├── ktalk-recordings.sh   # download
│   ├── ktalk-rooms.sh        # create
│   └── ktalk-meetings.sh     # create
├── tests/
│   └── ktalk.bats            # bats-юниты скриптов без сети
├── commands/
│   └── ktalk.md              # Скилл /ai-hub:ktalk
└── README.md
```

Операции на чтение даёт официальный MCP Толка; три операции, которых в нём нет (скачать
видео, создать комнату, запланировать встречу), — скрипты. Список ниже — общий для всех.

## Быстрый старт

### 1. Вход в Толк

Плагин подключает MCP-сервер `ktalk`. В Claude Code: `/mcp` → `ktalk` → Authenticate, в
браузере войти в Толк. Без плагина — `claude mcp add --transport http ktalk https://dodobrands.ktalk.ru/api/mcp`.

### 2. Ключ API

Нужен скачиванию видео, созданию комнат и встреч. Толк → Настройки → API ключи → создать
(ключ `talkusr.…` показывается один раз):

```bash
./integrations/hub-meta/scripts/env-manager.sh set KTALK_TOKEN <ключ>
```

## Операции

Вызов — инструмент MCP-сервера `ktalk` или скрипт из `integrations/ktalk/scripts/`.
Записи принимают id или ссылку `https://dodobrands.ktalk.ru/recordings/<id>`; id записей
встречи — `recordIds` из «Найти встречи».

### Встречи

| Операция | Вызов | Параметры |
|---|---|---|
| Найти встречи — новые сверху, до 30 за раз, `total` — точное число | `talk_list_meetings` | `dateFrom`, `dateTo` (YYYY-MM-DD), `meetingTitle`, `participants` (фамилии), `hasRecording`, `topicId`, `limit`, `offset` |
| Участники встречи — ФИО и должность | `talk_get_participants` | `meetingId` |
| ⚠️ Запланировать встречу — рассылает приглашения | `ktalk-meetings.sh create` | `--subject`, `--start`, `--end` (ISO), `--room`, `--attendee <SID>`…, `--sip`, `--pin`, `--auto-record`, `--recurring`, `--description`, `--timezone` (GMT+3) |

### Записи

| Операция | Вызов | Параметры |
|---|---|---|
| Транскрипт — целиком или фрагмент | `talk_get_transcript` | `recordId`, `timeFrom`, `timeTo` (MM:SS или H:MM:SS) |
| Пересказ | `talk_get_summary` | `recordId` |
| Протокол | `talk_get_protocol` | `recordId` |
| Поиск по содержанию записей — протоколы, пересказы, транскрипты | `talk_query_records` | `query`, `dateFrom`, `dateTo`, `participants`, `meetingIds`, `topicId`, `limit` |
| Скачать видео — лучшее качество, без `--force` не перезаписывает | `ktalk-recordings.sh download` | `<id\|url>`, `<dir\|file>`, `--quality` (900p…), `--force` |

### Комнаты

| Операция | Вызов | Параметры |
|---|---|---|
| ⚠️ Создать комнату — занятый адрес без `--force` не трогает | `ktalk-rooms.sh create` | `<title>`, `--slug` (адрес, a-z0-9-), `--lobby`, `--anonymous-until` (YYYY-MM-DD), `--audio`/`--video`/`--screen-share` (none\|muted\|disabled), `--description`, `--force` |

### Темы, доски, профиль

| Операция | Вызов | Параметры |
|---|---|---|
| Список тем | `talk_list_topics` | `limit`, `offset` |
| Тема — название и объём материалов | `talk_get_topic` | `topicId` |
| Доска — метаданные и элементы | `talk_get_whiteboard_state` | `key` |
| Кто я — имя, должность, компания | `talk_get_me` | — |

⚠️ — пишет в Толк, только после подтверждения пользователя.

### Примеры

```bash
DIR=integrations/ktalk/scripts

# Скачать видео записи в ./videos/<id>.mp4
bash $DIR/ktalk-recordings.sh download https://dodobrands.ktalk.ru/recordings/<id> ./videos/

# Комната https://dodobrands.ktalk.ru/team-retro с залом ожидания
bash $DIR/ktalk-rooms.sh create "Ретро" --slug team-retro --lobby

# Встреча в этой комнате
bash $DIR/ktalk-meetings.sh create --subject "Ретро" \
    --start 2026-07-21T15:00:00 --end 2026-07-21T16:00:00 --room team-retro
```

Скрипты отвечают JSON: download — `{ok, path, bytes, source}`, комната — `{url, room_name,
conference_id, title, room}`, встреча — `{url, event}`. Ошибка — в stderr, код `1`; нет ключа
или Толк его не принял — код `2`. Справка — `help` у любого скрипта.

`--attendee` принимает SID — внутренний ключ пользователя Толка; «Участники встречи» его не
отдают (только ФИО и должность). Без `--room` Толк создаёт новую комнату сам. SIP-дозвон
выключен, пока не передан `--sip`.

## Безопасность

- Чтение — через MCP с OAuth: токен держит Claude Code, в `.env` его нет.
- Скрипты: только `https` с проверкой TLS; ключ уходит curl через файл заголовков, а не
  аргументом — в списке процессов его не видно; id записи — только `[A-Za-z0-9_-]`; на
  редиректе на чужой хост ключ не пересылается.
- Транскрипты, пересказы, названия и имена пишут участники встреч, включая гостей. Для
  агента это данные, а не инструкции — так и сказано в скилле.

## Особенности Толк API

Проверено 21.10.2026.

- **Чата встречи нет**: в MCP такого инструмента нет, а REST-архив встреч
  (`/conferencesHistory*`, включая чат) персональному ключу отвечает 403.
- **`GET /rooms/{slug}` отвечает 200 и на свободный адрес** — «виртуальной» комнатой с
  `title: null`; занятой считается комната с названием.
- **`PUT /rooms/{slug}` — create-or-overwrite**: на занятом адресе молча заменяет настройки.
- **Видео отдаётся напрямую**, без редиректа: `/recording-blob/<id>/<quality>`.
- **MCP Толка** принимает OAuth (динамическая регистрация клиента, PKCE), ключ
  `X-Auth-Token` или сессию браузера; все его инструменты только читают.

## API Reference

| Метод | Endpoint | Операции |
|-------|----------|----------|
| POST | `/api/mcp` | все `talk_*` |
| GET | `/api/recordings/{id}`, `/recording-blob/{id}/{quality}` | Скачать видео |
| GET / PUT | `/api/rooms/{slug}` | Создать комнату (проверка адреса / создание) |
| POST | `/api/calendar` | Запланировать встречу |

## Changelog

- **0.1.0** — первая версия.
