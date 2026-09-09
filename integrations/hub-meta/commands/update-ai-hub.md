---
name: update-ai-hub
description: "Обновить (подтянуть свежую версию) публичных скиллов dodobrands/ai-hub в текущем overlay-репо — git subtree pull из upstream. Вызывай, когда пользователь просит: 'обнови ai-hub инструменты', 'обнови ai-hub', 'подтяни свежий ai-hub', 'update ai-hub subtree', 'обнови generic скиллы'."
argument-hint: "[prefix]"
allowed-tools: ["Bash", "Read"]
---

# Update dodobrands/ai-hub subtree

Скилл подтягивает свежую версию публичного `dodobrands/ai-hub` в overlay-репо пользователя через `git subtree pull`.

## Когда запускается

Пользователь говорит что-то вроде:
- «обнови ai-hub инструменты»
- «обнови ai-hub»
- «подтяни свежий ai-hub»
- «обнови generic скиллы»
- «update ai-hub subtree»
- `/ai-hub:update-ai-hub [prefix]`

## Пошаговый сценарий

### Шаг 1 — определить prefix (где живёт subtree)

По умолчанию: `integrations/sagos95-ai-hub`. Если `$ARGUMENTS` не пуст — использовать как prefix.

Проверь что папка существует:
```bash
PREFIX="${ARGUMENTS:-integrations/sagos95-ai-hub}"
[[ -d "$PREFIX" ]] || { echo "Prefix '$PREFIX' not found. Это overlay-репо с установленным subtree?"; exit 1; }
```

Если prefix не найден — подскажи пользователю:
> Похоже, ai-hub ещё не подключён как subtree. Если хочешь установить — запусти:
> `curl -sL https://raw.githubusercontent.com/dodobrands/ai-hub/main/scripts/install-as-subtree.sh | bash`

### Шаг 2 — предпочти Makefile-таргет, если он есть

Многие overlay-репо держат шорткат в Makefile:
```bash
if [[ -f Makefile ]] && grep -q '^update-ai-hub:' Makefile; then
  make update-ai-hub
  exit $?
fi
```

Если Makefile-таргет есть — используй его и выйди (он уже знает правильный prefix и параметры).

### Шаг 3 — fallback: использовать упакованный скрипт

В dodobrands/ai-hub есть готовый скрипт. Если subtree уже установлен — скрипт лежит внутри:

```bash
SCRIPT="$PREFIX/scripts/update-from-ai-hub.sh"
if [[ -x "$SCRIPT" ]]; then
  "$SCRIPT" "$PREFIX"
  exit $?
fi
```

### Шаг 4 — fallback: прямой git subtree pull

```bash
# Проверь, что remote ai-hub настроен
git remote get-url ai-hub &>/dev/null || \
  git remote add ai-hub https://github.com/dodobrands/ai-hub.git

# Проверь что working tree чистый
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  echo "Working tree грязный. Закоммить или застэшь изменения перед обновлением."
  exit 1
fi

git subtree pull --prefix="$PREFIX" ai-hub main --squash
```

### Шаг 5 — показать что изменилось

После успешного pull:
```bash
echo "=== Что приехало из upstream ==="
git log -1 --stat
```

Кратко суммируй пользователю:
- сколько файлов изменилось
- если видны новые команды в `integrations/*/commands/` — перечисли их
- если обновился корневой plugin.json — покажи новую версию

### Шаг 6 — напомнить про симлинки

Если видны новые команды в свежем subtree, но нет симлинка в `.claude/commands/*/`:
> В subtree появились новые команды: `<list>`. Если хочешь их вызывать как `/ai-hub:<name>` — нужно добавить симлинки через `/ai-hub:create-command` или вручную.

## Обработка ошибок

- **Working tree грязный** → не запускай pull, попроси пользователя закоммитить/застэшить
- **Prefix не существует** → подскажи install-as-subtree.sh
- **Конфликты при merge (редко, т.к. subtree read-only)** → остановись, покажи `git status`, предложи `git merge --abort` или ручное разрешение
- **Нет remote `ai-hub`** → добавь автоматически, но сообщи пользователю

## Не делай

- Не пушь результат автоматически — пользователь сам решает, когда пушить overlay
- Не трогай ничего в `$PREFIX/` вручную — файлы там только обновляются через pull
