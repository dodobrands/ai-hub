# Databricks Genie

CLI инструменты для интеграции LLM агентов с Databricks Genie — запросы аналитических данных на естественном языке.

Авторизация — OAuth через [databricks CLI](https://docs.databricks.com/aws/en/dev-tools/cli/install): токен хранит и обновляет сам CLI, в `.env` и в скрипты он не попадает. Personal Access Token (PAT) не нужен.

## Структура

```
├── GENIE_API.md             # Документация REST API
├── MCP_INTEGRATION.md       # Документация MCP подключения
├── README.md                # Этот файл
├── scripts/
│   ├── genie-config.sh      # Конфигурация
│   └── genie.sh             # CLI для запросов данных
└── tests/
    └── genie.bats           # Тесты genie.sh (стаб databricks CLI, без сети)
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

### 2. Настройка окружения

```bash
# Добавьте в .env (корень репозитория или overlay-репозитория):
GENIE_SPACE_ID=<space_id>                        # из list-spaces
GENIE_PROFILE=<profile>                          # профиль из шага 1; пусто — профиль DEFAULT
GENIE_HOST=https://<workspace>.azuredatabricks.net   # опционально: только для подсказки с командой логина
```

Ни одна из переменных не секретная.

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

### Ошибка авторизации (401, `cannot configure default credentials`, `refresh token is invalid`)

Залогиньтесь заново: `databricks auth login --host <workspace-url> --profile <profile>`. Скрипт печатает эту команду с вашими `GENIE_HOST` и `GENIE_PROFILE`.

### 403 / space не найден

У профиля нет доступа к space или к его warehouse. Проверьте `databricks genie list-spaces --profile <profile>` и `GENIE_SPACE_ID`.

### `databricks CLI not found`

Установите CLI (см. шаг 1).

### Пустой ответ

Попробуйте переформулировать вопрос или добавить контекст (страна, период)

### Таймаут

Скрипт ждёт ответ до 5 минут. Сложные запросы могут выполняться дольше, попробуйте упростить запрос
