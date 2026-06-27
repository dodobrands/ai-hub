# AI Hub (ИИ концентратор)

Набор AI-инструментов для интеграции с разными полезными сервисами: Kaiten, Time (Mattermost), Buildin, Genie, Holst. Плюс автоматизация spike-исследований, product discovery, тестирования и диагностики.

---

Для AI-агентов есть отдельная короткая инструкция: [INSTALL.md](INSTALL.md).

Если хочешь дать репозиторий другому агенту, удобнее всего давать raw URL на этот файл:

```text
https://raw.githubusercontent.com/sagos95/ai-hub/main/INSTALL.md
```

---

## Установка

### Через marketplace (Claude Code, GitHub Copilot, Cursor, ...)

AI Hub опубликован как marketplace-плагин. Любой AI-агент, поддерживающий marketplace (Claude Code, GitHub Copilot и другие), может установить отдельные плагины или весь набор через свой стандартный механизм.

**Claude Code:**

```bash
# Добавить marketplace (один раз)
claude /plugin marketplace add sagos95/ai-hub

# Установить все инструменты:
claude /plugin install buildin@ai-hub code-review@ai-hub discovery@ai-hub \
  genie@ai-hub holst@ai-hub hub-meta@ai-hub kaiten@ai-hub \
  reverse-product-analysis@ai-hub spike@ai-hub test-factory@ai-hub testops@ai-hub time@ai-hub

# Установить конкретный плагин:
claude /plugin install spike@ai-hub
claude /plugin install kaiten@ai-hub
claude /plugin install time@ai-hub
claude /plugin install testops@ai-hub
```

**GitHub Copilot CLI:**

```bash
# Добавить marketplace (один раз)
copilot plugin marketplace add sagos95/ai-hub

# Установить все инструменты:
copilot plugin install buildin@ai-hub code-review@ai-hub discovery@ai-hub \
  genie@ai-hub holst@ai-hub hub-meta@ai-hub kaiten@ai-hub \
  reverse-product-analysis@ai-hub spike@ai-hub test-factory@ai-hub testops@ai-hub time@ai-hub

# Установить конкретный плагин:
copilot plugin install spike@ai-hub
copilot plugin install testops@ai-hub
```

Доступные плагины: `buildin`, `code-review`, `discovery`, `genie`, `holst`, `hub-meta`, `kaiten`, `reverse-product-analysis`, `spike`, `test-factory`, `testops`, `time`.

### Через git clone или zip + setup

```bash
git clone https://github.com/sagos95/ai-hub.git
cd ai-hub
bash integrations/hub-meta/scripts/setup.sh next
# или: npm run setup
```

Если на машине нет `git`, публичный репозиторий можно скачать как архив:

```bash
curl -L https://github.com/sagos95/ai-hub/archive/refs/heads/main.zip -o ai-hub.zip
unzip ai-hub.zip
cd ai-hub-main
bash integrations/hub-meta/scripts/setup.sh next
```

Если установку делает AI-агент, лучше давать ему [INSTALL.md](INSTALL.md), а не пересказывать шаги вручную.

> `package.json` здесь не делает репу Node-проектом — это тонкий обёрточный файл, чтобы агенты, по привычке запускающие `npm run setup` после клона, автоматически триггерили правильный workflow. Никаких npm-зависимостей нет.

### Настройка токенов (если настраиваешь вручную)

Рекомендованный путь — `/ai-hub:setup` (или `integrations/hub-meta/commands/setup.md` для non-Claude агентов). Если всё же хочешь руками — вот что нужно в `.env`:

| Переменная | Как получить |
|------------|--------------|
| `KAITEN_DOMAIN`, `TIME_BASE_URL`, `BUILDIN_SPACE_ID` | Общий конфиг команды — лежит на странице Buildin `https://buildin.ai/c7ec2023-9025-4c09-be09-e6f54cb07f7e` (если команда использует этот шаблон). Или спроси коллег. |
| `KAITEN_TOKEN` | Kaiten → Настройки профиля → API/Интеграции → Создать токен |
| `BUILDIN_UI_TOKEN` | `/ai-hub:buildin-login` — browser SSO |
| `TIME_TOKEN` | `/ai-hub:time-login` — browser SSO |
| `GENIE_TOKEN` | Опционально, получить у админа данных |
| `TESTOPS_URL`, `TESTOPS_TOKEN` | Allure TestOps → Settings → API Tokens → Generate Token |

Скиллы без токенов (ai-test, rpa-analyze, retro, code-review и т.д.) работают сразу.

### Кастомизация под команду

Скопируй `team-config.example.json` → `team-config.json` и заполни ID своих досок, колонок и каналов. Скрипты и команды подхватят конфиг автоматически.

---

## Структура

```
├── .claude-plugin/
│   └── plugin.json               # Манифест плагина
├── .claude/commands/ai-hub/      # Slash-команды (симлинки на папку integrations/)
├── integrations/                 # Интеграции: скиллы, плагины и т.д.
│   ├── kaiten/                   #   Интеграция с Kaiten (чтение, запись, поиск по доскам, карточкам, и т.д.)
│   ├── buildin/                  #   Buildin (чтение, запись, поиск по страницам)
│   ├── time/                     #   Time (чтение, запись, поиск по сообщениям, каналам, тредам)
│   ├── genie/                    #   Databricks Genie (аналитика)
│   ├── holst/                    #   Holst.so — (в основном чтение досок)
│   ├── spike/                    #   Скилл для технического исследования задачи
│   ├── discovery/                #   Product Discovery (9 фаз)
│   ├── reverse-product-analysis/ #   Реверс-анализ проекта с полным описанием его функционала и сущностей
│   ├── test-factory/             #   Скилл для создания тестов
│   ├── testops/                  #   Allure TestOps (тест-кейсы, запуски, дефекты)
│   ├── code-review/              #   Code review workflow
│   └── hub-meta/                 #   Мета-команды хаба (используется для разработки самого хаба)
├── team-config.example.json      # Шаблон конфига команды
└── CLAUDE.md                     # Инструкции для AI-агента
```

### Архитектура

Каждая интеграция — самодостаточный модуль (scripts/, commands/, skills/, agents/). Нет общих папок-свалок — каждый файл живёт в папке своей интеграции. Можно взять отдельный модуль и переиспользовать его целиком.

```
integrations/
├── integration-1/
│   ├── commands/
│   └── skills/...
├── integration-2/
│   ├── README.md
│   ├── commands/
│   └── skills/...
```

---

## Интеграции

Главная идея — **дать AI-агенту полный контекст из командных систем**, чтобы он мог работать автономно. Агент не ограничен только кодом и git-историей — он читает задачи, обсуждения, wiki, метрики и диагностирует проблемы сам.

### Источники контекста

- **[Kaiten](integrations/kaiten/)** — универсальный клиент для Kaiten API. Чтение и запись карточек, комментариев, чек-листов, свойств, структуры досок и колонок. Фундамент для большинства других интеграций.

- **[Time](integrations/time/)** `/ai-hub:time-chat` — полный доступ к мессенджеру Time (Mattermost). Чтение каналов и тредов, отправка сообщений. Логин через browser-based SSO — токен не попадает в контекст LLM.

- **[Buildin](integrations/buildin/)** `/ai-hub:buildin-read` `/ai-hub:buildin-publish` — чтение и запись во внутреннюю wiki Buildin.ai. Рекурсивное раскрытие вложенных блоков, навигация по дереву, поиск по названию.

- **[Holst](integrations/holst/)** `/ai-hub:holst-export` — экспорт данных с визуальных досок Holst.so (аналог Miro). Фреймы, стикеры, тексты — для превращения брейнштормов в структурированные документы.

- **[Genie](integrations/genie/)** — запросы к DWH на естественном языке через Databricks Genie. Валидация гипотез, сбор метрик, анализ данных прямо в потоке работы.

- **[TestOps](integrations/testops/)** `/ai-hub:testops` — интеграция с Allure TestOps. Поиск тест-кейсов (AQL), просмотр запусков, дефектов, статистики. Создание и обновление тест-кейсов через API.

### Автоматизация процессов

- **[Spike](integrations/spike/)** `/ai-hub:spike` — полный цикл spike-исследования. Три агента (explorer → researcher → architect) последовательно изучают код, ищут best practices и формулируют варианты решения. Структурированный отчёт за 10–20 минут вместо дней ручного погружения.

- **[Discovery](integrations/discovery/)** `/ai-hub:discovery` — Product Discovery в 9 фаз: от формулировки проблемы до go/no-go решения. 12 субагентов передают артефакты друг другу, подтягивая данные из Kaiten и Genie автоматически.

- **[Reverse Analysis](integrations/reverse-product-analysis/)** `/ai-hub:rpa-analyze` — реверс-анализ сервиса по исходному коду. 9 агентов в 4 волны: домен, эндпоинты, поведение, контракты, интеграции, сценарии. Полная карта того, что сервис делает.

### Разработка и качество

- **[Test Factory](integrations/test-factory/)** `/ai-hub:ai-test` — AI-генерация тестов. Два агента в Ralph-loop: coder пишет, reviewer критикует — до 5 итераций до достаточного качества.

- **[Code Review](integrations/code-review/)** `/ai-hub:code-review` — автономный code review через fail-fast pipeline (build → security → performance → architecture → correctness).

---

## Использование как team overlay

AI Hub может использоваться не только самостоятельно, но и как **generic-ядро**, которое команда может расширить своей спецификой внутри своего репозитория ИИ-хаба. Как это работает:

1. Подключи ai-hub в свой overlay-репозиторий как git subtree (см. ниже)
2. Добавь свой `team-config.json` с ID досок и каналов
3. Добавь команднo-специфичные интеграции (например, свой kaiten-workflow с нужными колонками)
4. Добавь `AI_CONTEXT.md` с описанием своей команды и продуктов

Generic-интеграции получают обновления из ai-hub, а командная специфика живёт отдельно.

### Установка (как git subtree)

Из корня своего overlay-репозитория (своего ai-hub):

```bash
curl -sL https://raw.githubusercontent.com/sagos95/ai-hub/main/scripts/install-as-subtree.sh | bash
```

Скрипт делает всё сам:
1. Добавляет remote `ai-hub` и фетчит
2. `git subtree add --prefix=integrations/sagos95-ai-hub ai-hub main --squash`
3. Создаёт симлинки для всех slash-команд в `.claude/commands/ai-hub/`
4. Регистрирует плагин в `.claude/settings.json` (через `jq`, идемпотентно)

После этого команды `/ai-hub:*` доступны сразу — запускай Claude Code и пользуйся. Никаких ручных шагов.

Свой prefix можно передать аргументом:

```bash
curl -sL https://raw.githubusercontent.com/sagos95/ai-hub/main/scripts/install-as-subtree.sh | bash -s integrations/ai-hub
```

Другой namespace (например, чтобы команды стали `/my-hub:*`):
```bash
AI_HUB_NAMESPACE=my-hub curl -sL ... | bash
```

### Обновление subtree

```bash
curl -sL https://raw.githubusercontent.com/sagos95/ai-hub/main/scripts/update-from-ai-hub.sh | bash
# либо с локальным скриптом (если сохранил его в своём репо):
./scripts/update-from-ai-hub.sh [prefix]
```

### Альтернатива — вручную

```bash
# установка
git remote add ai-hub https://github.com/sagos95/ai-hub.git
git fetch ai-hub
git subtree add --prefix=integrations/sagos95-ai-hub ai-hub main --squash

# обновление
git subtree pull --prefix=integrations/sagos95-ai-hub ai-hub main --squash
```

### Пример структуры overlay-репозитория

```
your-team-repo/
├── integrations/
│   ├── sagos95-ai-hub/         ← subtree (read-only для вашей команды; если захочется внести правки, то можно создать PR в sagos95/ai-hub)
│   ├── <your-team>-workflow/   ← команднo-специфичные скиллы
│   └── <other-vendor>/         ← при желании — другой публичный hub как ещё один subtree
├── .claude/
│   ├── settings.json           ← plugins: ["./integrations/sagos95-ai-hub", "."]
│   └── commands/<ns>/          ← симлинки на команды из integrations/*
├── team-config.json            ← локальный (gitignore или без секретов)
├── AI_CONTEXT.md               ← описание команды и продуктов
└── CLAUDE.md                   ← корневые инструкции (vendor-CLAUDE.md игнорятся)
```

**Инвариант:** `integrations/sagos95-ai-hub/` — read-only. Любые правки generic-скиллов идут PR в upstream `sagos95/ai-hub`, затем `update-from-ai-hub.sh` в overlay-репо.

---

## Добавить новый скилл

```bash
# Создать команду (файл + симлинк + запись в registry)
claude /ai-hub:create-command my-integration my-command

# Написать логику в integrations/my-integration/
```

## Лицензия

MIT
