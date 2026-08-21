---
description: "Time (Mattermost) → Claude Code Channel: проверить готовность коннектора и получить команду запуска"
argument-hint: "[check]"
allowed-tools: ["Bash", "Read", "AskUserQuestion"]
---

# Time Connector — интерактивный бот в Time

Коннектор делает из запущенной сессии Claude Code «мозг» бота в Time: коллеги из whitelist
пишут боту в ЛС, @упоминают его в канале или отвечают в его треде — сообщение прилетает в эту
сессию как `<channel …>`, а ты отвечаешь инструментом `reply` в тот же тред/ЛС.
Подробности — `integrations/time/README.md`, раздел «Connector».

Это **research-preview фича Claude Code (Channels)**: канал подключается только **флагом при
старте `claude`** — включить его из уже запущенной сессии нельзя. Поэтому задача этой команды:
проверить предпосылки и выдать пользователю точную команду перезапуска.

## Workflow

Каталог скриптов резолвится так, чтобы команда работала из **любого** репозитория
(standalone-клон, subtree-overlay, marketplace-install). Выполни строку-резолвер
перед вызовом скриптов; если bash-блоки запускаются отдельными shell'ами и
переменная между ними не сохраняется — повтори её в начале нужного блока.

```bash
# resolve-time-dir:start — первый существующий из кандидатов: плагин-кеш → overlay → standalone
TIME_SCRIPTS=$(ls -d "${CLAUDE_PLUGIN_ROOT:-/nope}/scripts" "$PWD"/integrations/*/integrations/time/scripts "$PWD"/integrations/time/scripts 2>/dev/null | head -1)
# resolve-time-dir:end
chmod +x "$TIME_SCRIPTS"/*.sh
```

### Шаг 1. Предпосылки (без сети, без секретов)

```bash
bash "$TIME_SCRIPTS/time-connector.sh" print-env
```

Разбери вывод:

- **`RUNTIME=missing`** → нужен `bun` (https://bun.sh) или Node.js ≥ 22.6. Скажи пользователю,
  что поставить, и остановись.
- **`TIME_BOT_TOKEN=missing`** → коннектору нужен **токен бот-аккаунта Time** (не личный
  `TIME_TOKEN`). Объясни пользователю:
  - токен создаётся в Time → Menu → Integrations → Bot Accounts → Add Bot Account (если прав
    нет — запросить у администратора Time в компании);
  - боту нужны **права на сообщения**: галочка «Post to channels» (`post:all`) при создании и
    членство в каналах, где его будут упоминать (`/invite @имя-бота`); ЛС работают без приглашений;
  - токен записывается в `.env` **в терминале**, не в чат:
    `bash integrations/hub-meta/scripts/env-manager.sh set TIME_BOT_TOKEN <token>`
    (в plugin-cache раскладке — `bash "$(ls -d "$TIME_SCRIPTS"/../../../hub-meta/*/scripts | sort -V | tail -1)/env-manager.sh" set …`).
  После этого — повтори Шаг 1.
- **Whitelist.** Если `TIME_TEAM_CONFIG` указывает на файл — проверь в нём
  `.time.connector.allowed_users` (`jq '.time.connector.allowed_users' <файл>`). Если пусто и
  `TIME_CONNECTOR_ALLOWED_USERS` тоже пуст — **бот будет молча дропать все сообщения**. Спроси у
  пользователя список username'ов Time (без `@`) и предложи один из вариантов:
  - `team-config.json`: `jq '.time.connector.allowed_users = ["j.doe","a.smith"]' team-config.json > t && mv t team-config.json`
  - или `.env`: `bash integrations/hub-meta/scripts/env-manager.sh set TIME_CONNECTOR_ALLOWED_USERS j.doe,a.smith`

### Шаг 2. Проверка подключения (REST, без MCP)

```bash
bash "$TIME_SCRIPTS/time-connector.sh" check
```

Покажи пользователю: имя бота, какие username'ы из whitelist нашлись (`✓`/`✗`), в каких
тимах состоит бот. `error:token_invalid` → токен неверный/отозван; `STATUS: WARN` → чаще всего
пустой whitelist. Напомни: @упоминания приходят только из каналов, куда бот добавлен.

Если аргумент команды — `check`, на этом остановись.

### Шаг 3. Регистрация MCP-сервера и команда запуска

Коннектор **намеренно не объявлен в plugin-уровневом `.mcp.json`** — иначе он стартовал бы в
каждой сессии с плагином `time` (и без флага channels молча «акал» бы коллегам). Поэтому сервер
регистрируется один раз на уровне пользователя, одинаково для всех раскладок (клон, overlay,
plugin-cache) — путь берётся из `$TIME_SCRIPTS`:

1. Проверь, что уже зарегистрировано: `claude mcp get time-connector`. Если сервера нет **или** его
   путь не совпадает с `$TIME_SCRIPTS/time-connector.sh` (например, после обновления плагина
   сменилась версия в пути) — **спроси подтверждение** и выполни:
   ```bash
   claude mcp remove --scope user time-connector 2>/dev/null
   claude mcp add --scope user time-connector -- bash "$TIME_SCRIPTS/time-connector.sh" serve
   ```
2. Напечатай пользователю команду запуска (не запускай `claude` сам):
   ```
   claude --dangerously-load-development-channels server:time-connector
   ```

Объясни:
- флаг работает только при старте — нужно выйти из текущей сессии и запустить `claude` с ним;
  при старте Claude Code покажет предупреждение о dev-channels — это ожидаемо;
- для Team/Enterprise админ должен включить Channels (`channelsEnabled`);
- один коннектор на бота: две сессии с флагом ответят на одно сообщение обе;
- проверка: `/mcp` в новой сессии покажет `time-connector` connected с тулами `reply` и `react`.
  В сессиях **без** флага сервер тоже стартует (он user-scope) — это безобидно, но если мешает,
  `claude mcp remove --scope user time-connector` между использованиями.

### Шаг 4. Быстрая проверка в Time

Подскажи: написать боту в личку с аккаунта из whitelist или `@имя-бота` в канале, где он
состоит. В сессии появится `← time-connector · j.doe: …`; ответ уйдёт тем же каналом.
Запросы разрешений на tool-коллы бот присылает в **ЛС** последнему написавшему — ответ
`yes <код>` / `no <код>`.
