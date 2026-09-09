#!/usr/bin/env bash
# append-image под /bin/bash: тела API-запросов доходят валидным JSON.
#
# Зачем: на macOS /bin/bash = 3.2, и вложенная подстановка
# $( … "$(python3 -c "…{…}…")" … ) там теряет кавычки внутреннего скрипта —
# словарь в inline-python режется brace expansion, тело запроса уходит пустым
# (SyntaxError в stderr + HTTP 411 от nginx). На bash 5 (CI) конструкция
# работает, поэтому баг ловится только запуском под /bin/bash на маке;
# здесь CI-гейт держит инвариант «тела запросов валидны», мак — сам баг.
#
# buildin.sh и curl застаблены: тест пишет тела запросов в файлы и проверяет,
# что дедуп (/api/search/resource) и getS3FileUploadInfo получили валидный
# JSON с sha256/size, а stderr чист от SyntaxError.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$TESTS_DIR/../scripts"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0

fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok()   { echo "ok:   $1"; }

# ---- песочница: копия скриптов + стабы --------------------------------------
mkdir -p "$TMP/scripts" "$TMP/bin" "$TMP/log"
cp "$SRC_DIR/buildin-pages.sh" "$SRC_DIR/buildin-blocks.py" "$TMP/scripts/"

cat > "$TMP/scripts/buildin.sh" <<STUB
#!/usr/bin/env bash
# Стаб buildin.sh: пишет тело запроса в log/, отвечает канонными JSON.
METHOD="\$1"; ENDPOINT="\$2"; BODY="\${3:-}"
LOG_DIR="$TMP/log"
case "\$ENDPOINT" in
    /api/users/me)                   echo '{"code":200,"data":{"uuid":"user-1"}}' ;;
    /api/blocks/*)                   echo '{"code":200,"data":{"spaceId":"space-1","parentId":"parent-1"}}' ;;
    /api/search/resource)            printf '%s' "\$BODY" > "\$LOG_DIR/dedup-body.json"
                                     echo '{"code":200,"data":{"ossName":""}}' ;;
    /api/upload/getS3FileUploadInfo) printf '%s' "\$BODY" > "\$LOG_DIR/upload-body.json"
                                     echo '{"code":200,"data":{"s3Key":"s3/test/pic.png","uploadUrl":"https://s3.local/put"}}' ;;
    /api/records/transactions)       printf '%s' "\$BODY" > "\$LOG_DIR/tx-body.json"
                                     echo '{"code":200,"data":true}' ;;
    *)                               echo '{"code":404,"msg":"stub: unknown endpoint '"\$ENDPOINT"'"}' ;;
esac
STUB
chmod +x "$TMP/scripts/buildin.sh"

cat > "$TMP/bin/curl" <<'STUB'
#!/bin/sh
# Стаб curl для PUT в S3: append-image ждёт «200» через -w "%{http_code}".
echo 200
STUB
chmod +x "$TMP/bin/curl"

python3 -c "
import struct, zlib
sig = b'\x89PNG\r\n\x1a\n'
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
idat = chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00'))
open('$TMP/pic.png', 'wb').write(sig + ihdr + idat + chunk(b'IEND', b''))
"

# ---- прогон под /bin/bash (на маке это 3.2 — целевой шелл скриптов) ----------
STDERR="$TMP/log/stderr.txt"
PATH="$TMP/bin:$PATH" /bin/bash "$TMP/scripts/buildin-pages.sh" \
    append-image 11111111-2222-3333-4444-555555555555 "$TMP/pic.png" "подпись" \
    > "$TMP/log/stdout.txt" 2> "$STDERR"
RC=$?

# ---- проверки ----------------------------------------------------------------
[ "$RC" -eq 0 ] && ok "append-image завершился без ошибки" \
                || fail "append-image упал (rc=$RC), stderr: $(cat "$STDERR")"

if grep -q 'SyntaxError' "$STDERR"; then
    fail "в stderr — SyntaxError от inline-python (brace expansion порезал скрипт)"
else
    ok "stderr чист от SyntaxError"
fi

for req in dedup upload; do
    body_file="$TMP/log/$req-body.json"
    if [ ! -s "$body_file" ]; then
        fail "$req: тело запроса пустое или запрос не отправлен"
        continue
    fi
    if python3 -c "
import json, sys
body = json.load(open(sys.argv[1]))
assert body['sha256'] and body['size'] > 0, 'нет sha256/size'
" "$body_file" 2>/dev/null; then
        ok "$req: тело запроса — валидный JSON с sha256/size"
    else
        fail "$req: тело запроса не парсится или без sha256/size: $(cat "$body_file")"
    fi
done

grep -q '^ossName: s3/test/pic.png$' "$TMP/log/stdout.txt" \
    && ok "ossName из getS3FileUploadInfo дошёл до вывода" \
    || fail "в выводе нет ossName (stdout: $(cat "$TMP/log/stdout.txt"))"

echo "---"
if [ "$FAILS" -gt 0 ]; then
    echo "$FAILS check(s) failed"
    exit 1
fi
echo "all checks passed"
