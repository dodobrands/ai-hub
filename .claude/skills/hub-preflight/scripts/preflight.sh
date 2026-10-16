#!/usr/bin/env bash
# Префлайт ветки ai-hub перед PR: ловит то, что ревью раз за разом находит руками.
#
# Проверяет только изменения ветки относительно базы (merge-base с origin/main),
# кроме манифестов и симлинков: их рассинхрон проверяется по всему репозиторию,
# потому что ломает установку независимо от того, кто его внёс.
#
# Usage (из корня репозитория):
#   bash .claude/skills/hub-preflight/scripts/preflight.sh [--base <ref>] [--no-tests]
#
# Exit: 0, если нет FAIL (WARN не валит); 1, если есть хоть один FAIL.
#
# Локальный стоп-лист обезличивания: файл .deident-denylist в корне (в .gitignore,
# в репозиторий не коммитится), по одному regex на строку: имена компаний,
# внутренние домены, логины. Публичный репозиторий их не перечисляет.
#
# Совместимость: bash 3.2 (дефолт macOS). Без mapfile, declare -A, ${x,,}.
set -u

BASE_REF="origin/main"
RUN_TESTS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2 ;;
    --no-tests) RUN_TESTS=0; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "не git-репозиторий" >&2; exit 2; }
cd "$ROOT" || exit 2
[ -f .claude-plugin/marketplace.json ] || { echo "запускай из клона ai-hub" >&2; exit 2; }

FAILS=0
WARNS=0
pass() { printf '  PASS  %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; WARNS=$((WARNS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
section() { printf '\n## %s\n' "$1"; }

BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || {
  echo "не нашёл базу $BASE_REF: сделай git fetch origin" >&2; exit 2;
}
CHANGED=$(
  { git diff --name-only --diff-filter=ACMR "$BASE" HEAD
    git diff --name-only --diff-filter=ACMR HEAD
    git ls-files --others --exclude-standard; } | sort -u
)
changed_matching() { printf '%s\n' "$CHANGED" | grep -E "$1" || true; }

# Добавленные строки ветки, включая незакоммиченное: "файл:текст".
added_lines() {
  { git diff -U0 "$BASE" -- "$@"; git diff -U0 -- "$@"; } | awk '
    /^\+\+\+ b\// { f = substr($0, 7); next }
    /^\+/ && !/^\+\+\+/ { print f ":" substr($0, 2) }'
  for u in $(git ls-files --others --exclude-standard -- "$@"); do
    [ -f "$u" ] && awk -v f="$u" '{ print f ":" $0 }' "$u"
  done
}

printf 'ai-hub preflight: база %s (%s), изменено файлов: %s\n' \
  "$BASE_REF" "$(git rev-parse --short "$BASE")" "$(printf '%s\n' "$CHANGED" | grep -c . || true)"

# ---------------------------------------------------------------------------
section "Манифесты: plugin.json и marketplace.json согласованы"
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$1" "$2"; }
MKT_LIST=$(python3 -c '
import json
for p in json.load(open(".claude-plugin/marketplace.json"))["plugins"]:
    print(p["name"], p.get("version", ""), p["source"])')
drift=0
for pj in integrations/*/.claude-plugin/plugin.json; do
  name=$(json_get "$pj" name); ver=$(json_get "$pj" version)
  line=$(printf '%s\n' "$MKT_LIST" | awk -v n="$name" '$1 == n')
  if [ -z "$line" ]; then
    warn "$name ($pj) нет в marketplace.json: плагин не установится из маркетплейса"
    drift=1; continue
  fi
  mver=$(printf '%s' "$line" | awk '{print $2}')
  if [ "$mver" != "$ver" ]; then
    # Рассинхрон, который уже есть на базе, не вина ветки: WARN, чтобы не блокировать
    # чужую работу. Новый рассинхрон (ветка подняла одну сторону) это FAIL.
    bver=$(git show "$BASE:$pj" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)
    bmver=$(git show "$BASE:.claude-plugin/marketplace.json" 2>/dev/null | python3 -c '
import json,sys
for p in json.load(sys.stdin)["plugins"]:
    if p["name"] == sys.argv[1]: print(p.get("version",""))' "$name" 2>/dev/null)
    if [ "$bver" = "$ver" ] && [ "$bmver" = "$mver" ]; then
      warn "$name: plugin.json $ver, marketplace.json $mver (унаследовано с базы)"
    else
      fail "$name: plugin.json $ver, marketplace.json $mver (подними обе стороны одинаково)"
    fi
    drift=1
  fi
done
while read -r name _ src; do
  [ -z "$name" ] && continue
  [ -d "$src" ] || { fail "marketplace.json: $name указывает на несуществующий $src"; drift=1; }
done <<EOF
$MKT_LIST
EOF
for p in $(python3 -c 'import json; print("\n".join(json.load(open(".claude/settings.json")).get("plugins", [])))' 2>/dev/null); do
  [ -d "$p" ] || { warn ".claude/settings.json: plugins ссылается на несуществующий $p"; drift=1; }
done
[ "$drift" -eq 0 ] && pass "версии и пути манифестов совпадают"

# ---------------------------------------------------------------------------
section "Bump версии для изменённых плагинов"
touched=$(changed_matching '^integrations/[^/]+/(commands|skills|agents|scripts)/' | cut -d/ -f2 | sort -u)
if [ -z "$touched" ]; then
  pass "скиллы, команды, агенты и скрипты интеграций не менялись"
else
  for integ in $touched; do
    pj="integrations/$integ/.claude-plugin/plugin.json"
    [ -f "$pj" ] || { warn "$integ: изменения есть, а plugin.json нет"; continue; }
    old=$(git show "$BASE:$pj" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || echo "")
    new=$(json_get "$pj" version)
    if [ -n "$old" ] && [ "$old" = "$new" ]; then
      fail "$integ: код менялся, версия осталась $new (patch для правок, minor для нового скилла)"
    else
      pass "$integ: ${old:-новый} -> $new"
    fi
  done
  old_root=$(git show "$BASE:.claude-plugin/plugin.json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
  new_root=$(json_get .claude-plugin/plugin.json version)
  if [ "$old_root" = "$new_root" ]; then
    fail "корневой .claude-plugin/plugin.json: версия $new_root не поднята (правило из CLAUDE.md)"
  else
    pass "корневая версия: $old_root -> $new_root"
  fi
fi

# ---------------------------------------------------------------------------
section "Симлинки команд"
broken=$(find .claude integrations -type l ! -exec test -e {} \; -print 2>/dev/null)
if [ -n "$broken" ]; then
  printf '%s\n' "$broken" | while read -r l; do fail "битый симлинк: $l -> $(readlink "$l")"; done
  FAILS=$((FAILS + $(printf '%s\n' "$broken" | grep -c .)))
else
  pass "битых симлинков нет"
fi
for cmd in $(changed_matching '^integrations/[^/]+/commands/[^/]+\.md$'); do
  link=".claude/commands/ai-hub/$(basename "$cmd")"
  [ -L "$link" ] || warn "$cmd без симлинка $link (создай через /ai-hub:create-command или ln -s)"
done

# ---------------------------------------------------------------------------
section "Обезличивание (только добавленные строки)"
DEIDENT_RE='https?://[a-z0-9-]+\.(kaiten\.ru|time-messenger\.ru|qatools\.cloud|ktalk\.ru)'
DEIDENT_RE="$DEIDENT_RE"'|buildin\.ai/[0-9a-f]{8}-[0-9a-f]{4}'
DEIDENT_RE="$DEIDENT_RE"'|/(space|card|boards?)/[0-9]{4,}'
DEIDENT_RE="$DEIDENT_RE"'|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}'
ALLOW_RE='your-company|your-domain|<domain>|<[a-z_]+>|example\.(com|org|invalid)|j\.doe|noreply@|users\.noreply\.github\.com|git@github\.com'
if [ -f .deident-denylist ]; then
  extra=$(grep -v '^[[:space:]]*\(#\|$\)' .deident-denylist | paste -sd'|' -)
  [ -n "$extra" ] && DEIDENT_RE="$DEIDENT_RE|$extra"
else
  warn "нет .deident-denylist: имена компаний и внутренние домены не проверяются (см. SKILL.md)"
fi
hits=$(added_lines . ':!*.lock' | grep -iE "$DEIDENT_RE" | grep -viE "$ALLOW_RE" | head -20)
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" | while IFS= read -r h; do fail "конкретика: $h"; done
  FAILS=$((FAILS + $(printf '%s\n' "$hits" | grep -c .)))
else
  pass "реальных хостов, ID и email в добавленных строках нет"
fi

# ---------------------------------------------------------------------------
section "Shell: shellcheck и совместимость bash 3.2 / zsh"
sh_files=$(changed_matching '\.sh$' | grep -v '^tests/' | grep -v '^\.claude/skills/hub-preflight/' || true)
if [ -z "$sh_files" ]; then
  pass "shell-скрипты не менялись"
else
  if shellcheck --version >/dev/null 2>&1; then
    for f in $sh_files; do
      if out=$(shellcheck -S warning -x "$f" 2>&1); then pass "shellcheck $f"
      else fail "shellcheck $f"; printf '%s\n' "$out" | head -15 | sed 's/^/        /'; fi
    done
  else
    warn "shellcheck не запускается (brew install shellcheck): скрипты не проверены"
  fi
  # bash 3.2 это /bin/bash на маке: bash-4-измы падают у половины пользователей.
  b4=$(added_lines $sh_files | grep -vE '^[^:]+:[[:space:]]*#' | grep -E '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)|declare -[AnlU]|local -[AnlU]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|&>>|\|&|\[-1\]' | head -10)
  if [ -n "$b4" ]; then
    printf '%s\n' "$b4" | while IFS= read -r h; do fail "bash 4+: ${h#*:}"; done
    FAILS=$((FAILS + $(printf '%s\n' "$b4" | grep -c .)))
  else
    pass "bash-4-измов в добавленных строках нет"
  fi
fi
# Резолверы в .md выполняются в шелле пользователя (на маке zsh): glob без совпадения там фатален.
md_changed=$(changed_matching '^integrations/.*\.md$')
if [ -n "$md_changed" ]; then
  zg=$(added_lines $md_changed | grep -E '_SCRIPTS=\$\(ls -d .*\*' | head -5)
  if [ -n "$zg" ]; then
    printf '%s\n' "$zg" | while IFS= read -r h; do warn "glob в резолвере (в zsh no matches found обрывает подстановку): ${h%%:*}"; done
  else
    pass "новых glob-резолверов в .md нет"
  fi
fi

# ---------------------------------------------------------------------------
section "Python: секреты и трейсбеки"
py_files=$(changed_matching '\.py$')
if [ -n "$py_files" ]; then
  for f in $py_files; do python3 -m py_compile "$f" 2>/dev/null && pass "компилируется $f" || fail "синтаксис $f"; done
  tb=$(added_lines $py_files | grep -E 'urlopen\(|requests\.(get|post|put|patch|delete)\(' | head -5)
  [ -n "$tb" ] && warn "сетевые вызовы в python: убедись, что HTTPError ловится и печатается одной строкой без трейсбека"
fi
rm -rf integrations/*/scripts/__pycache__ integrations/*/tests/__pycache__ 2>/dev/null

# ---------------------------------------------------------------------------
section "Эвристики по прошлым ревью (WARN, решай сам)"
scr_files=$(changed_matching '^integrations/[^/]+/scripts/.*\.(sh|py)$')
if [ -z "$scr_files" ]; then
  pass "скрипты интеграций не менялись"
else
  # Тихий отказ: ошибка API глушится, команда выходит с 0, агент видит «пусто».
  silent=$(added_lines $scr_files | grep -E 'curl[^|]*(2>/dev/null|\|\| true)|curl -s[^S]' | head -5)
  [ -n "$silent" ] && printf '%s\n' "$silent" | while IFS= read -r h; do
    warn "curl может молча проглотить ошибку (нужны -sS, проверка HTTP-кода и rc!=0): ${h%%:*}"; done
  # Предсказуемые пути в /tmp: коллизии между запусками и права по umask.
  tmpf=$(added_lines $scr_files | grep -E '["'"'"' =]/tmp/[A-Za-z0-9_.$-]' | grep -v mktemp | head -5)
  [ -n "$tmpf" ] && printf '%s\n' "$tmpf" | while IFS= read -r h; do
    warn "фиксированный путь в /tmp (используй mktemp и chmod 600): ${h%%:*}"; done
  # Подстановка внутри local/export теряет код возврата (SC2155), под set -e это ложный успех.
  sub=$(added_lines $scr_files | grep -E '^[^:]+:[[:space:]]*(local|export|readonly) [A-Za-z_]+=\$\(' | head -5)
  [ -n "$sub" ] && printf '%s\n' "$sub" | while IFS= read -r h; do
    warn "local/export x=\$(...) глотает ошибку подстановки: ${h#*:}"; done
  ascii=$(added_lines $scr_files | grep -E 'ensure_ascii=False' | head -3)
  [ -n "$ascii" ] && warn "ensure_ascii=False: проверь вывод под LC_ALL=C (падает на кодировке stdout)"
  # Новая возможность в скрипте, а инструкции агента не тронуты: агент о ней не узнает.
  for integ in $(printf '%s\n' "$scr_files" | cut -d/ -f2 | sort -u); do
    if ! printf '%s\n' "$CHANGED" | grep -qE "^integrations/$integ/(commands|skills|agents)/"; then
      warn "$integ: скрипты менялись, commands/skills нет. Новый флаг или команда только в README агенту не видны"
    fi
  done
fi

# ---------------------------------------------------------------------------
section "Тесты"
if [ "$RUN_TESTS" -eq 0 ]; then
  warn "тесты пропущены (--no-tests)"
else
  integ_changed=$(changed_matching '^integrations/' | cut -d/ -f2 | sort -u)
  if command -v bats >/dev/null 2>&1; then
    for integ in $integ_changed; do
      ls "integrations/$integ/tests/"*.bats >/dev/null 2>&1 || continue
      if out=$(bats "integrations/$integ/tests/"*.bats 2>&1); then pass "bats $integ ($(printf '%s\n' "$out" | grep -c '^ok'))"
      else fail "bats $integ"; printf '%s\n' "$out" | grep -E '^not ok|#' | head -15 | sed 's/^/        /'; fi
    done
  else
    warn "bats не установлен (brew install bats-core): юнит-тесты не прогнаны"
  fi
  for integ in $(printf '%s\n' "$CHANGED" | grep -E '^integrations/[^/]+/scripts/' | cut -d/ -f2 | sort -u); do
    if ! printf '%s\n' "$CHANGED" | grep -q "^integrations/$integ/tests/"; then
      warn "$integ: скрипты менялись, тесты нет. Новое поведение без bats-теста ревью вернёт"
    fi
  done
  for t in tests/*.sh; do
    if out=$(bash "$t" 2>&1); then pass "$t"
    else fail "$t"; printf '%s\n' "$out" | tail -10 | sed 's/^/        /'; fi
  done
fi

# ---------------------------------------------------------------------------
printf '\nИтог: FAIL %s, WARN %s\n' "$FAILS" "$WARNS"
[ "$FAILS" -eq 0 ]
