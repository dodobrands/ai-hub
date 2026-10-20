#!/usr/bin/env bash
# CI-гейт: проверки самого manifest-versions.sh не выключились.
#
# Зачем: manifest-versions.sh на здоровом репозитории всегда зелёный, поэтому
# случайно выключенная проверка там не видна — гейт продолжит «проходить»,
# ничего не проверяя. Здесь на синтетических манифестах проверяется, что каждый
# класс поломки по-прежнему валит job, а чистый манифест — нет.
#
# Фикстуры синтетические, а не копия репозитория: тест не должен краснеть от
# того, что в репозитории завели новый плагин.
#
# Любой провал → exit≠0 → CI красный.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO/tests/manifest-versions.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0
SUM="${GITHUB_STEP_SUMMARY:-/dev/null}"

{ echo "### Самопроверка manifest-versions.sh"; echo; echo "| Сценарий | Итог |"; echo "|---|---|"; } >> "$SUM"

# Фикстура: два плагина, оба согласованы. Правки вносит caller через python3.
mkfixture() { # dir
  local d="$1"
  mkdir -p "$d/tests" "$d/.claude-plugin" \
           "$d/integrations/alpha/.claude-plugin" "$d/integrations/beta/.claude-plugin"
  cp "$GATE" "$d/tests/"
  cat > "$d/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "fixture",
  "plugins": [
    { "name": "alpha", "version": "1.0.0", "source": "./integrations/alpha" },
    { "name": "beta",  "version": "2.0.0", "source": "./integrations/beta"  }
  ]
}
JSON
  printf '{ "name": "alpha", "version": "1.0.0" }\n' > "$d/integrations/alpha/.claude-plugin/plugin.json"
  printf '{ "name": "beta",  "version": "2.0.0" }\n' > "$d/integrations/beta/.claude-plugin/plugin.json"
}

# Прогон гейта на фикстуре. Печатает «код|вывод».
check() { # name expected_code expected_substring mutator_python
  local name="$1" want="$2" needle="$3" mutate="$4"
  local d="$TMP/$(echo "$name" | tr -c 'a-zA-Z0-9' '_')"
  rm -rf "$d"; mkfixture "$d"
  if [ -n "$mutate" ]; then python3 -c "
import json, os
os.chdir(r'''$d''')
$mutate
" || { printf '  FAIL  %s — фикстуру не собрать\n' "$name"; FAILS=$((FAILS+1)); return; }
  fi

  local out code r
  out=$( cd "$d" && bash tests/manifest-versions.sh 2>&1 ); code=$?

  if [ "$code" != "$want" ]; then
    printf '  FAIL  %s — ожидали exit=%s, получили %s\n' "$name" "$want" "$code"
    echo "$out" | sed 's/^/          /'
    FAILS=$((FAILS+1)); r=FAIL
  elif ! echo "$out" | grep -qF "$needle"; then
    printf '  FAIL  %s — в выводе нет [%s]\n' "$name" "$needle"
    echo "$out" | sed 's/^/          /'
    FAILS=$((FAILS+1)); r=FAIL
  else
    printf '  PASS  %s (exit=%s)\n' "$name" "$code"; r=PASS
  fi
  echo "| $name | $r |" >> "$SUM"
}

echo "== manifest-versions.sh: каждый класс поломки валит job =="

check "чистый манифест — зелёный" 0 "манифесты согласованы" ""

check "версии разошлись" 1 "Версии разошлись" "
d = json.load(open('integrations/alpha/.claude-plugin/plugin.json'))
d['version'] = '9.9.9'
json.dump(d, open('integrations/alpha/.claude-plugin/plugin.json', 'w'))
"

check "name не совпадает с каталогом плагина" 1 "Имя в plugin.json" "
d = json.load(open('integrations/alpha/.claude-plugin/plugin.json'))
d['name'] = 'alpha-typo'
json.dump(d, open('integrations/alpha/.claude-plugin/plugin.json', 'w'))
"

check "запись каталога без plugin.json" 1 "plugin.json" "
d = json.load(open('.claude-plugin/marketplace.json'))
d['plugins'].append({'name': 'gamma', 'version': '1.0.0', 'source': './integrations/gamma'})
json.dump(d, open('.claude-plugin/marketplace.json', 'w'))
"

check "source ведёт в чужой каталог" 1 "source" "
d = json.load(open('.claude-plugin/marketplace.json'))
d['plugins'][0]['source'] = './integrations/beta'
json.dump(d, open('.claude-plugin/marketplace.json', 'w'))
"

check "дубль имени в каталоге" 1 "одним именем" "
d = json.load(open('.claude-plugin/marketplace.json'))
dup = dict(d['plugins'][0]); dup['version'] = '1.0.0'
d['plugins'].insert(0, dup)
json.dump(d, open('.claude-plugin/marketplace.json', 'w'))
"

check "дубль имени с совпадающими версиями" 1 "одним именем" "
d = json.load(open('.claude-plugin/marketplace.json'))
d['plugins'].append(dict(d['plugins'][0]))
json.dump(d, open('.claude-plugin/marketplace.json', 'w'))
"

check "плагин не в каталоге — предупреждение, не провал" 0 "::warning" "
import os
os.makedirs('integrations/gamma/.claude-plugin')
open('integrations/gamma/.claude-plugin/plugin.json', 'w').write('{\"name\": \"gamma\", \"version\": \"1.0.0\"}')
"

echo
if [ $FAILS -eq 0 ]; then
  echo "ИТОГ: PASS — все проверки manifest-versions.sh на месте"
  { echo; echo "**ИТОГ: PASS** — все проверки на месте."; } >> "$SUM"
else
  echo "ИТОГ: FAIL — провалов: $FAILS"
  { echo; echo "**ИТОГ: FAIL** — провалов: $FAILS."; } >> "$SUM"
fi
exit $FAILS
