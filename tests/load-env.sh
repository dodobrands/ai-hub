#!/usr/bin/env bash
# CI-гейт: поиск .env (hub_load_env) и резолв самого load-env.sh по раскладкам установки.
#
# Зачем: токен настраивается один раз, а скрипты запускаются из разных деревьев —
# клон репо, team-overlay, кеш плагинов Claude Code, marketplace-клон. Кеш и
# marketplace — соседние ветки ~/.claude/plugins, обходом вверх из одной в другую
# не попасть, поэтому есть фолбэк на профиль пользователя. Плюс сам load-env.sh
# в кеш-раскладке лежит за версией (hub-meta/<version>/scripts) и должен
# находиться без $CLAUDE_PLUGIN_ROOT — переменная выставлена только внутри
# Claude Code, а скрипты зовут и из обычного шелла.
#
# Любой провал → exit≠0 → CI красный.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOAD_ENV="$REPO/integrations/hub-meta/scripts/load-env.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0
SUM="${GITHUB_STEP_SUMMARY:-/dev/null}"

pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

check(){ # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; r=PASS; else fail "$1 — ожидали [$2], получили [$3]"; r=FAIL; fi
  echo "| $1 | $r |" >> "$SUM"
}

mkenv(){ mkdir -p "$(dirname "$1")"; printf 'KAITEN_TOKEN=%s\n' "$2" > "$1"; }

# Прогон hub_load_env в изолированном HOME. Печатает найденный токен (или пусто).
run_load(){ # start_dir home [xdg_config_home]
  ( HOME="$2" XDG_CONFIG_HOME="${3:-}" CLAUDE_PLUGIN_ROOT="" bash -c '
      [ -n "$XDG_CONFIG_HOME" ] || unset XDG_CONFIG_HOME
      . "$1"
      hub_load_env "$2" || exit 0
      printf %s "$KAITEN_TOKEN"
    ' _ "$LOAD_ENV" "$1" )
}

# ============================================================================
# 1) hub_load_env: приоритет «ближайший .env → профиль пользователя»
# ============================================================================
echo "== hub_load_env (репо / overlay / профиль) =="
{ echo "### Поиск .env — hub_load_env"; echo; echo "| Сценарий | Итог |"; echo "|---|---|"; } >> "$SUM"

# 1.1 Кеш-раскладка: .env лежит выше по дереву — берём его, профиль не трогаем.
H="$TMP/c1/home"
CACHE="$H/.claude/plugins/cache/ai-hub"
mkdir -p "$CACHE/time/1.1.3/scripts"
mkenv "$CACHE/.env" from_cache
mkenv "$H/.ai-hub/.env" from_profile
check "кеш-раскладка: .env вверх по дереву" \
      "from_cache" "$(run_load "$CACHE/time/1.1.3/scripts" "$H")"

# 1.2 Marketplace-раскладка: вверх .env нет (кеш — соседняя ветка), берём профиль.
H="$TMP/c2/home"
MKT="$H/.claude/plugins/marketplaces/ai-hub/integrations/time/scripts"
mkdir -p "$MKT"
mkenv "$H/.claude/plugins/cache/ai-hub/.env" from_cache_profile
check "marketplace-раскладка: фолбэк на ~/.claude/plugins/cache/ai-hub/.env" \
      "from_cache_profile" "$(run_load "$MKT" "$H")"

# 1.2b Standalone-клон вне ~/.claude + токены лежат в ~/.claude/plugins/.env (куда доходит
#      walk-up у plugin-cache скриптов): последний профильный фолбэк.
H="$TMP/c2b/home"
CLONE="$H/src/ai-hub/integrations/time/scripts"
mkdir -p "$CLONE"
mkenv "$H/.claude/plugins/.env" from_plugins_root
check "standalone-клон: фолбэк на ~/.claude/plugins/.env" \
      "from_plugins_root" "$(run_load "$CLONE" "$H")"

# 1.3 Репозиторный .env сильнее профиля.
H="$TMP/c3/home"
REPO_DIR="$TMP/c3/team-repo"
mkdir -p "$REPO_DIR/integrations/time/scripts"
mkenv "$REPO_DIR/.env" from_repo
mkenv "$H/.ai-hub/.env" from_profile
check "репозиторный .env приоритетнее профиля" \
      "from_repo" "$(run_load "$REPO_DIR/integrations/time/scripts" "$H")"

# 1.4 Порядок внутри профиля: XDG → ~/.ai-hub → кеш плагинов.
H="$TMP/c4/home"
XDG="$TMP/c4/xdg"
MKT="$H/.claude/plugins/marketplaces/ai-hub/integrations/time/scripts"
mkdir -p "$MKT"
mkenv "$XDG/ai-hub/.env" from_xdg
mkenv "$H/.ai-hub/.env" from_dot_ai_hub
mkenv "$H/.claude/plugins/cache/ai-hub/.env" from_cache_profile
check "профиль: XDG_CONFIG_HOME впереди остальных" \
      "from_xdg" "$(run_load "$MKT" "$H" "$XDG")"

H="$TMP/c5/home"
MKT="$H/.claude/plugins/marketplaces/ai-hub/integrations/time/scripts"
mkdir -p "$MKT"
mkenv "$H/.ai-hub/.env" from_dot_ai_hub
mkenv "$H/.claude/plugins/cache/ai-hub/.env" from_cache_profile
check "профиль: ~/.ai-hub впереди кеша плагинов" \
      "from_dot_ai_hub" "$(run_load "$MKT" "$H")"

# 1.5 Нигде нет .env → hub_load_env возвращает 1 (вывод пустой).
H="$TMP/c6/home"
MKT="$H/.claude/plugins/marketplaces/ai-hub/integrations/time/scripts"
mkdir -p "$MKT"
check "нет .env нигде → hub_load_env != 0" "" "$(run_load "$MKT" "$H")"

# ============================================================================
# 2) Бутстрап: сам load-env.sh находится в кеш-раскладке без CLAUDE_PLUGIN_ROOT
# ============================================================================
echo
echo "== Резолв load-env.sh (кеш плагинов, CLAUDE_PLUGIN_ROOT не выставлен) =="
{ echo; echo "### Резолв load-env.sh — кеш плагинов без CLAUDE_PLUGIN_ROOT"; echo; echo "| Скрипт | Итог |"; echo "|---|---|"; } >> "$SUM"

# Кеш-раскладка: <cache>/<marketplace>/<plugin>/<version>/scripts/
# Версий hub-meta рядом несколько (кеш их копит) — резолв обязан взять старшую.
# Набор подобран так, что лексикографический порядок ≠ версионный: `head -1`
# выбрал бы 1.2.2, а нужна 2.0.0.
CACHE="$TMP/bootstrap/cache/ai-hub"
EXPECTED_HUB_META="$CACHE/hub-meta/2.0.0/scripts/load-env.sh"
for v in 1.2.2 1.10.0 2.0.0; do
  mkdir -p "$CACHE/hub-meta/$v/scripts"
  cp "$LOAD_ENV" "$CACHE/hub-meta/$v/scripts/load-env.sh"
done

for f in $(grep -rl '^_hub_load_env_sh="\$SCRIPT_DIR/\.\./\.\./hub-meta/scripts/load-env\.sh"' "$REPO/integrations" | sort); do
  rel="${f#"$REPO"/}"
  plugin="$(echo "$rel" | cut -d/ -f2)"
  scripts_dir="$CACHE/$plugin/9.9.9/scripts"
  mkdir -p "$scripts_dir"
  # Бутстрап-блок из реального скрипта: объявление _hub_load_env_sh и идущие
  # следом строки-фолбэки. Дальше (source / сообщение об ошибке) — не наше дело.
  snip="$(awk '/^_hub_load_env_sh=/{p=1} p && !/^_hub_load_env_sh=/ && !/^\[\[ -f "\$_hub_load_env_sh" \]\] \|\| _hub_load_env_sh=/{exit} p' "$f")"
  got="$( CLAUDE_PLUGIN_ROOT="" bash -c "set -e; unset CLAUDE_PLUGIN_ROOT; SCRIPT_DIR='$scripts_dir'
$snip
printf %s \"\$_hub_load_env_sh\"" 2>/dev/null )"
  if [ ! -f "$got" ]; then
    fail "$rel — load-env.sh не найден → [$got]"; r=FAIL
  elif [ "$(cd "$(dirname "$got")" && pwd)/load-env.sh" != "$EXPECTED_HUB_META" ]; then
    fail "$rel — взята не старшая версия → [$got]"; r=FAIL
  else
    pass "$rel"; r=PASS
  fi
  echo "| $rel | $r |" >> "$SUM"
done

echo
if [ $FAILS -eq 0 ]; then
  echo "ИТОГ: PASS — .env и load-env.sh находятся во всех раскладках"
  { echo; echo "**ИТОГ: PASS** — все сценарии зелёные."; } >> "$SUM"
else
  echo "ИТОГ: FAIL — провалов: $FAILS"
  { echo; echo "**ИТОГ: FAIL** — провалов: $FAILS."; } >> "$SUM"
fi
exit $FAILS
