---
description: "Login to Time via browser MCP (Google SSO) — securely extracts token without exposing it to LLM"
allowed-tools: ["Bash", "mcp"]
---

# Time Login

Авторизация в Time. Токен извлекается Bash-скриптом и **НИКОГДА не попадает в контекст LLM**.

**Приоритет способов (пробовать сверху вниз):**
1. **`cookie auto` — ПРИМАРНЫЙ, zero-MCP, без интеракции.** Читает MMAUTHTOKEN прямо из профиля браузера (Chrome/Brave/Edge/Arc/Firefox), где юзер уже залогинен в Time. Самый быстрый путь — **пробовать первым**.
2. **Браузерный MCP** (Chrome DevTools MCP, затем Playwright MCP) — fallback, если `cookie` не дал токен (нет залогиненной сессии / профиль недоступен) и нужен интерактивный Google SSO.
3. **Ручной `sso`** — последний fallback.

⚠️ Браузерный MCP может быть недоступен (например, профиль уже занят запущенным Chrome) — это нормально; переходи к нему только если `cookie` не сработал.

## Workflow

Каталог скриптов резолвится так, чтобы команда работала из **любого** репозитория
(standalone-клон, subtree-overlay, marketplace-install). Выполни строку-резолвер
перед вызовом скриптов; если bash-блоки запускаются отдельными shell'ами и
переменная между ними не сохраняется — повтори её в начале нужного блока.

```bash
# resolve-time-dir:start — первый существующий из кандидатов: плагин-кеш → overlay → standalone
TIME_SCRIPTS=$(ls -d "${CLAUDE_PLUGIN_ROOT:-/nope}/scripts" "$PWD"/integrations/*/integrations/time/scripts "$PWD"/integrations/time/scripts 2>/dev/null | head -1)
# resolve-time-dir:end
TIME_DIR=$(dirname "$TIME_SCRIPTS")   # каталог интеграции — для .cache / .time-signature
```

### Step 0: Проверь существующий токен

```bash
"$TIME_SCRIPTS/time-login.sh" check
```

Если вывод `ok @username (email)` — токен валиден, дальше делать ничего не нужно. Покажи: «Токен ещё валиден. Залогинен как @username.»

Если `error:*` или ненулевой exit code — продолжай к Step 1.

### Step 1: Cookie-извлечение (ПРИМАРНЫЙ путь, без MCP) — пробуй первым

```bash
"$TIME_SCRIPTS/time-login.sh" cookie auto
```

Читает MMAUTHTOKEN из браузера, где юзер залогинен в Time (итерирует профили Chrome/Brave/Edge/Arc/Firefox), валидирует и сохраняет токен в `.env`. Без браузерного MCP и без сети.

- Может всплыть системный диалог Keychain («доступ к Chrome Safe Storage») — попроси юзера нажать «Разрешить» / «Always Allow».
- `ok @username (via <browser>/<profile>)` — готово, токен сохранён. Покажи юзеру и **заверши логин** (Step 2–5 не нужны; переходи сразу к Step 6 — постфикс).
- Не нашёл валидного токена (нет залогиненной сессии в браузере / все профили разлогинены) — переходи к Step 2 (браузерный MCP, интерактивный SSO).

### Step 2: Определи доступный MCP (fallback, если Step 1 не дал токен)

Проверь, какой браузерный MCP доступен у юзера. Попробуй вызвать любой read-only MCP-тул:

**Вариант A — Chrome DevTools MCP:**
Попробуй `list_pages` или `take_snapshot`. Если MCP отвечает — используй его.

**Вариант B — Playwright MCP:**
Попробуй `browser_snapshot`. Если MCP отвечает — используй его.

**Вариант C — Нет MCP:**
Если ни один MCP недоступен, предложи юзеру установить Chrome DevTools MCP, и с его согласия автоматически, сам установи этот MCP.

Если юзер не хочет MCP — предложи ручной fallback:
```bash
"$TIME_SCRIPTS/time-login.sh" sso
```

### Step 3: Открой Time в браузере через MCP

**Chrome DevTools MCP:**
Используй `navigate_page` с URL `$TIME_BASE_URL`

**Playwright MCP:**
Используй `browser_navigate` с URL `$TIME_BASE_URL`

Скажи юзеру: «Открылся браузер. Залогинься через Google SSO, если нужно. Скажи когда будет готово.»

### Step 4: Дождись логина и извлеки токен

Когда юзер подтвердит что залогинился:

**Chrome DevTools MCP:**
1. Используй `evaluate_script` чтобы проверить логин:
   - script: вызови fetch к `$TIME_BASE_URL/api/v4/users/me` и проверь что ответ 200
2. Если ответ 200 — юзер залогинен. Попроси юзера скопировать MMAUTHTOKEN cookie:
   - DevTools MCP не имеет прямого доступа к httpOnly cookies через JS
   - Попроси юзера: «Скопируй MMAUTHTOKEN из DevTools → Application → Cookies → $TIME_BASE_URL»
3. Запусти Bash-скрипт для сохранения токена из clipboard:
```bash
bash "$TIME_SCRIPTS/time-save-token-from-clipboard.sh"
```

**Playwright MCP (fallback):**
1. Используй `browser_storage_state` чтобы сохранить cookies в файл:
   - filename: `"$TIME_DIR/.cache/storage-state.json"`
2. Запусти Bash-скрипт для безопасного извлечения токена:
```bash
bash "$TIME_SCRIPTS/time-extract-token-from-storage.sh" "$TIME_DIR/.cache/storage-state.json"
```

### Step 5: Обработай результат

- `ok @username (email)` — покажи: «Залогинен как @username. Токен сохранён в .env.»
- `error:no_mmauthtoken` — юзер не залогинился или cookie не появилась. Предложи повторить.
- `error:validation_failed` — токен невалидный. Предложи перелогиниться.
- `error:no_storage_file` / `error:file_not_found` — проблема с файлом. Проверь путь.

### Step 6: Настройка постфикса сообщений

После успешного логина спроси пользователя:

«Хочешь добавить постфикс к сообщениям, отправляемым через AI? Например, эмодзи `:robot:` или текст `(via AI)`. Если нет — сообщения будут отправляться без постфикса.»

- Если пользователь хочет постфикс — сохрани его:
```bash
echo " <постфикс>" > "$TIME_DIR/.time-signature"
```
(пробел перед постфиксом — чтобы он не слипался с текстом сообщения)

- Если не хочет — ничего не делай (файл `.time-signature` не создаётся, подпись пустая).

## Ручной fallback

Если MCP не работает или юзер предпочитает терминал:
```bash
"$TIME_SCRIPTS/time-login.sh" sso
```

## Security

- Токен: Browser MCP → storage-state файл → Bash script → .env
- LLM видит только статусные сообщения (`ok`, `error:*`)
- Storage-state файл удаляется сразу после извлечения токена
- Не привязан к конкретному браузеру — работает с любым MCP
