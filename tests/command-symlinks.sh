#!/usr/bin/env bash
# CI-гейт симлинков slash-команд: relink-commands.sh / update-from-ai-hub.sh /
# install-as-subtree.sh раскладывают ссылки в .claude/commands/<namespace>/.
#
# Зачем: цель ссылки строится как "../../../$cmd_file" — жёсткие три уровня вверх
# верны только когда .claude/commands/<ns>/ — РЕАЛЬНЫЙ каталог в корне overlay.
# Если overlay держит каталог команд внутри сабтри и линкует его в корень
# (.claude/commands/<ns> → <prefix>/.claude/commands/<ns>), реальная глубина — 5,
# и все созданные ссылки битые. Второй случай — overlay переименовал команду
# (buildin-publish.md → publish-page.md): скрипт не видит алиас по basename и
# плодит дубль на тот же файл.
#
# Гейт гоняет relink-commands.sh на фикстурах-overlay и требует: ни одной битой
# ссылки, ни одного дубля, чужие файлы не тронуты, устаревшие ссылки — названы.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
RELINK="$REPO/scripts/relink-commands.sh"
PREFIX="integrations/team-overlay"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0
SUM="${GITHUB_STEP_SUMMARY:-/dev/null}"

pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
check(){ # $1=условие-результат(0/1) $2=имя $3=диагностика
  if [ "$1" -eq 0 ]; then pass "$2"; echo "| $2 | PASS |" >> "$SUM"
  else fail "$2 → $3"; echo "| $2 | FAIL |" >> "$SUM"; fi
}

# ---- фикстура overlay-репо ---------------------------------------------------
# layout=plain      → .claude/commands/ai-hub — реальный каталог (глубина 3)
# layout=symlinked  → .claude/commands/ai-hub — ссылка внутрь сабтри (глубина 5)
mk_overlay(){ # $1=root $2=layout
  local root="$1" layout="$2"
  mkdir -p "$root/$PREFIX/integrations/buildin/commands" \
           "$root/$PREFIX/integrations/kaiten/commands"
  printf '# publish\n' > "$root/$PREFIX/integrations/buildin/commands/publish-page.md"
  printf '# read\n'    > "$root/$PREFIX/integrations/buildin/commands/read-page.md"
  printf '# card\n'    > "$root/$PREFIX/integrations/kaiten/commands/kaiten-card.md"

  if [ "$layout" = symlinked ]; then
    mkdir -p "$root/$PREFIX/.claude/commands/ai-hub" "$root/.claude/commands"
    ( cd "$root/.claude/commands" && ln -s "../../$PREFIX/.claude/commands/ai-hub" ai-hub )
  else
    mkdir -p "$root/.claude/commands/ai-hub"
  fi
}

relink(){ # $1=root [+флаги] → stdout скрипта, cwd = корень overlay (как в доке)
  local root="$1"; shift
  ( cd "$root" && bash "$RELINK" "$PREFIX" ai-hub "$@" 2>&1 )
}

broken_links(){ # $1=root → имена битых ссылок в каталоге команд
  local d="$1/.claude/commands/ai-hub" f
  for f in "$d"/*.md; do
    [ -L "$f" ] || continue
    [ -e "$f" ] || printf '%s ' "${f##*/}"
  done
}

{ echo "### Симлинки slash-команд"; echo; echo "| Проверка | Итог |"; echo "|---|---|"; } >> "$SUM"

# ============================================================================
# 1) plain: реальный каталог команд в корне overlay — базовый сценарий
# ============================================================================
echo "== plain overlay (.claude/commands/ai-hub — реальный каталог) =="
R="$TMP/plain"; mk_overlay "$R" plain
OUT=$(relink "$R")
BROKEN=$(broken_links "$R")
[ -z "$BROKEN" ]; check $? "plain — нет битых ссылок" "битые: $BROKEN"
[ -e "$R/.claude/commands/ai-hub/kaiten-card.md" ]
check $? "plain — kaiten-card.md резолвится" "$OUT"

# ============================================================================
# 2) symlinked: каталог команд живёт в сабтри и залинкован в корень
#    (раскладка overlay-репо, у которого команды переименованы под свой namespace)
# ============================================================================
echo "== symlinked overlay (.claude/commands/ai-hub → <prefix>/.claude/...) =="
R="$TMP/symlinked"; mk_overlay "$R" symlinked
OUT=$(relink "$R")
BROKEN=$(broken_links "$R")
[ -z "$BROKEN" ]; check $? "symlinked — нет битых ссылок" "битые: $BROKEN"
[ -e "$R/.claude/commands/ai-hub/kaiten-card.md" ]
check $? "symlinked — kaiten-card.md резолвится" "$OUT"

# ============================================================================
# 3) переименованный алиас: ссылка на тот же файл под другим именем — не дублить
# ============================================================================
echo "== алиас под своим именем (buildin-publish.md → publish-page.md) =="
R="$TMP/alias"; mk_overlay "$R" symlinked
( cd "$R/$PREFIX/.claude/commands/ai-hub" \
  && ln -s ../../../integrations/buildin/commands/publish-page.md buildin-publish.md )
OUT=$(relink "$R")
[ -e "$R/.claude/commands/ai-hub/buildin-publish.md" ]
check $? "алиас — существующая ссылка осталась рабочей" "$OUT"
[ ! -e "$R/.claude/commands/ai-hub/publish-page.md" ] && [ ! -L "$R/.claude/commands/ai-hub/publish-page.md" ]
check $? "алиас — дубль publish-page.md не создан" "$OUT"

# ============================================================================
# 4) чужой обычный файл на месте команды — не перезаписывать
# ============================================================================
echo "== конфликт с обычным файлом =="
R="$TMP/conflict"; mk_overlay "$R" plain
printf 'своя команда\n' > "$R/.claude/commands/ai-hub/kaiten-card.md"
OUT=$(relink "$R")
[ "$(cat "$R/.claude/commands/ai-hub/kaiten-card.md")" = "своя команда" ]
check $? "конфликт — обычный файл не перезаписан" "$OUT"

# ============================================================================
# 5) устаревшая ссылка (интеграцию удалили из upstream) — назвать в выводе
# ============================================================================
echo "== устаревшая битая ссылка =="
R="$TMP/stale"; mk_overlay "$R" plain
( cd "$R/.claude/commands/ai-hub" \
  && ln -s ../../../"$PREFIX"/integrations/gone/commands/gone.md gone.md )
OUT=$(relink "$R")
printf '%s' "$OUT" | grep -q 'gone.md'
check $? "устаревшая — gone.md упомянут в отчёте" "$OUT"
[ -L "$R/.claude/commands/ai-hub/gone.md" ]
check $? "устаревшая — без --prune gone.md не удалён" "$OUT"

# ============================================================================
# 6) --prune: явный опт-ин на снос битых ссылок, живые не трогает
# ============================================================================
echo "== --prune =="
OUT=$(relink "$R" --prune)
[ ! -L "$R/.claude/commands/ai-hub/gone.md" ]
check $? "--prune — битая gone.md снесена" "$OUT"
[ -e "$R/.claude/commands/ai-hub/kaiten-card.md" ]
check $? "--prune — рабочая ссылка не тронута" "$OUT"

echo
if [ $FAILS -eq 0 ]; then
  echo "ИТОГ: PASS — симлинки команд раскладываются корректно во всех раскладках"
  { echo; echo "**ИТОГ: PASS**"; } >> "$SUM"
else
  echo "ИТОГ: FAIL — провалов: $FAILS"
  { echo; echo "**ИТОГ: FAIL** — провалов: $FAILS."; } >> "$SUM"
fi
exit $FAILS
