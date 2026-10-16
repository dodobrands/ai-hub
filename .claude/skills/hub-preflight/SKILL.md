---
name: hub-preflight
description: >
  Use before every commit, push or PR in the ai-hub repo, and when asked «проверь ветку»,
  «готово к PR?», «прогони префлайт», «preflight». Механически проверяет ветку на то, что
  ревью раньше находило руками: рассинхрон plugin.json и marketplace.json, забытый bump
  версии, битые симлинки команд, утечки конкретики (хосты, ID, email), bash 4+ и zsh-glob,
  тихие отказы curl, фиксированные пути в /tmp, фичи без инструкции агенту, тесты.
---

# hub-preflight: проверка ветки перед PR

Цель: PR уходит на ревью без находок, которые ловятся скриптом. Каждый раунд ревью
стоит дня; механика должна отсекаться здесь, за минуту.

## Запуск

Из корня клона ai-hub:

```bash
git fetch origin main --quiet
bash .claude/skills/hub-preflight/scripts/preflight.sh            # полный прогон
bash .claude/skills/hub-preflight/scripts/preflight.sh --no-tests # быстро, без bats
bash .claude/skills/hub-preflight/scripts/preflight.sh --base origin/<branch>  # PR поверх чужой ветки
```

Exit 0, если нет FAIL. WARN не валит прогон, но каждый WARN разбери: либо поправь,
либо объясни в описании PR, почему так и надо.

## Что проверяется

| Блок | FAIL | WARN |
| --- | --- | --- |
| Манифесты | ветка подняла версию только в одном из `plugin.json` / `marketplace.json` | рассинхрон, унаследованный с базы; плагина нет в каталоге; мёртвый путь в `.claude/settings.json` |
| Bump версии | менялись `commands/ skills/ agents/ scripts/` интеграции, а версия та же (и в корневом `plugin.json`) | |
| Симлинки | битый симлинк в `.claude/` или `integrations/` | новая команда без симлинка в `.claude/commands/ai-hub/` |
| Обезличивание | в добавленных строках реальный хост трекера/мессенджера/вики, ID доски или карточки, email, слово из `.deident-denylist` | нет `.deident-denylist` |
| Shell | shellcheck, bash 4+ (`mapfile`, `declare -A`, `${x,,}`, `&>>`) | glob в резолвере `.md` (в zsh обрывает подстановку) |
| Эвристики ревью | | `curl` без `-S` или с `2>/dev/null`, `/tmp/<фикс. имя>`, `local x=$(...)`, `ensure_ascii=False`, скрипты менялись, а `commands/`/`skills/` нет |
| Тесты | упал bats интеграции или `tests/*.sh` | bats не установлен; скрипты менялись без новых тестов |

## Локальный стоп-лист обезличивания

Репозиторий публичный, поэтому имена компаний и внутренние домены в нём не перечислены.
Создай в корне файл `.deident-denylist` (он в `.gitignore`), по одному regex на строку:

```text
# имена организаций и брендов, внутренние домены, логины коллег
my-company
internal\.example-corp\.io
```

## Порядок работы

1. Прогони скрипт. Пока есть FAIL, PR не открывай.
2. Чинить версии: подними patch для правок и minor для нового скилла или команды,
   **одинаково** в `integrations/<name>/.claude-plugin/plugin.json` и в записи плагина в
   `.claude-plugin/marketplace.json`, плюс корневой `.claude-plugin/plugin.json`.
3. Чинить shell и тесты: правила в скилле `hub-script-dev`.
4. После зелёного прогона пройди скилл `hub-self-review`: он ловит то, что механикой не
   поймать (обещания в README против кода, тесты, которые ничего не доказывают).
5. В описание PR вставь итоговую строку прогона (`Итог: FAIL 0, WARN N`) и разбор WARN.

## Ограничения

- Эвристики грубые: ложные срабатывания нормальны, отключать проверку ради зелёного
  прогона нельзя. Если правило систематически врёт, поправь скрипт в отдельном PR.
- shellcheck и bats ставятся отдельно: `brew install shellcheck bats-core`. Без них скрипт
  честно пишет WARN, а не PASS.
- Скрипт сам совместим с bash 3.2: любые правки в нём проверяй под `/bin/bash` на маке.
