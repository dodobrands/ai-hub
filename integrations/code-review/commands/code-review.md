---
name: code-review
description: "Autonomous C#/.NET code review — fail-fast pipeline (build → security → performance → architecture → correctness → UI)"
argument-hint: "<path-to-repo> [--card <kaiten-id>] [--pr <url>] [--desc \"что проверить\"] [--base <branch>]"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Agent", "AskUserQuestion"]
---

# /ai-hub:code-review — Автономное ревью C#/.NET кода

Fail-fast pipeline: 6 стадий от дешёвых к дорогим. Проверяет **только изменения** (diff) относительно base-ветки. Первая найденная BLOCK-проблема → стоп, отчёт. Повторный запуск продолжает с незавершённой стадии.

## Константы

```
SCRIPTS_DIR = integrations/code-review/scripts
AGENTS_DIR  = integrations/code-review/agents
STATE_FILE  = .code-review-state.json   # в корне целевого репо
BASELINE_FILE = .code-review-baseline.json  # замьюченные findings
```

## Аргументы

`$ARGUMENTS` парсится следующим образом:

- Первый позиционный аргумент — `REPO_PATH` (абсолютный путь к репозиторию, обязательно)
- `--card <id>` — Kaiten card ID для получения контекста задачи
- `--pr <url>` — ссылка на GitHub PR (извлекается описание и комментарии)
- `--desc "текст"` — текстовое описание того, что именно нужно проверить
- `--base <branch>` — ветка для сравнения (по умолчанию `main`)

Можно комбинировать. Если ничего кроме пути не указано — **спроси пользователя** что именно ревьюим (карточка, PR, или просто текущий diff на ветке).

Примеры:
```
/ai-hub:code-review /path/to/your-service --card 12345
/ai-hub:code-review /path/to/your-service --pr https://github.com/your-org/your-service/pull/42
/ai-hub:code-review /path/to/your-service --desc "Added /languages page with language overview"
/ai-hub:code-review /path/to/your-service
```

## Workflow

### Фаза 0: Сбор контекста

#### 0a: Валидация репозитория

1. Распарси `$ARGUMENTS` → `REPO_PATH`, `BASE_BRANCH`, `CARD_ID`, `PR_URL`, `DESCRIPTION`
2. Проверь что `REPO_PATH` существует, содержит `.sln` или `.csproj`
3. Проверь что `BASE_BRANCH` существует: `git -C $REPO_PATH rev-parse --verify $BASE_BRANCH`
4. Определи текущую ветку: `git -C $REPO_PATH branch --show-current`
5. Проверь что есть изменения: `git -C $REPO_PATH diff $BASE_BRANCH...HEAD --name-only`
6. Если нет изменений — сообщи и остановись

#### 0b: Контекст задачи → `TASK_CONTEXT`

Собери описание того, **что именно** проверяем. Это критически важно — AI-агенты будут фокусироваться на этом.

**Если передан `--card <id>`:**
```bash
./integrations/kaiten/scripts/kaiten-cards.sh get <id>
```
Извлеки title, description, чек-листы. Сформируй `TASK_CONTEXT`.

**Если передан `--pr <url>`:**
```bash
gh pr view <number> --repo <owner/repo> --json title,body
```
Извлеки title и body. Сформируй `TASK_CONTEXT`.

**Если передан `--desc`:**
Используй текст как `TASK_CONTEXT`.

**Если ничего не передано:**
Попробуй извлечь контекст автоматически:
1. Посмотри коммит-сообщения: `git -C $REPO_PATH log $BASE_BRANCH..HEAD --oneline --no-merges`
2. Если в сообщениях есть Kaiten card ID (числа после `#` или в URL) — подтяни карточку
3. Если есть PR для текущей ветки: `gh pr list --repo <repo> --head <branch> --json number,title,body`
4. Если ничего не нашёл — **спроси пользователя**: "Что именно ревьюим? Опиши кратко суть изменений, или дай Kaiten card ID / PR URL"

Результат:
```
TASK_CONTEXT = "<что именно разрабатывается / проверяется — 2-5 предложений>"
```

#### 0c: Scope изменений → `CHANGED_FILES`, `DIFF_SUMMARY`

```bash
# Список изменённых файлов
git -C $REPO_PATH diff $BASE_BRANCH...HEAD --name-only --diff-filter=ACMR

# Статистика
git -C $REPO_PATH diff $BASE_BRANCH...HEAD --stat

# Краткий diff (для передачи агентам, лимит 3000 строк)
git -C $REPO_PATH diff $BASE_BRANCH...HEAD --diff-filter=ACMR -- '*.cs' '*.razor' | head -3000
```

Сохрани в переменные. Выведи пользователю краткий summary:

```
📋 Review scope:
   Task: <TASK_CONTEXT, первые 100 символов>
   Branch: <current> vs <base>
   Changed: <N> files (<M> .cs, <K> .razor)
   Lines: +<added> / -<removed>
```

#### 0d: State-файл (resume support)

Загрузи или создай `$REPO_PATH/$STATE_FILE`:
```json
{
  "base_branch": "main",
  "head_commit": "<git rev-parse HEAD>",
  "task_context": "<TASK_CONTEXT>",
  "stages": {
    "build": null,
    "security": null,
    "performance": null,
    "architecture": null,
    "correctness": null,
    "ui-blazor": null
  },
  "current_stage": "build",
  "run_count": 0,
  "warnings": []
}
```

**Проверка актуальности:** Если `head_commit` не совпадает с текущим HEAD — сбросить все стадии (код изменился после фикса). Если совпадает — продолжить с `current_stage`.

`run_count += 1`

#### 0e: Baseline (мьют pre-existing issues)

Проверь наличие `$REPO_PATH/$BASELINE_FILE`. Это JSON-файл, куда пользователь может положить findings, которые он хочет замьютить (pre-existing issues, не связанные с текущей доработкой):

```json
{
  "muted": [
    {"rule": "SEC005", "file": "src/Legacy/ProcessRunner.cs", "reason": "Pre-existing, tracked in #12345"},
    {"rule": "PERF-*", "file": "src/Admin/*", "reason": "Admin endpoints, low traffic"},
    {"pattern": "warning CS0618", "reason": "Obsolete API usage planned for Q3 cleanup"}
  ]
}
```

Матчинг: `rule` — точный или wildcard (`SEC*`), `file` — glob, `pattern` — substring в тексте finding.

Если baseline-файла нет — это нормально, все findings активны.

### Фаза 1: Pipeline (fail-fast)

Стадии выполняются **строго последовательно**. При первом FAIL — стоп.

**КРИТИЧЕСКИ ВАЖНО**: Все стадии (и скрипты, и AI-агенты) проверяют **ТОЛЬКО diff** — изменения относительно `$BASE_BRANCH`. Не весь проект.

---

#### Stage 0: Build & Static Analyzers (shell script)

**Если `stages.build == "PASS"` → пропустить.**

Запусти:
```bash
bash integrations/code-review/scripts/stage0-build.sh "$REPO_PATH" "$BASE_BRANCH" 2>&1
```

- Exit 0 → `stages.build = "PASS"`, продолжить
- Exit 1 → парси JSON-line findings, отфильтруй замьюченные через baseline
  - Если после фильтрации остались BLOCK → `stages.build = "FAIL"`, **СТОП**
  - Если только WARNING → `stages.build = "PASS"`, сохрани warnings, продолжить
  - Если все замьючены → `stages.build = "PASS"`, продолжить

---

#### Stage 1: Security Patterns (shell script)

**Если `stages.security == "PASS"` → пропустить.**

Запусти:
```bash
bash integrations/code-review/scripts/stage1-security.sh "$REPO_PATH" "$BASE_BRANCH" 2>&1
```

Обработка аналогична Stage 0 (парси → фильтруй baseline → BLOCK = FAIL).

---

#### Stage 2: Performance Review (AI agent)

**Если `stages.performance == "PASS"` → пропустить.**

1. Собери контекст:
```bash
bash integrations/code-review/scripts/collect-diff-context.sh "$REPO_PATH" "$BASE_BRANCH" 2>&1
```

2. Прочитай промпт агента: `integrations/code-review/agents/review-performance.md`

3. Запусти агента через **Agent tool** (`subagent_type: "general-purpose"`, `model: "sonnet"`):

```
<Полный текст промпта из review-performance.md>

## TASK_CONTEXT (что разрабатывается)
<TASK_CONTEXT>

## DIFF_CONTEXT (что изменилось)
<вывод collect-diff-context.sh>

## Задача
Проведи performance review ТОЛЬКО ИЗМЕНЁННОГО кода в репозитории.
Репозиторий доступен для чтения по пути: $REPO_PATH
Сравнение с веткой: $BASE_BRANCH

ВАЖНО:
- Проверяй ТОЛЬКО код из diff. Не ревьюй pre-existing код, который не менялся в этом PR.
- Если видишь проблему в старом коде, которую изменения УСУГУБЛЯЮТ — это валидный finding.
- Если старый код имеет проблему, но изменения её не затрагивают — это НЕ finding.
- Используй TASK_CONTEXT чтобы понять намерение разработчика и оценить критичность.
```

4. Парси ответ агента:
   - Если вердикт `PASS` → `stages.performance = "PASS"`, продолжить
   - Если вердикт `FAIL` → `stages.performance = "FAIL"`, `current_stage = "performance"`, **СТОП** → отчёт

---

#### Stage 3: Architecture Review (AI agent)

**Если `stages.architecture == "PASS"` → пропустить.**

Аналогично Stage 2, но с промптом из `review-architecture.md`.

Запусти агента с `model: "sonnet"`. Передай `TASK_CONTEXT` и `DIFF_CONTEXT`.

Добавь инструкцию:
```
ВАЖНО: Проверяй архитектуру ТОЛЬКО изменённого/добавленного кода.
Используй TASK_CONTEXT чтобы понять, какую задачу решает разработчик.
```

Парси вердикт → обнови state → при FAIL **СТОП**.

---

#### Stage 4: Correctness Review (AI agent)

**Если `stages.correctness == "PASS"` → пропустить.**

Аналогично Stage 2, но с промптом из `review-correctness.md`.

Запусти агента с `model: "sonnet"`. Передай `TASK_CONTEXT` и `DIFF_CONTEXT`.

Добавь инструкцию:
```
ВАЖНО: Проверяй корректность ТОЛЬКО нового/изменённого кода.
Если изменение вводит новое вычисляемое свойство — проверь его на edge cases.
Если изменение трогает существующую логику — проверь, не сломана ли она.
```

Парси вердикт → обнови state → при FAIL **СТОП**.

---

#### Stage 5: UI/Blazor Review (AI agent)

**Если `stages["ui-blazor"] == "PASS"` → пропустить.**

1. Проверь есть ли `.razor` или `.css` файлы в diff:
```bash
git -C $REPO_PATH diff $BASE_BRANCH...HEAD --name-only | grep -E '\.(razor|css)$'
```

2. Если нет → `stages["ui-blazor"] = "PASS"` (skip), продолжить
3. Если есть → запусти агента с промптом из `review-ui-blazor.md` + `TASK_CONTEXT` + `DIFF_CONTEXT`

Парси вердикт → обнови state → при FAIL **СТОП**.

---

### Фаза 2: Отчёт

#### Если pipeline остановился на FAIL:

```
🔴 Code Review — FAIL at Stage N: <stage_name>

📍 Repository: $REPO_PATH
🔀 Branch: <current branch> vs $BASE_BRANCH
📋 Task: <TASK_CONTEXT, кратко>
🔄 Run: #<run_count>

## ❌ <Stage Name> — FAIL

<Findings от стадии — ТОЛЬКО BLOCK, сгруппированные по файлу>

<Если есть warnings — показать отдельно после BLOCK>

## ✅ Passed stages
- Stage 0: Build ✅
- Stage 1: Security ✅
- ...

## ⏭️ Skipped stages (not yet checked)
- Stage N+1: ...

---
💡 Исправь найденные проблемы и запусти `/ai-hub:code-review $REPO_PATH` повторно.
   Pipeline продолжит с Stage N (пройденные стадии будут пропущены).

💡 Если finding не относится к твоей доработке — добавь в $REPO_PATH/.code-review-baseline.json:
   {"muted": [{"rule": "<rule_id>", "file": "<path>", "reason": "Pre-existing, not related to this PR"}]}
```

#### Если ВСЕ стадии PASS:

```
✅ Code Review — ALL PASS

📍 Repository: $REPO_PATH
🔀 Branch: <current branch> vs $BASE_BRANCH
📋 Task: <TASK_CONTEXT, кратко>
🔄 Runs total: <run_count>

| Stage | Status |
|-------|--------|
| 0. Build & Analyzers | ✅ PASS |
| 1. Security Patterns | ✅ PASS |
| 2. Performance | ✅ PASS |
| 3. Architecture | ✅ PASS |
| 4. Correctness | ✅ PASS |
| 5. UI/Blazor | ✅ PASS (или ⏭️ skipped) |

<Warnings из всех стадий, если были — показать как non-blocking рекомендации>

---
🎉 Код готов к merge.
```

### Фаза 3: Сохранение state

После каждой стадии (PASS или FAIL) — обнови `$STATE_FILE` через Write tool. Это критически важно для fail-fast + resume.

## Важные правила

- **Оркестратор НЕ модифицирует код** — только читает, запускает скрипты и агентов, пишет state/baseline файлы
- **Фокус на diff** — и скрипты, и AI-агенты проверяют ТОЛЬКО изменения. Pre-existing issues → baseline
- **TASK_CONTEXT обязателен** — без понимания задачи ревью бессмысленно. Если контекст не извлечён автоматически — спроси пользователя
- **AI-агенты получают diff + контекст задачи** — они знают И что изменилось, И зачем
- **Каждый AI-агент** запускается в чистом контексте (Agent tool) — никакой предвзятости
- **При FAIL — показать ТОЛЬКО проблемы текущей стадии**, не нагружая пользователя
- **State-файл** позволяет продолжить pipeline после фикса — не перепроверять пройденные стадии
- **Если HEAD изменился** (пользователь сделал коммит с фиксом) — state сбрасывается, pipeline рестартует с нуля
- **Baseline-файл** позволяет замьютить pre-existing issues — не блокировать текущую доработку
- **Warnings не блокируют** — только BLOCK findings останавливают pipeline
- **`$STATE_FILE` и `$BASELINE_FILE`** должны быть в `.gitignore` — это рабочие артефакты
- **Обезличенность** — при ревью кода/документации в самом `ai-hub` помечай конкретные названия компаний, внутренние ссылки/домены, реальные логины и ID как замечание (заменить на плейсхолдер). Правила — [`REVIEW_GUIDELINES.md`](../../../REVIEW_GUIDELINES.md)
