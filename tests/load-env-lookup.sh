#!/usr/bin/env bash
# CI-гейт: скрипты интеграций находят hub-meta/scripts/load-env.sh во всех раскладках
# установки хаба, а опубликованный плагин с такими скриптами объявляет зависимость от hub-meta.
#
# Зачем: блок поиска load-env.sh скопирован в каждый скрипт — подключить сам себя загрузчик
# не может. bats-тесты интеграций кладут hub-meta рядом и проверяют только первую ветку
# поиска. Раскладку кэша плагинов Claude Code (<cache>/<marketplace>/<plugin>/<version>/) и
# фолбэк через $CLAUDE_PLUGIN_ROOT не проверяло ничто, а без hub-meta плагин падал на
# первом же вызове скрипта — Claude Code не знал, что hub-meta нужен.
#
# Как: каждый скрипт с блоком копируется в синтетическую раскладку и запускается целиком.
# Вместо load-env.sh лежит стаб: он пишет, какая копия подключилась, и делает exit 0 —
# скрипт останавливается ровно в момент подключения, до сети и токенов. На этом держится
# безопасность прогона: до блока скрипты только вычисляют пути. Если поиск сломан, скрипт
# пойдёт дальше — поэтому stdin закрыт, а curl/open/az/osascript подменены отказом.
#
# Без hub-meta скрипт обязан упасть с понятной причиной, а не работать дальше без .env.
# Исключения перечислены в soft_for явно: такой скрипт без load-env.sh продолжает работу
# намеренно, и в сценарии «hub-meta нет» его не запускаем — дальше он сделал бы настоящую
# работу. Список явный, чтобы скрипт, потерявший отказ, не стал мягким молча.
#
# Любой провал → exit≠0 → CI красный.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0
pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

# Версии подобраны так, что старшая (1.10.0) не первая и не последняя при обычной
# сортировке строк: пройдёт только сравнение версий (sort -V).
HUB_META_VERSIONS="0.9.0 1.10.0 1.9.0"
HUB_META_NEWEST="1.10.0"

# Блок внутри функции сам не выполнится: такой скрипт — библиотека, её надо подключить и
# вызвать функцию, которая ищет load-env.sh.
entry_for(){
  case "$1" in
    */ktalk-auth.sh) echo ktalk_init_auth ;;
  esac
}

soft_for(){
  case "$1" in
    */buildin-shadow.sh) echo "shadow-индекс читается локально и без .env" ;;
    */time-messages.sh)  echo "обёртка над time.sh, отказ даёт сам time.sh" ;;
    */ktalk-auth.sh)     echo "токены можно передать через окружение" ;;
  esac
}

mkdir -p "$TMP/bin"
for c in curl open xdg-open osascript az; do
  printf '#!/bin/sh\necho "load-env-lookup: %s заблокирован в гейте" >&2\nexit 99\n' "$c" > "$TMP/bin/$c"
  chmod +x "$TMP/bin/$c"
done

stub(){ # $1=куда положить load-env.sh $2=метка копии
  mkdir -p "$(dirname "$1")"
  printf 'printf %%s "%s" > "$LOOKUP_MARK"\nexit 0\n' "$2" > "$1"
}

run_script(){ # $1=скопированный скрипт $2=метка-файл $3=CLAUDE_PLUGIN_ROOT (или пусто) → код выхода
  local script="$1" mark="$2" root="$3" entry
  entry="$(entry_for "$script")"
  (
    unset CLAUDE_PLUGIN_ROOT KTALK_TOKEN KTALK_SESSION_TOKEN
    [ -n "$root" ] && export CLAUDE_PLUGIN_ROOT="$root"
    export LOOKUP_MARK="$mark" PATH="$TMP/bin:$PATH"
    if [ -n "$entry" ]; then
      bash -c 'source "$1"; "$2"' _ "$script" "$entry"
    else
      bash "$script"
    fi
  ) </dev/null >"$TMP/out.txt" 2>&1
}

SCRIPTS=$(grep -rl --include='*.sh' '_hub_load_env_sh=' integrations | grep -v '/tests/' | grep -v '^integrations/hub-meta/' | sort)
if [ -z "$SCRIPTS" ]; then
  echo "Не найдено ни одного скрипта с блоком поиска load-env.sh — гейт нечего проверять" >&2
  exit 1
fi

echo "== Поиск load-env.sh по раскладкам =="
n=0
for rel in $SCRIPTS; do
  n=$((n+1))
  plugin="${rel#integrations/}"; plugin="${plugin%%/*}"
  inner="${rel#integrations/$plugin/}"
  case_dir="$TMP/case$n"
  mark="$case_dir/mark"
  soft="$(soft_for "$rel")"

  # 1. Исходники: standalone-клон, subtree в overlay-репо, marketplace из локальной папки.
  dst="$case_dir/src/integrations/$plugin/$inner"
  mkdir -p "$(dirname "$dst")"; cp "$rel" "$dst"
  stub "$case_dir/src/integrations/hub-meta/scripts/load-env.sh" source
  rm -f "$mark"; run_script "$dst" "$mark" ""
  if [ "$(cat "$mark" 2>/dev/null)" = source ]; then pass "$rel — исходники"
  else fail "$rel — исходники: load-env.sh не подключён ($(head -c 200 "$TMP/out.txt"))"; fi

  # 2. Кэш плагинов: соседние версии hub-meta, берётся старшая.
  cache="$case_dir/cache/marketplace"
  dst="$cache/$plugin/1.0.0/$inner"
  mkdir -p "$(dirname "$dst")"; cp "$rel" "$dst"
  for v in $HUB_META_VERSIONS; do stub "$cache/hub-meta/$v/scripts/load-env.sh" "$v"; done
  rm -f "$mark"; run_script "$dst" "$mark" ""
  got="$(cat "$mark" 2>/dev/null)"
  if [ "$got" = "$HUB_META_NEWEST" ]; then pass "$rel — кэш плагинов"
  else fail "$rel — кэш плагинов: подключён «${got:-ничего}», ждали hub-meta $HUB_META_NEWEST ($(head -c 200 "$TMP/out.txt"))"; fi

  # 3. Скрипт вне кэша, hub-meta находится только через $CLAUDE_PLUGIN_ROOT.
  dst="$case_dir/elsewhere/a/b/$inner"
  mkdir -p "$(dirname "$dst")"; cp "$rel" "$dst"
  rm -f "$mark"; run_script "$dst" "$mark" "$cache/$plugin/1.0.0"
  got="$(cat "$mark" 2>/dev/null)"
  if [ "$got" = "$HUB_META_NEWEST" ]; then pass "$rel — \$CLAUDE_PLUGIN_ROOT"
  else fail "$rel — \$CLAUDE_PLUGIN_ROOT: подключён «${got:-ничего}», ждали hub-meta $HUB_META_NEWEST ($(head -c 200 "$TMP/out.txt"))"; fi

  # 4. hub-meta нет: скрипт падает с понятной причиной, а не идёт дальше без .env.
  if [ -n "$soft" ]; then
    printf '  SKIP  %s — без hub-meta: мягкий (%s)\n' "$rel" "$soft"
  else
    dst="$case_dir/bare/integrations/$plugin/$inner"
    mkdir -p "$(dirname "$dst")"; cp "$rel" "$dst"
    rm -f "$mark"; run_script "$dst" "$mark" ""; code=$?
    if [ "$code" -ne 0 ] && grep -q 'load-env.sh not found' "$TMP/out.txt"; then pass "$rel — без hub-meta: отказ"
    else fail "$rel — без hub-meta: ждали отказ «load-env.sh not found», код $code ($(head -c 200 "$TMP/out.txt"))"; fi
  fi
done

echo
echo "== Опубликованный плагин со скриптами на load-env.sh объявляет зависимость от hub-meta =="
# Без объявления Claude Code ставит плагин без hub-meta, и скрипт падает на первом вызове.
# С dependencies он ставит hub-meta сам или отключает плагин с понятной ошибкой.
SCRIPTS="$SCRIPTS" python3 - <<'PY' || FAILS=$((FAILS+1))
import json
import os
import sys

scripts = os.environ["SCRIPTS"].split()
users = sorted({p.split("/")[1] for p in scripts})
catalog = json.load(open(".claude-plugin/marketplace.json"))
published = {e["source"].removeprefix("./").rstrip("/"): e["name"] for e in catalog["plugins"]
             if isinstance(e.get("source"), str)}

def declares_hub_meta(deps):
    for d in deps or []:
        name = d.get("name") if isinstance(d, dict) else d
        if isinstance(name, str) and name.split("@")[0] == "hub-meta":
            return True
    return False

failed = False
for plugin in users:
    src = f"integrations/{plugin}"
    if src not in published:
        print(f"  SKIP  {plugin} — не опубликован в marketplace.json")
        continue
    manifest = json.load(open(f"{src}/.claude-plugin/plugin.json"))
    if declares_hub_meta(manifest.get("dependencies")):
        print(f"  PASS  {plugin} — dependencies содержит hub-meta")
    else:
        print(f"  FAIL  {plugin} — скрипты ищут load-env.sh, а в {src}/.claude-plugin/plugin.json "
              f"нет \"dependencies\": [\"hub-meta\"]")
        failed = True
sys.exit(1 if failed else 0)
PY

echo
if [ "$FAILS" -gt 0 ]; then
  echo "Провалов: $FAILS"
  exit 1
fi
echo "Все проверки пройдены"
