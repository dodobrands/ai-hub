---
name: setup
description: "AI Hub initial setup — configure company environment and personal tokens"
argument-hint: "[buildin_config_page_url]"
allowed-tools: ["Bash", "Read", "AskUserQuestion", "mcp"]
---

# AI Hub Setup

**Primary path:** `bash integrations/hub-meta/scripts/setup.sh next` — этот скрипт в цикле печатает ТЕКУЩИЙ шаг с точными командами. Крути до `STATUS: DONE`. Большинству агентов этого достаточно — дальше можно не читать.

Этот файл — длинная reference-документация на те же шаги (если агент хочет понять "зачем"). Читай сверху вниз и выполняй. Не суммаризируй, не пропускай, не останавливайся раньше времени.

## Hard rules (инварианты)

1. **НЕ останавливайся на `git clone`**. Клон — только половина установки. Если ты только что склонировал репо и пришёл сюда — сразу начинай Step 0.
2. **НЕ сообщай "установка завершена", пока все mandatory переменные `.env` не `=set`**. Финальный статус определяется выводом `env-manager.sh check`, а не твоим ощущением.
3. **Отсутствие браузерного MCP — НЕ блокер**. У КАЖДОГО login-шага ниже есть **manual fallback**: юзер сам открывает браузер, копирует токен из DevTools Console, присылает тебе текстом. Никакой MCP для этого не нужен.
4. **Порядок шагов важен.** Buildin первый, потому что там лежит конфиг-страница с `KAITEN_DOMAIN`. Не меняй порядок.
5. **Если любой шаг не удался** — переходи к его manual fallback, не просто пропускай.

## Constants

```
ENV_MANAGER         = integrations/hub-meta/scripts/env-manager.sh
BUILDIN_LOGIN       = integrations/buildin/scripts/buildin-login.sh
BUILDIN_PAGES       = integrations/buildin/scripts/buildin-pages.sh
DEFAULT_CONFIG_PAGE = https://buildin.ai/c7ec2023-9025-4c09-be09-e6f54cb07f7e
```

## Checklist

Отмечай выполненные шаги в голове. Не докладывай успех, пока не дошёл до Step 7.

- [ ] Step 0 — миграция `.env.local`
- [ ] Step 1 — проверка текущего состояния
- [ ] Step 2 — логин в Buildin (MCP **или** manual)
- [ ] Step 3 — чтение конфиг-страницы → `KAITEN_DOMAIN`, `BUILDIN_SPACE_ID` (fallback: спросить юзера напрямую)
- [ ] Step 4 — логин в Holst (MCP-only, пропускается без MCP)
- [ ] Step 5 — токен Kaiten (всегда manual)
- [ ] Step 6 — `team-config.json`
- [ ] Step 7 — финальная проверка

## Step 0 — миграция

```bash
bash integrations/hub-meta/scripts/env-manager.sh migrate
```

- `migrated:*` → предупреди юзера «переименовал `.env.local` → `.env`».
- `warning:both exist` → попроси объединить вручную, **продолжай**.
- `ok:nothing to migrate` → молчи.

## Step 1 — проверка состояния

```bash
bash integrations/hub-meta/scripts/env-manager.sh check
```

Если ВСЕ mandatory (`KAITEN_DOMAIN`, `BUILDIN_SPACE_ID`, `KAITEN_TOKEN`, `BUILDIN_UI_TOKEN`) `=set` → **прыгай на Step 6**.

Иначе — продолжай по порядку.

## Step 2 — Buildin login

### 2a. Быстрый check

```bash
bash integrations/buildin/scripts/buildin-login.sh check
```

- `ok Name (email)` → токен валиден, **пропусти к Step 3**.
- `error:*` → нужен логин, переходи к 2b.

### 2b. Есть браузерный MCP?

Попробуй Chrome DevTools MCP (`list_pages`) или Playwright MCP (`browser_snapshot`).

- **MCP отвечает** — выполни workflow из `integrations/buildin/commands/buildin-login.md` (открой `https://buildin.ai/login`, дождись SSO, извлеки cookie `next_auth` через `evaluate_script` в clipboard, запусти `bash integrations/buildin/scripts/buildin-login.sh clipboard`). Токен в контекст LLM не попадает.
- **MCP нет** — переходи к 2c (manual fallback).

### 2c. Manual fallback (никакого MCP не нужно)

Дай юзеру ровно эту инструкцию (можешь парафразировать, но сохрани шаги):

> 1. Открой в браузере `https://buildin.ai` и залогинься через Google SSO.
> 2. Нажми `F12` → вкладка **Console**.
> 3. Вставь и выполни: `document.cookie.match(/next_auth=([^;]+)/)?.[1]`
> 4. Скопируй результат (это JWT) и пришли мне сюда.

Когда юзер пришлёт токен:

```bash
bash integrations/buildin/scripts/buildin-login.sh save "<token>"
```

- `ok Name (email)` → логин ОК, переходи к Step 3.
- `error:*` → попроси юзера повторить (возможно, скопировал не тот cookie).

## Step 3 — чтение конфиг-страницы

### 3a. Если Buildin login прошёл — попробуй автоподтяжку

Определи `page_id`: последний UUID из `$ARGUMENTS` (если юзер передал URL), иначе из `DEFAULT_CONFIG_PAGE`.

```bash
bash integrations/buildin/scripts/buildin-pages.sh read "<page_id>"
```

Из вывода извлеки все строки `[A-Z_]+=<непустое>`. Для каждой:

```bash
bash integrations/hub-meta/scripts/env-manager.sh set "<KEY>" "<VALUE>"
```

Покажи юзеру только ключи (не значения): «Подтянул: `KAITEN_DOMAIN`, `BUILDIN_SPACE_ID`». Дальше Step 4.

### 3b. Manual fallback (Buildin недоступен / страница 404 / Step 2 пропущен)

**Не пропускай этот шаг** — без `KAITEN_DOMAIN` остальные скиллы не работают.

Спроси юзера напрямую (через `AskUserQuestion`, если есть; иначе просто текстом):

- **`KAITEN_DOMAIN`** — домен Kaiten без схемы. Пример: `yourcompany.kaiten.ru`.
- **`BUILDIN_SPACE_ID`** — ID пространства Buildin (опционально, можно пустое).

Если юзер не знает — попроси открыть соответствующий сервис в браузере и скопировать из адресной строки.

Сохрани каждое:

```bash
bash integrations/hub-meta/scripts/env-manager.sh set KAITEN_DOMAIN "<value>"
bash integrations/hub-meta/scripts/env-manager.sh set BUILDIN_SPACE_ID "<value>"   # опционально
```

## Step 4 — Holst login (опционально)

Holst хранит сессию в самом браузере — отдельный токен не нужен.

- **Есть Chrome DevTools MCP** — через `navigate_page` открой `https://app.holst.so/`, попроси юзера залогиниться и подтвердить «готово». Вкладка останется активной для будущих `/ai-hub:holst-export`.
- **Нет MCP** — пропусти шаг. Скажи юзеру: «Holst потребует залогиниться при первом использовании `/ai-hub:holst-export`, настроить заранее без браузерного MCP нельзя». Это ОК, продолжай.

## Step 5 — Kaiten token (всегда manual, MCP не помогает)

```bash
bash integrations/hub-meta/scripts/env-manager.sh has KAITEN_TOKEN && echo set || echo missing
```

Если `set` — провалидируй:

```bash
source .env && curl -sS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $KAITEN_TOKEN" \
  "https://$KAITEN_DOMAIN/api/latest/users/current"
```

`200` → пропусти к Step 6. Иначе — попроси пересоздать.

Если `missing` — дай юзеру инструкцию (подставь актуальный `$KAITEN_DOMAIN`):

> 1. Открой `https://$KAITEN_DOMAIN/profile`.
> 2. **Настройки профиля → API/Интеграции → Создать токен**.
> 3. Скопируй и пришли мне сюда.

Когда юзер пришлёт:

```bash
bash integrations/hub-meta/scripts/env-manager.sh set KAITEN_TOKEN "<token>"
```

Провалидируй тем же curl-ом. Не `200` — попроси повторить.

## Step 6 — team-config.json

```bash
test -f team-config.json && echo exists || echo missing
```

- `exists` → пропусти.
- `missing` → ищи шаблон в порядке приоритета:
  - `team-config.example.json` (standalone installation)
  - `integrations/sagos95-ai-hub/team-config.example.json` (subtree installation в overlay-репо)

Если шаблон найден: `cp <example> team-config.json`. Спроси юзера:

> «Создал `team-config.json` из шаблона. Заполнить сейчас вместе (я задам вопросы) или оставить заглушки — заполнишь руками позже?»

**Если "вместе"** — через `AskUserQuestion` или текстом запроси по одному полю: `kaiten.space_id`, `kaiten.boards.sprint.id`, колонки. Для Kaiten-доски принимай URL и извлекай ID после `/board/`. Записывай через `jq`:

```bash
tmp=$(mktemp)
jq '.kaiten.space_id = ($v | tonumber)' --arg v "$ANSWER" team-config.json > "$tmp" && mv "$tmp" team-config.json
```

**Если "позже"** — назови путь и ключи, которые нужно заполнить.

## Step 7 — финальная проверка

```bash
bash integrations/hub-meta/scripts/env-manager.sh check
```

- Все mandatory `=set` → **сейчас можно сказать "готово"**. Выведи 2-3 примера команд, которыми юзер может протестировать:
  - `/ai-hub:buildin-read <url>`
  - `/ai-hub:spike <kaiten-url>`
- Остались `missing` в mandatory → НЕ говори "готово". Назови что осталось и предложи повторить соответствующий шаг.
- `missing` только в optional (`GENIE_*`) → скажи «готово, опциональное можно настроить позже».

## Anti-patterns (что НЕ делать)

- ❌ Остановиться после клона и сказать «репозиторий установлен, настрой `.env` руками». **Ты обязан пройти setup.**
- ❌ Остановиться на Step 2/3 из-за отсутствия браузерного MCP. **Есть manual fallback — используй его.**
- ❌ Пропустить Step 3 manual fallback, оставив `KAITEN_DOMAIN` пустым. **Без него ничего не работает — спроси юзера.**
- ❌ Сообщать «дошёл до Step 6», если Steps 2–3 не выполнены. **Checklist линейный.**
- ❌ Вставлять токен в сообщение пользователя или в логи. **Только через `env-manager.sh set` в `.env`.**
- ❌ Начинать с Step 6 (`team-config.json`). **Это последний content-шаг, не первый.**
