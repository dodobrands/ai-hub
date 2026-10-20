#!/usr/bin/env bash
# CI-гейт: голый `[[ … ]]` посреди @test в bats-файлах интеграций.
#
# Зачем: bats ловит провал проверки через set -e, а bash до 4.1 на упавший
# `[[ … ]]` errexit не срабатывает. На маке /bin/bash — 3.2, и такая проверка
# посреди теста молча проходит: тест зелёный, хотя условие ложно. Последняя
# команда теста безопасна — её статус и есть статус теста. Остальные пишутся
# как `[[ … ]] || false` или через `[ … ]`.
#
# Голым считается и `(( … ))`: под bash 3.2 его провал тоже не роняет тест.
#
# Ограничение: CI гоняет bats под bash 5 на ubuntu, а bash 3.2 проверяется
# только локально на маке. Гейт закрывает одну причину расхождения — голые
# `[[ ]]` и `(( ))`, — а не все: прочие отличия 3.2 от 5 CI не увидит.
#
# Гейт сначала проверяет сам детектор на образцах, потом — все bats-файлы
# integrations. Любой провал → exit≠0 → CI красный.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0

ok(){ printf '  ok    %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

# Детектор: печатает «файл:строка: текст» на каждый голый [[ ]] или (( ))
# не последней командой @test. Строки с «\» на конце и строки с незакрытой
# «[[» склеиваются в одну команду; тела heredoc (встроенный python и т.п.)
# пропускаются — это не bash.
cat > "$TMP/detect.py" <<'PY'
import re
import sys

TEST_START = re.compile(r'^@test\s.*\{\s*$')
# «<<<» — here-string, не heredoc: принятый за heredoc, он скрыл бы строки до
# мнимого терминатора, а при поиске конца теста — и все тесты до конца файла.
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*['\"]?(\w+)['\"]?")


def commands(body):
    """(номер первой строки, логическая команда) тела теста без комментариев и пустых."""
    out, buf, start, heredoc = [], "", None, None
    for lineno, line in body:
        if heredoc:
            if line.strip() == heredoc:
                heredoc = None
            continue
        stripped = line.strip()
        if not buf and (not stripped or stripped.startswith("#")):
            continue
        if start is None:
            start = lineno
        cont = stripped.endswith("\\")
        buf += (stripped[:-1] if cont else stripped) + " "
        # Без «\», но с незакрытой «[[» или «((» — та же команда: bash ждёт
        # закрывающие скобки на следующих строках.
        if cont or buf.count("[[") > buf.count("]]") or buf.count("((") > buf.count("))"):
            continue
        out.append((start, buf.strip()))
        m = HEREDOC.search(buf)
        if m:
            heredoc = m.group(1)
        buf, start = "", None
    return out


def strip_tail(cmd):
    """Команда без хвостового комментария и «;». «#» в кавычках и в $# — не комментарий."""
    out, quote = [], None
    for i, ch in enumerate(cmd):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or cmd[i - 1].isspace()):
            break
        out.append(ch)
    return "".join(out).strip().rstrip(";").rstrip()


def bare(cmd):
    """Команда — сам [[ ]] или (( )) (возможно с !), без «|| …» после скобок."""
    c = strip_tail(cmd)
    if c.startswith("! "):
        c = c[2:].lstrip()
    return (c.startswith("[[") and c.endswith("]]")) or (c.startswith("((") and c.endswith("))"))


def scan(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    found, i = [], 0
    while i < len(lines):
        if TEST_START.match(lines[i]):
            # Конец теста — «}» в нулевой колонке вне heredoc: внутри heredoc
            # такая строка — текст, и тест не кончается.
            body, j, heredoc = [], i + 1, None
            while j < len(lines):
                line = lines[j]
                if heredoc:
                    if line.strip() == heredoc:
                        heredoc = None
                elif line.rstrip() == "}":
                    break
                else:
                    m = HEREDOC.search(line)
                    if m:
                        heredoc = m.group(1)
                body.append((j + 1, line))
                j += 1
            cmds = commands(body)
            for lineno, cmd in cmds[:-1]:
                if bare(cmd):
                    found.append("%s:%d: %s" % (path, lineno, cmd))
            i = j
        i += 1
    return found


bad = [f for p in sys.argv[1:] for f in scan(p)]
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY

detect(){ python3 "$TMP/detect.py" "$@"; }

# ---- детектор на образцах ----------------------------------------------------
sample(){ printf '%s\n' "$@" > "$TMP/sample.bats"; }

sample '@test "x" {' '    [[ "$a" == b ]]' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "голый [[ ]] посреди теста не замечен" || ok "голый [[ ]] посреди теста замечен"

sample '@test "x" {' '    [ "$c" -eq 0 ]' '    [[ "$a" == b ]]' '}'
detect "$TMP/sample.bats" > /dev/null && ok "[[ ]] последней командой допустим" || fail "последний [[ ]] ошибочно отвергнут"

sample '@test "x" {' '    [[ "$a" == b ]] || false' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && ok "[[ ]] || false посреди теста допустим" || fail "[[ ]] || false ошибочно отвергнут"

sample '@test "x" {' '    ! [[ "$a" == b ]]' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "! [[ ]] посреди теста не замечен" || ok "! [[ ]] посреди теста замечен"

sample '@test "x" {' '    [[ "$a" == b \' '       && "$d" == e ]]' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "[[ ]] с переносом строки не замечен" || ok "[[ ]] с переносом строки замечен"

sample '@test "x" {' '    run python3 - <<'"'"'PY'"'"'' '[[ not bash ]]' 'PY' '    # [[ в комментарии ]]' '' '    [ "$status" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && ok "heredoc и комментарии не проверяются" || fail "heredoc или комментарий принят за [[ ]]"

sample 'helper() {' '    [[ "$a" == b ]]' '    echo x' '}' '@test "x" {' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && ok "вне @test гейт не смотрит" || fail "гейт сработал вне @test"

sample '@test "x" {' '    [[ "$a" == b ]]  # почему' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "[[ ]] с комментарием в конце не замечен" || ok "[[ ]] с комментарием в конце замечен"

sample '@test "x" {' '    [[ "$a" == b ]];' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "[[ ]]; не замечен" || ok "[[ ]]; замечен"

sample '@test "x" {' '    [[ "$a" == b &&' '       "$c" == d ]]' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "[[ ]] с переносом без «\\» не замечен" || ok "[[ ]] с переносом без «\\» замечен"

sample '@test "x" {' '    (( n == 2 ))' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "(( )) посреди теста не замечен" || ok "(( )) посреди теста замечен"

sample '@test "x" {' '    [[ "$a" == "#x" ]] || false  # «#» в кавычках' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && ok "«#» в кавычках не режет команду" || fail "«#» в кавычках принят за комментарий"

sample '@test "x" {' '    [[ "$a" == "x #y" ]]' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "«#» в кавычках обрезал голый [[ ]] — не замечен" || ok "голый [[ ]] с «#» в кавычках замечен"

sample '@test "x" {' '    run python3 - <<'"'"'PY'"'"'' '}' 'PY' '    [[ "$a" == b ]]' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "«}» в heredoc оборвал тест — [[ ]] после него не замечен" || ok "«}» в heredoc не обрывает тест"

sample '@test "x" {' '    run cat <<< word' '    [[ "$a" == b ]]' '    [ "$c" -eq 0 ]' '}'
detect "$TMP/sample.bats" > /dev/null && fail "«<<<» принят за heredoc — [[ ]] после него не замечен" || ok "«<<<» — не heredoc"

# ---- bats-файлы интеграций ---------------------------------------------------
# Тот же обход, что у раннера bats в shell-tests.yml: гейт смотрит ровно на то,
# что гоняет CI.
FILES=$(cd "$REPO" && find integrations -path '*/tests/*.bats' | sort)
if [ -z "$FILES" ]; then
    fail "не найдено ни одного bats-файла в integrations — гейт смотрит не туда"
else
    # shellcheck disable=SC2086 # пути без пробелов: integrations/<имя>/tests/<файл>.bats
    if OUT=$(cd "$REPO" && detect $FILES); then
        ok "голых [[ ]] посреди @test нет ($(echo "$FILES" | wc -l | tr -d ' ') файлов)"
    else
        fail "голый [[ ]] посреди @test — под bash 3.2 он не роняет тест; допишите || false:"
        printf '%s\n' "$OUT" | sed 's/^/        /'
    fi
fi

echo "-----"
if [ "$FAILS" -eq 0 ]; then echo "PASS"; else echo "$FAILS fail(s)"; exit 1; fi
