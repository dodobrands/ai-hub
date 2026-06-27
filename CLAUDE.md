# CLAUDE.md

AI Hub — набор интеграций и скиллов для Claude Code, подключающих агента к командным инструментам (таск-трекеры, мессенджеры, вики, графические доски, аналитика). Основной язык — русский.

## First run — крути setup.sh пока не DONE

Юзер только что склонировал репо или прислал первым сообщением запрос вроде «установи мне ai-hub», «настрой», «запусти»? **Сразу начни установку**:

```bash
bash integrations/hub-meta/scripts/setup.sh next
```

Этот скрипт печатает ОДИН текущий шаг с точными командами. Выполни — вызови `next` снова — получи следующий шаг. **Крути в цикле пока первая строка вывода не станет `STATUS: DONE`.**

**Hard rules** (повторены из README):

1. Не докладывай «готово» до `STATUS: DONE`.
2. Chrome DevTools MCP — обязателен, ставь автоматически (команда на Step 1).
3. Default: юзер только жмёт Google SSO в браузере через MCP. Manual copy-paste — только если MCP сломался.
4. Secrets идут в `.env` через `env-manager.sh set`, в контекст LLM не попадают.

Полный reference — [`integrations/hub-meta/commands/setup.md`](integrations/hub-meta/commands/setup.md). Хардкод-конфига команды: `https://buildin.ai/c7ec2023-9025-4c09-be09-e6f54cb07f7e`.

## Architecture

Модульная архитектура: каждая интеграция — самодостаточный модуль (scripts/, commands/, skills/, agents/). Детали — в README каждого модуля.

```
├── integrations/
│   ├── kaiten/                   # Kaiten API клиент              → README.md
│   ├── buildin/                  # Buildin wiki клиент (UI API)   → README.md
│   ├── buildin-bot-api/          # Buildin wiki клиент (Bot API)  → README.md
│   ├── time/                     # Time (Mattermost) клиент       → README.md
│   ├── genie/                    # Databricks Genie (аналитика)   → README.md
│   ├── spike/                    # Spike-исследования             → README.md
│   ├── discovery/                # Product Discovery (9 фаз)
│   ├── test-factory/             # Генерация тестов
│   ├── reverse-product-analysis/ # Реверс-анализ по коду
│   ├── holst/                    # Инструменты для графических досок
│   ├── kusto/                    # Azure Data Explorer (логи)     → README.md
│   ├── hub-meta/                 # create-command, skill-retro
│   └── code-review/              # Code review workflow
└── .env                          # Токены (не в git)
```

### Slash-команды и симлинки

Claude Code CLI ищет slash-команды в `.claude/commands/`. Команды размещены в поддиректории `ai-hub/`, что даёт namespace `/ai-hub:` в CLI. Исходные файлы команд хранятся внутри своих интеграций (`integrations/<name>/commands/`), а в `.claude/commands/ai-hub/` лежат **симлинки** с относительными путями.

```
.claude/commands/ai-hub/
  discovery.md                   → ../../../integrations/discovery/commands/discovery.md
  rpa-analyze.md                 → ../../../integrations/reverse-product-analysis/commands/reverse-analysis.md
  holst-export.md                → ../../../integrations/holst/commands/holst-export.md
  buildin-read.md                → ../../../integrations/buildin/commands/read-page.md
  buildin-publish.md             → ../../../integrations/buildin/commands/publish-page.md
  buildin-login.md               → ../../../integrations/buildin/commands/buildin-login.md
  buildin-bot-read.md            → ../../../integrations/buildin-bot-api/commands/buildin-bot-read.md
  setup.md                       → ../../../integrations/hub-meta/commands/setup.md
  create-command.md              → ../../../integrations/hub-meta/commands/create-command.md
  spike.md                       → ../../../integrations/spike/commands/spike.md
  ai-test.md                     → ../../../integrations/test-factory/commands/ai-test.md
  time-chat.md                   → ../../../integrations/time/commands/time-chat.md
  time-login.md                  → ../../../integrations/time/commands/time-login.md
  code-review.md                 → ../../../integrations/code-review/commands/code-review.md
  retro.md                       → ../../../integrations/hub-meta/commands/retro.md
  kusto-query.md                 → ../../../integrations/kusto/commands/kusto-query.md
  kaiten-card.md                 → ../../../integrations/kaiten/commands/kaiten-card.md
  kaiten-board.md                → ../../../integrations/kaiten/commands/kaiten-board.md
```

**Почему симлинки, а не копии:**
- Единый source of truth — файл команды живёт в папке своей интеграции
- Нет рассинхрона — изменил оригинал, симлинк автоматически ведёт на актуальную версию
- Модульность — интеграцию можно скопировать целиком в другой проект

**При создании новой команды** используй `/ai-hub:create-command <integration> <name>` — он создаст файл и симлинк автоматически.

## Data Sources

Интеграции дают агенту доступ к внешним системам. Используй готовые скиллы и скрипты — не пиши свои и не спрашивай пользователя как подключиться.

**Все источники — закрытые SPA за авторизацией. WebFetch и браузер (Chrome DevTools) НЕ работают для чтения данных. Всегда используй скрипты/скиллы из таблицы ниже.**

| Источник | Чтение | Запись | Когда использовать |
|----------|--------|--------|--------------------|
| **Kaiten** — таск-трекер (аналог Jira/Linear) | скрипты `integrations/kaiten/scripts/` | скрипты `integrations/kaiten/` | Карточки, комментарии, чек-листы, перемещение по колонкам, работа с досками |
| **Time** — мессенджер (аналог Slack), на базе Mattermost | `/ai-hub:time-chat` | `/ai-hub:time-chat` | Чтение тредов/каналов для контекста, отправка статусов и вопросов |
| **Buildin (UI API)** — база знаний (аналог Notion) | `/ai-hub:buildin-read` или скрипты `integrations/buildin/scripts/buildin-pages.sh read <url\|id>` | `/ai-hub:buildin-publish` | Чтение документации, публикация результатов. JWT-токен из Google SSO, видит все страницы пользователя. Логин: `/ai-hub:buildin-login` |
| **Buildin (Bot API)** — база знаний (Official API) | `/ai-hub:buildin-bot-read` или скрипты `integrations/buildin-bot-api/scripts/buildin-bot-pages.sh read <url\|id>` | скрипты `integrations/buildin-bot-api/scripts/buildin-bot-pages.sh create\|update` | Чтение/запись через бот-токен. Видит только расшаренные боту страницы. Notion-подобный REST API |
| **Holst** — графические доски (аналог Miro) | `/ai-hub:holst-export` | — | Экспорт данных с визуальных досок (фреймы, стикеры, тексты) |

**Выбор Buildin-интеграции:** если `BUILDIN_UI_TOKEN` есть в `.env` — используй **UI API** (видит все страницы). Если нет — используй **Bot API** (`BUILDIN_BOT_TOKEN`). Не пытайся логиниться через `/ai-hub:buildin-login` автоматически — он требует участия пользователя.

## Team Config

**При любом вопросе о Kaiten-досках, карточках, колонках, каналах Time или страницах Buildin — первым делом проверь наличие `team-config.json` в корне репозитория.** Если файл есть — используй ID досок, колонок и каналов оттуда. Не спрашивай пользователя о board_id/column_id, если они есть в конфиге.

Шаблон для создания конфига — `team-config.example.json`. Структура:
- `kaiten.boards.sprint` — спринтовая доска (id, колонки: sprint_backlog, in_progress, doing, on_hold, done)
- `kaiten.boards.business_backlog` — бизнес-бэклог (id, колонки discovery/ready)
- `kaiten.space_id` — пространство команды
- `kaiten.property_id_affected_services` — ID кастомного свойства
- `time.channels` — ключевые каналы команды

Shell-скрипты (kaiten-export-board.sh и др.) читают конфиг автоматически через `jq`. Agent-команды (.md) проверяют наличие файла и используют значения.

Если `team-config.json` отсутствует — инструменты запрашивают недостающие параметры у пользователя.

## Rules

- **Обезличенность репозитория**: `ai-hub` — публичный мульти-командный репо. Никаких конкретных названий компаний, внутренних доменов/ссылок, реальных логинов/email, ID пространств/досок/карточек/каналов в generic-коде, командах, скиллах и документации — только плейсхолдеры. Командная специфика живёт в overlay-репозитории потребителя. Полные правила (в т.ч. для агентов-ревьюверов) — [`REVIEW_GUIDELINES.md`](REVIEW_GUIDELINES.md).
- **Версионирование плагина**: при добавлении или изменении любого скилла/команды — bump `version` в `.claude-plugin/plugin.json` (minor для новых скиллов, patch для изменений существующих).
- **Все команды запускаются из корня репозитория.**
- **Клонирование репозиториев** — только после подтверждения пользователем. Клоны — в `Temp/` (в .gitignore). Только чтение, не пушить в чужие репозитории.
- **Kaiten API** — лимит 100 запросов/мин (HTTP 429 при превышении).
- **Зависимости**: `jq`, `python3`, `gh` (GitHub CLI).

## Documentation Conventions

- **Spike-файлы**: `spikes/YYYY-MM-DD_тема_card-id.md`
- **Feature Specs**: Job Story формат, Gherkin BDD, критерии приёмки как `- [ ]`
