#!/usr/bin/env bash
# CI-гейт резолва пути к скриптам интеграций по всем сценариям потребления хаба.
#
# Зачем: командные .md и скиллы указывают агенту, каким путём звать скрипты.
# Жёсткий относительный путь работает только из корня репо ai-hub; голый
# ${CLAUDE_PLUGIN_ROOT} — только в плагин-контексте. Этот тест проверяет, что
# резолвер из реальных .md находит скрипты во всех сценариях:
#   standalone-клон, subtree-overlay (cwd ≠ корень ai-hub), marketplace-install,
#   а для скиллов (активируются из произвольного cwd) — ещё symlink-в-~/.claude
#   и Copilot _direct.
#
# Покрытие: buildin, kaiten, time (команды + skill).
# Любой провал REQUIRED → exit≠0 → CI красный.
set -u

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0
SUM="${GITHUB_STEP_SUMMARY:-/dev/null}"

mk(){ mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; }

# integration → каноничный скрипт-маркер (его наличие в резолвнутом каталоге = успех)
declare -A MARK=( [buildin]=buildin-pages.sh [kaiten]=kaiten-cards.sh [time]=time-messages.sh )

# ---- извлечение резолвера из .md -------------------------------------------
extract_cmd_resolver(){ # $1=md $2=integration
  sed -n "/resolve-$2-dir:start/,/resolve-$2-dir:end/p" "$1"
}
extract_skill_resolver(){ # $1=md  (резолвер skill-time: _t=… → TIME_MESSAGES=…)
  sed -n '/^_t=""/,/^TIME_MESSAGES=/p' "$1"
}

# ---- прогон одного сценария -------------------------------------------------
run_cmd(){ # snippet cwd root → каталог скриптов
  ( cd "$2" && CLAUDE_PLUGIN_ROOT="$3" bash -c "$1"$'\n''printf %s "${BUILDIN_SCRIPTS:-}${KAITEN_SCRIPTS:-}${TIME_SCRIPTS:-}"' )
}
run_skill(){ # snippet cwd root home → полный путь скрипта
  ( cd "$2" && HOME="$4" CLAUDE_PLUGIN_ROOT="$3" bash -c "set -u; $1"$'\n''printf %s "$TIME_MESSAGES"' )
}

pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

# ============================================================================
# 1) КОМАНДЫ: резолвер из каждого командного .md по cwd-сценариям
# ============================================================================
echo "== Команды (standalone / overlay / marketplace) =="
{ echo "### Резолв пути — команды"; echo; echo "| Интеграция | Файл | Сценарий | Итог |"; echo "|---|---|---|---|"; } >> "$SUM"

for INT in buildin kaiten time; do
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

# ============================================================================
# 2) SKILL time-chat: резолвер активируется из ПРОИЗВОЛЬНОГО cwd
# ============================================================================
echo
echo "== Skill time-chat (произвольный cwd: git / symlink / copilot / plugin) =="
{ echo; echo "### Резолв пути — skill time-chat"; echo; echo "| Сценарий | Итог |"; echo "|---|---|"; } >> "$SUM"

SKILL_MD="integrations/time/skills/time-chat/SKILL.md"
if [ -f "$SKILL_MD" ] && grep -q '^_t=""' "$SKILL_MD"; then
  SNIP="$(extract_skill_resolver "$SKILL_MD")"
  M=time-messages.sh
  S_ST="$TMP/skill/standalone"; mk "$S_ST/integrations/time/scripts/$M"
  ( cd "$S_ST" && git init -q && git -c user.email=t@t -c user.name=t add -A && git -c user.email=t@t -c user.name=t commit -qm x )
  S_OV="$TMP/skill/overlay/integrations/team-overlay/integrations/time"; mk "$S_OV/scripts/$M"; mkdir -p "$S_OV/skills/time-chat"
  S_CA="$TMP/skill/cache/time/9.9.9"; mk "$S_CA/scripts/$M"
  S_UN="$TMP/skill/unrelated"; mkdir -p "$S_UN"
  H_CLEAN="$TMP/skill/home-clean"; mkdir -p "$H_CLEAN/.claude/skills"
  H_SYM="$TMP/skill/home-sym"; mkdir -p "$H_SYM/.claude/skills"; ln -s "$S_OV/skills/time-chat" "$H_SYM/.claude/skills/any-name"
  H_COP="$TMP/skill/home-copilot"; mk "$H_COP/.copilot/installed-plugins/_direct/time/scripts/$M"

  # name|cwd|root|home
  S_SCN=(
    "standalone (git rev-parse)  |$S_ST|$|$H_CLEAN"
    "standalone, /plugin         |$S_ST|$S_ST/integrations/time|$H_CLEAN"
    "overlay-subtree, symlink    |$S_UN|$|$H_SYM"
    "overlay-subtree, /plugin    |$S_OV|$S_OV|$H_CLEAN"
    "marketplace (кеш плагина)   |$S_UN|$S_CA|$H_CLEAN"
    "Copilot _direct             |$S_UN|$|$H_COP"
  )
  for row in "${S_SCN[@]}"; do
    IFS='|' read -r name cwd root home <<< "$row"
    name="$(echo "$name" | sed 's/ *$//')"; [ "$root" = '$' ] && root=""
    got="$(run_skill "$SNIP" "$cwd" "$root" "$home")"
    if [ -f "$got" ]; then pass "skill — $name"; r=PASS; else fail "skill — $name → [$got]"; r=FAIL; fi
    echo "| $name | $r |" >> "$SUM"
  done
else
  fail "skill SKILL.md не найден или без резолвера (_t)"
fi

echo
if [ $FAILS -eq 0 ]; then
  echo "ИТОГ: PASS — все .md резолвят путь во всех сценариях"
  { echo; echo "**ИТОГ: PASS** — все сценарии зелёные."; } >> "$SUM"
else
  echo "ИТОГ: FAIL — провалов REQUIRED: $FAILS"
  { echo; echo "**ИТОГ: FAIL** — провалов: $FAILS."; } >> "$SUM"
fi
exit $FAILS
