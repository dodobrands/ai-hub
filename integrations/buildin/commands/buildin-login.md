---
description: "Login to Buildin via browser MCP (Google SSO) — securely extracts JWT token"
allowed-tools: ["Bash", "mcp"]
---

# Buildin Login — MCP-based browser login

Авторизация в Buildin через браузерный MCP-сервер. Токен — JWT из cookie `next_auth` (НЕ httpOnly, читается через JS).

## Workflow

Каталог скриптов резолвится так, чтобы команда работала из **любого** репозитория
(standalone-клон, subtree-overlay, marketplace-install). Выполни строку-резолвер
перед вызовом скриптов; если bash-блоки запускаются отдельными shell'ами и
переменная между ними не сохраняется — повтори её в начале нужного блока.

```bash
# resolve-buildin-dir:start — первый существующий из кандидатов: плагин-кеш → overlay → standalone
BUILDIN_SCRIPTS=$(ls -d "${CLAUDE_PLUGIN_ROOT:-/nope}/scripts" "$PWD"/integrations/*/integrations/buildin/scripts "$PWD"/integrations/buildin/scripts 2>/dev/null | head -1)
# resolve-buildin-dir:end
```

### Step 0: Проверь существующий токен

```bash
bash "$BUILDIN_SCRIPTS/buildin-login.sh" check
```

Если вывод `ok Name (email)` — токен валиден. Покажи: «Токен ещё валиден. Залогинен как Name.»

Если `error:*` — продолжай к Step 1.

### Step 0.5: Попробуй cookie из браузера (быстрый путь)

Перед использованием MCP попробуй извлечь токен из cookie-store Chrome напрямую — это быстрее и не требует открытия браузера:

```bash
bash integrations/buildin/scripts/buildin-login.sh cookie
```

Если вывод `ok Name (via chrome/...)` — готово, переходи к использованию. Если ошибка — продолжай к Step 1.

### Step 1: Определи доступный MCP

Попробуй `list_pages` (Chrome DevTools MCP). Если отвечает — используй его.

Если MCP недоступен — предложи ручной fallback: пусть юзер откроет buildin.ai, залогинится, и в DevTools Console выполнит:
```js
document.cookie.match(/next_auth=([^;]+)/)?.[1]
```
Затем вставит токен:
```bash
bash "$BUILDIN_SCRIPTS/buildin-login.sh" save "<token>"
```

### Step 2: Открой Buildin в браузере

Используй `navigate_page` с URL `https://buildin.ai/login`

Скажи юзеру: «Открылся браузер с Buildin. Залогинься через Google SSO, если нужно. Скажи когда будет готово.»

Если юзер уже залогинен (redirect на `/chat` или workspace) — сразу переходи к Step 3.

### Step 3: Извлеки токен БЕЗОПАСНО

**Токен НИКОГДА не должен попадать в контекст LLM.** Весь путь: cookie → clipboard → bash → .env.

1. Используй `evaluate_script` — он копирует токен в clipboard и возвращает **только статус**:

```javascript
() => {
  const match = document.cookie.match(/next_auth=([^;]+)/);
  if (!match) return { status: 'error', reason: 'no_cookie' };
  const token = match[1];
  navigator.clipboard.writeText(token);
  return { status: 'copied', length: token.length };
}
```

**ЗАПРЕЩЕНО:**
- Возвращать токен из evaluate_script
- Читать clipboard через evaluate_script
- Логировать или выводить токен любым способом

2. Если `status: 'copied'` — запусти скрипт (он читает clipboard, валидирует, сохраняет, очищает clipboard):

```bash
bash "$BUILDIN_SCRIPTS/buildin-login.sh" clipboard
```

### Step 4: Обработай результат

- `ok Name (email)` — покажи: «Залогинен как Name. Токен сохранён в .env (30 дней).»
- `error:clipboard_empty` — clipboard не заполнился. Попроси юзера вручную скопировать из DevTools Console: `document.cookie.match(/next_auth=([^;]+)/)?.[1]` и вставить через `buildin-login.sh save`.
- `error:validation_failed` — токен невалидный. Предложи перелогиниться.
- `error:not_a_jwt` — в clipboard не JWT. Попроси повторить.

## Ручной fallback

```bash
# 1. Открой buildin.ai и залогинься
# 2. В DevTools Console:
#    document.cookie.match(/next_auth=([^;]+)/)?.[1]
# 3. Скопируй результат и запусти:
bash "$BUILDIN_SCRIPTS/buildin-login.sh" save "<вставь_токен>"
```

## Security

- Cookie `next_auth` — обычная cookie (не httpOnly), читается через JS
- Путь токена: Browser cookie → system clipboard → Bash script → .env
- LLM видит **только** `{status, length}` от JS и `ok Name (email)` от bash
- Токен **НИКОГДА** не появляется в выводе tool-ов, контексте или логах
- Clipboard очищается сразу после сохранения
- JWT действует 30 дней (exp в payload)
