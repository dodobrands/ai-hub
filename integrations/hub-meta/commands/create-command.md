---
name: create-command
description: Create a new slash-command for an integration and register it via symlink
argument-hint: "<integration-name> <command-name>"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "AskUserQuestion"]
---

# Create Command — создание новой slash-команды

Создаёт новую команду в указанной интеграции и регистрирует её через симлинк в `.claude/commands/`.

## Входные параметры

Аргумент: `$ARGUMENTS` — имя интеграции и имя команды.

Формат: `<integration-name> <command-name>`

Пример: `kaiten my-new-command`

## Workflow

### Шаг 1: Валидация

1. Разбери аргументы:
   - `integration-name` — папка интеграции в `integrations/`
   - `command-name` — имя команды (без `.md`)

2. Если аргументы не указаны — спроси у пользователя через AskUserQuestion

3. Проверь, что интеграция существует:
   ```bash
   ls integrations/<integration-name>/
   ```

4. Проверь, что команда не существует:
   ```bash
   test -f integrations/<integration-name>/commands/<command-name>.md && echo "EXISTS" || echo "OK"
   ```

### Шаг 2: Создание файла команды

1. Создай директорию `commands/`, если её нет:
   ```bash
   mkdir -p integrations/<integration-name>/commands
   ```

2. Спроси у пользователя:
   - Описание команды (для поля `description`)
   - Формат аргументов (для поля `argument-hint`), если нужны
   - Краткое описание того, что команда должна делать

3. Создай файл `integrations/<integration-name>/commands/<command-name>.md` со стандартной структурой:

```markdown
---
name: <command-name>
description: <описание>
argument-hint: "<аргументы>"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Task", "AskUserQuestion"]
---

# <Command Name> — <описание>

<Детальное описание workflow>

## Workflow

### Шаг 1: ...

...
```

4. Наполни workflow на основе описания пользователя

### Шаг 3: Регистрация симлинков

Создай **два** относительных симлинка — для локальной работы и для plugin system:

```bash
# 1. Для локальной работы из репо (.claude/commands/ai-hub/)
ln -sf ../../../integrations/<integration-name>/commands/<command-name>.md .claude/commands/ai-hub/<command-name>.md

# 2. Для plugin system (commands/ в корне)
ln -sf ../integrations/<integration-name>/commands/<command-name>.md commands/<command-name>.md
```

**Важно:** симлинки должны использовать **относительные пути**, чтобы работать на любой машине после `git clone`.

### Шаг 4: Добавление в marketplace.json

Добавь запись о новом скилле в `.claude-plugin/marketplace.json` — в массив `plugins`:

```json
{
  "name": "<integration-name>",
  "description": "<описание>",
  "version": "1.0.0",
  "author": {
    "name": "AI Hub Contributors"
  },
  "source": "./integrations/<integration-name>",
  "category": "<automation|productivity|development>",
  "homepage": "https://github.com/dodobrands/ai-hub/tree/main/integrations/<integration-name>"
}
```

### Шаг 5: Обновление README.md

Добавь новый скилл в каталог в `merketplace/README.md`. В файле есть две таблицы скиллов:

1. **«Универсальные — для любой команды»** — скиллы общего назначения, без привязки к конкретной команде
2. **«Специфичные для команды»** — скиллы с захардкоженными настройками (ID досок, колонок, конфигов) под конкретную команду

Определи, в какую таблицу добавить скилл:
- Если скилл использует захардкоженные ID досок/колонок/пространств или конфиги конкретной команды → **«Специфичные для команды»**
- Во всех остальных случаях → **«Универсальные — для любой команды»**

Добавь строку в соответствующую таблицу:
```markdown
| **<Human-Readable Name>** | `/ai-hub:<command-name>` | <короткое описание> |
```

### Шаг 6: Bump версии плагина

Увеличь **patch-версию** в `.claude-plugin/plugin.json` (поле `version`), например `1.0.0` → `1.1.0`.

### Шаг 7: Проверка

1. Убедись, что оба симлинка рабочие:
   ```bash
   ls -la .claude/commands/ai-hub/<command-name>.md
   ls -la commands/<command-name>.md
   ```

2. Покажи результат:
   ```
   Команда создана:
   - Файл: integrations/<integration-name>/commands/<command-name>.md
   - Симлинк (local): .claude/commands/ai-hub/<command-name>.md
   - Симлинк (plugin): commands/<command-name>.md
   - Marketplace: .claude-plugin/marketplace.json (обновлён)
   - README.md: каталог обновлён
   - Доступна как: /ai-hub:<command-name>
   - plugin.json: версия обновлена
   ```

## Важно

- Исходный файл команды **всегда** лежит в `integrations/<name>/commands/` — это source of truth
- В `.claude/commands/ai-hub/` и `commands/` хранятся **только симлинки**
- Симлинки используют **относительные пути**, чтобы работать у всех после клонирования
- `commands/` (корень) — для plugin system, `.claude/commands/ai-hub/` — для работы из самого репо
