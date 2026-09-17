#!/usr/bin/env bash
# CI-гейт резолва пути к скриптам интеграций по всем сценариям потребления хаба.
#
# Зачем: командные .md и скиллы указывают агенту, каким путём звать скрипты.
# Жёсткий относительный путь работает только из корня репо ai-hub; голый
# ${CLAUDE_PLUGIN_ROOT} — только в плагин-контексте. Этот тест проверяет, что
# резолвер из реальных .md находит скрипты во всех сценариях:
#   standalone-клон, subtree-overlay (cwd ≠ корень ai-hub), marketplace-install.
#
# Покрытие: buildin, kaiten (команды).
# Любой провал REQUIRED → exit≠0 → CI красный.
set -u

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0
SUM="${GITHUB_STEP_SUMMARY:-/dev/null}"

mk(){ mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; }

# integration → каноничный скрипт-маркер (его наличие в резолвнутом каталоге = успех)
declare -A MARK=( [buildin]=buildin-pages.sh [kaiten]=kaiten-cards.sh )

# ---- извлечение резолвера из .md -------------------------------------------
extract_cmd_resolver(){ # $1=md $2=integration
  sed -n "/resolve-$2-dir:start/,/resolve-$2-dir:end/p" "$1"
}
# ---- прогон одного сценария -------------------------------------------------
run_cmd(){ # snippet cwd root → каталог скриптов
  ( cd "$2" && CLAUDE_PLUGIN_ROOT="$3" bash -c "$1"$'\n''printf %s "${BUILDIN_SCRIPTS:-}${KAITEN_SCRIPTS:-}"' )
}

pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

# ============================================================================
# 1) КОМАНДЫ: резолвер из каждого командного .md по cwd-сценариям
# ============================================================================
echo "== Команды (standalone / overlay / marketplace) =="
{ echo "### Резолв пути — команды"; echo; echo "| Интеграция | Файл | Сценарий | Итог |"; echo "|---|---|---|---|"; } >> "$SUM"

for INT in buildin kaiten; do
  M="${MARK[$INT]}"
  ST="$TMP/$INT/standalone"
  OV="$TMP/$INT/overlay"
  CA="$TMP/$INT/cache/$INT/9.9.9"
  UN="$TMP/$INT/unrelated/proj"
  mk "$ST/integrations/$INT/scripts/$M"
  mk "$OV/integrations/team-overlay/integrations/$INT/scripts/$M"
  mk "$CA/scripts/$M"
  mkdir -p "$UN"

  # name|cwd|root  (все REQUIRED)
  SCN=(
    "standalone (var нет)        |$ST|"
    "standalone, /plugin         |$ST|$ST/integrations/$INT"
    "overlay-subtree (var нет)   |$OV|"
    "overlay-subtree, /plugin    |$OV|$OV/integrations/team-overlay/integrations/$INT"
    "marketplace (кеш плагина)   |$UN|$CA"
  )

  for md in integrations/$INT/commands/*.md; do
    [ -f "$md" ] || continue
    grep -q "resolve-$INT-dir:start" "$md" || continue
    snip="$(extract_cmd_resolver "$md" "$INT")"
    base="$(basename "$md")"
    for row in "${SCN[@]}"; do
      IFS='|' read -r name cwd root <<< "$row"; name="$(echo "$name" | sed 's/ *$//')"
      dir="$(run_cmd "$snip" "$cwd" "$root")"
      if ( cd "$cwd" && [ -f "$dir/$M" ] ); then
        pass "$INT/$base — $name"; r=PASS
      else
        fail "$INT/$base — $name → [$dir]"; r=FAIL
      fi
      echo "| $INT | $base | $name | $r |" >> "$SUM"
    done
  done
done

echo
if [ $FAILS -eq 0 ]; then
  echo "ИТОГ: PASS — все .md резолвят путь во всех сценариях"
  { echo; echo "**ИТОГ: PASS** — все сценарии зелёные."; } >> "$SUM"
else
  echo "ИТОГ: FAIL — провалов REQUIRED: $FAILS"
  { echo; echo "**ИТОГ: FAIL** — провалов: $FAILS."; } >> "$SUM"
fi
exit $FAILS
