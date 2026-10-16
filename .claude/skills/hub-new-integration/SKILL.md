---
name: hub-new-integration
description: >
  Use when adding a new integration or plugin to the ai-hub repo: «новая интеграция»,
  «подключи <сервис> к хабу», «заведи плагин», «добавь клиент для <API>». Собирает каркас
  целиком за один проход: каталог, plugin.json и запись в marketplace.json с одной версией,
  load-env, скрипт-клиент по контракту, команда или скилл с glob-free резолвером, симлинки,
  bats-тест со стабом curl, гейт path-resolution, README, .env.example.
---

# hub-new-integration: каркас интеграции без забытых хвостов

Типовые потери на новой интеграции: плагин не попал в `marketplace.json`, версии
разъехались, нет симлинка команды, резолвер работает только из корня клона, нет тестов,
агент не знает, когда звать. Этот скилл закрывает всё сразу.

## Вход

Спроси, если не дано: `<name>` (kebab-case), что за сервис и его публичные доки API,
способ авторизации (токен в `.env`, SSO через браузер, ключ), 2-3 первых операции.

## Шаги

### 1. Каталог

```text
integrations/<name>/
├── .claude-plugin/plugin.json
├── README.md
├── commands/<name>-<action>.md        # если нужна slash-команда
├── skills/<name>/SKILL.md             # если должно срабатывать само по контексту
├── scripts/<name>.sh                  # клиент API
└── tests/<name>.bats
```

Команда, если пользователь зовёт явно (`/ai-hub:<name>-...`). Скилл, если агент должен
сам понять, что пора (ссылка на сервис в сообщении, ключевые слова).

### 2. Манифесты (одна версия в двух местах)

`integrations/<name>/.claude-plugin/plugin.json`:

```json
{
  "name": "<name>",
  "version": "0.1.0",
  "description": "<что даёт агенту, одной фразой>",
  "author": { "name": "AI Hub Contributors" }
}
```

Запись в `.claude-plugin/marketplace.json` → `plugins[]` с той же `version`, `source:
"./integrations/<name>"`, `category`, `homepage` по образцу соседей. Подними minor в
корневом `.claude-plugin/plugin.json`.

### 3. Скрипт-клиент

По контракту из скилла `hub-script-dev`: `load-env.sh`, `curl -sS` с проверкой HTTP-кода,
JSON в stdout, ошибки в stderr, rc != 0 при отказе, `usage` при неизвестной подкоманде.
Токен добавь в список секретов `integrations/hub-meta/scripts/load-env.sh` и в
`.env.example` с плейсхолдером.

### 4. Команда или скилл

Блок резолвера в начале (без glob, см. `hub-script-dev`, раздел 4), с маркерами
`# resolve-<name>-dir:start` / `:end`. Дальше: когда применять, примеры вызова каждой
операции, как читать результат, как выглядит отказ и что делать агенту.

Описание (`description`) пиши под триггеры: какие фразы и ссылки пользователя
активируют. Без реальных доменов, только `https://<domain>.<service>/...`.

### 5. Симлинки

```bash
ln -s ../../../integrations/<name>/commands/<file>.md .claude/commands/ai-hub/<file>.md
```

Для команд также можно `/ai-hub:create-command <name> <command>`.

### 6. Тесты и CI

- `tests/<name>.bats` по образцу `integrations/kaiten/tests/endpoint-normalization.bats`:
  успех, 401, 500, обрыв сети, ошибка в теле. `shell-tests.yml` подхватит сам.
- В `tests/path-resolution.sh` добавь маркер-скрипт интеграции в таблицу `MARK`, а пути
  `commands/`, `skills/`, `scripts/` интеграции в `paths` у `.github/workflows/path-resolution.yml`.

### 7. Документация

- `integrations/<name>/README.md`: что умеет, настройка `.env`, примеры, ограничения API
  (лимиты запросов, пагинация).
- Строка в дерево `Architecture` и, если это источник данных, строка в таблицу
  `Data Sources` в `CLAUDE.md`. Раздел в корневом `README.md`, если там есть список.

### 8. Проверка

```bash
bash .claude/skills/hub-preflight/scripts/preflight.sh
```

Затем `hub-self-review`. Если в плагине-потребителе каталог установится иначе (subtree,
marketplace), проверь резолвер руками хотя бы в одном неродном сценарии.
