# Databricks Genie

CLI инструменты для интеграции LLM агентов с Databricks Genie — запросы аналитических данных на естественном языке.

Авторизация — OAuth через [databricks CLI](https://docs.databricks.com/aws/en/dev-tools/cli/install): токен хранит и обновляет сам CLI, в `.env` и в скрипты он не попадает. Personal Access Token (PAT) не нужен.

Зависимости: databricks CLI (проверено на v1.13.0; нужна группа команд `genie`), `python3` и плагин `hub-meta` — из него берётся загрузчик `.env` (`hub-meta/scripts/load-env.sh`).

## Структура

```
├── GENIE_API.md             # Документация REST API
├── MCP_INTEGRATION.md       # Документация MCP подключения
├── README.md                # Этот файл
├── scripts/
│   ├── genie-config.sh      # Конфигурация
│   └── genie.sh             # CLI для запросов данных
└── tests/
    ├── genie.bats           # Тесты genie.sh (стаб databricks CLI, без сети)
    └── fixtures/            # Обезличенный реальный вывод CLI
```

## Быстрый старт

### 1. Установите databricks CLI и залогиньтесь

```bash
brew tap databricks/tap && brew install databricks   # или см. ссылку на установку выше
databricks auth login --host https://<workspace>.azuredatabricks.net --profile <profile>
```

Логин открывает браузер (SSO) один раз; дальше CLI сам обновляет токен. Проверка:

```bash
databricks auth profiles                       # профиль должен быть valid
databricks genie list-spaces --profile <profile>   # доступные Genie space и их space_id
```

Сам токен (`databricks auth token`) в терминал не выводите — он нужен только внутри пайпа, см. [MCP_INTEGRATION.md](./MCP_INTEGRATION.md).

### 2. Настройка окружения

```bash
# Добавьте в .env (корень репозитория или overlay-репозитория):
GENIE_SPACE_ID=<space_id>                            # из list-spaces
GENIE_HOST=https://<workspace>.azuredatabricks.net   # workspace; общий для команды
GENIE_PROFILE=<profile>                              # опционально: профиль CLI, важнее GENIE_HOST
```

Как выбирается workspace:

| `GENIE_PROFILE` | `GENIE_HOST` | Куда идёт запрос |
|---|---|---|
| задан | любой | профиль `GENIE_PROFILE` (хост берётся из него) |
| пусто | задан | профиль с этим хостом — CLI находит его сам; если таких профилей несколько, задайте `GENIE_PROFILE` |
| пусто | пусто | профиль CLI по умолчанию (`DATABRICKS_CONFIG_PROFILE`, `default_profile` или `DEFAULT` в `~/.databrickscfg`) |

Ни одна из переменных не секретная.

### Переход с genie 1.x

1. Удалите `GENIE_TOKEN` из `.env` и отзовите этот PAT в Databricks (User Settings → Developer → Access tokens). Пока переменная в `.env`, `genie.sh` предупреждает о ней.
2. Залогиньтесь: `databricks auth login --host $GENIE_HOST`. Если `GENIE_HOST` уже есть в `.env`, больше ничего настраивать не нужно.

### 3. Примеры использования

```bash
# Простой запрос (показывает SQL и таблицы)
./integrations/genie/scripts/genie.sh "how many orders yesterday?"

# Топ локаций
./integrations/genie/scripts/genie.sh "top-10 locations by revenue this week"

# Без SQL деталей (чистый ответ)
./integrations/genie/scripts/genie.sh --no-sql "how many orders yesterday?"

# Полный JSON ответ
./integrations/genie/scripts/genie.sh --raw "how many orders yesterday?"
```

Каждый вопрос выполняет SQL на warehouse, привязанном к space: если warehouse спит, первый запрос его разбудит (это и время, и деньги).

Параллельные вызовы (например, волна агентов) безопасны для логина: перед вопросом `genie.sh` под короткой блокировкой прогревает access token (`databricks auth token`, вывод отброшен). Токен обновится один раз, даже если в аккаунте Databricks включены single-use refresh tokens, при которых одновременные обновления выбивали бы друг друга и требовали перелогина.

### Пример вывода

```
Yesterday there were **27,599 orders**.

──────────────────────────────────────────────────
📊 SQL Query:
SELECT COUNT(DISTINCT `OrderId`) AS Orders_Count
FROM `analytics`.`gold`.`orders`
WHERE `SaleDate` = current_date - 1

📁 Tables: analytics.gold.orders

💡 Suggested questions:
   • What was the revenue yesterday?
```

## Использование с LLM агентами

### Оценка импакта фичи

```bash
./integrations/genie/scripts/genie.sh "what is the average daily revenue per location?"
./integrations/genie/scripts/genie.sh "how many delivery orders were there last month?"
```

### Анализ метрик

```bash
./integrations/genie/scripts/genie.sh "what is the average order value?"
./integrations/genie/scripts/genie.sh "top-5 regions by number of orders"
```

## Доступные данные

Genie имеет доступ к аналитическим данным, сконфигурированным в вашем Genie Space:

| Категория | Примеры метрик |
|-----------|----------------|
| Orders | count, revenue, average check |
| Geography | regions, locations |
| Time | yesterday, week, month, custom periods |
| Channels | delivery, pickup, etc. |

## API Reference

- REST API: [GENIE_API.md](./GENIE_API.md)
- MCP Integration: [MCP_INTEGRATION.md](./MCP_INTEGRATION.md)

## Troubleshooting

### Коды выхода `genie.sh`

| Код | Значение |
|---|---|
| 0 | ответ получен |
| 1 | ошибка (текст ошибки CLI выше): запрос не удался, нет доступа, таймаут, старый CLI, нет конфига |
| 2 | нужен логин. Он открывает браузер, поэтому его выполняет пользователь; агент останавливается и просит его |

### Нужен логин (код 2: `cannot configure default credentials`, `refresh token is invalid`, нет профиля)

Выполните команду из подсказки скрипта — она ведёт в тот же workspace, что и запрос (по `GENIE_PROFILE` или `GENIE_HOST`).

### `Unauthorized access to Org` / 403 / space не найден

Логин не поможет: у учётной записи нет доступа к workspace, space или его warehouse — это выдаётся правами. Проверьте `databricks genie list-spaces --profile <profile>` и `GENIE_SPACE_ID`.

### `databricks CLI not found` / `Update databricks CLI`

Установите или обновите CLI (см. шаг 1).

### Пустой ответ

Попробуйте переформулировать вопрос или добавить контекст (страна, период)

### Таймаут

Скрипт ждёт ответ до 5 минут. Сложные запросы могут выполняться дольше, попробуйте упростить запрос
