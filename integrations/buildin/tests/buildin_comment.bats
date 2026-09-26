#!/usr/bin/env bats
# Unit tests for buildin-comment.py — anchor lookup and the resplit checks.
#
# Поиск якоря и перенарезка сегментов — место, где ошибка тихая: тред
# привяжется не к той фразе или незаметно испортит блок. Поэтому здесь чистая
# функция без сети и без диска: doc-фикстура на вход, операции транзакции на
# выход. Разбор аргументов команды живёт в comment.sh — он про shell.

BLOCK=11111111-1111-4111-8111-111111111111
SPACE=22222222-2222-4222-8222-222222222222
USER=33333333-3333-4333-8333-333333333333
NOW=1700000000000

setup() {
    OPS_PY="$BATS_TEST_DIRNAME/../scripts/buildin-comment.py"
    DOC="$BATS_TEST_TMPDIR/doc.json"
}

# Документ-фикстура: один блок с заданными сегментами.
# $1 — segments (JSON), $2 — discussions блока (JSON, по умолчанию пусто).
mkdoc() {
    python3 - "$BLOCK" "$SPACE" "$1" "${2:-[]}" > "$DOC" <<'PY'
import json, sys
block_id, space_id, segments, discussions = sys.argv[1:5]
print(json.dumps({"data": {"blocks": {block_id: {
    "uuid": block_id,
    "spaceId": space_id,
    "type": 1,
    "discussions": json.loads(discussions),
    "data": {"segments": json.loads(segments), "pageFixedWidth": True},
}}}}))
PY
}

build() { # $1=anchor $2=text [flags...]
    local anchor="$1" text="$2"; shift 2
    python3 "$OPS_PY" "$DOC" "$BLOCK" "$anchor" "$text" "$NOW" "$USER" "$@" 2>/dev/null
}

# stderr упавшего запуска; пустая строка, если запуск внезапно успешен.
build_stderr() { # $1=anchor $2=text [flags...]
    local anchor="$1" text="$2"; shift 2
    python3 "$OPS_PY" "$DOC" "$BLOCK" "$anchor" "$text" "$NOW" "$USER" "$@" 2>&1 >/dev/null
}

# Выражение python над результатом: $1 — код, печатающий ответ.
probe() {
    python3 -c "
import json, sys
r = json.load(sys.stdin)
ops, rollback = r['ops'], r['rollback']
disc, comment, seg_op, list_op, touch_op = ops
$1"
}

# Прогон билдера с намеренно сломанным split_segments: проверки перенарезки
# обязаны поймать поломку. Без этого тест на инвариант был бы тавтологией —
# при исправном split_segments склейка не может разойтись по построению.
build_broken() { # $1=how $2=anchor
    python3 - "$OPS_PY" "$DOC" "$BLOCK" "$1" "$2" <<'PY'
import importlib.util, json, sys
ops_py, doc_path, block_id, how, anchor = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("bc", ops_py)
bc = importlib.util.module_from_spec(spec); spec.loader.exec_module(bc)
block = json.load(open(doc_path))["data"]["blocks"][block_id]
orig = bc.split_segments
if how == "drop-tail":
    bc.split_segments = lambda s, i, p, a, d: orig(s, i, p, a, d)[:-1]
elif how == "drop-url":
    def broken(s, i, p, a, d):
        out = orig(s, i, p, a, d)
        for x in out[i:i + 3]:
            x.pop("url", None)
        return out
    bc.split_segments = broken
elif how == "insert-empty":
    def broken(s, i, p, a, d):
        out = orig(s, i, p, a, d)
        out.insert(i, dict(out[i], text="", discussions=[]))
        return out
    bc.split_segments = broken
try:
    bc.build_ops(block, block_id, anchor, "t", 1, "u")
    print("НЕ ПОЙМАЛ")
except bc.AnchorError as e:
    print(str(e).split("\n")[0])
PY
}

# ---- форма операций ---------------------------------------------------------

@test "ops are narrow: segments via data path, discussion via list op" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build "beta" "note" | probe "
print(len(ops),
      seg_op['command'], '.'.join(seg_op['path']), list(seg_op['args']),
      list_op['command'], '.'.join(list_op['path']))")
    [ "$result" = "5 update data ['segments'] listAfter discussions" ]
}

@test "discussion and comment records are created before the block is touched" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build "beta" "note" | probe "print(disc['table'], comment['table'], seg_op['table'])")
    [ "$result" = "discussion comment block" ]
}

@test "rollback mirrors the write and retires the created records" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]' '["99999999-9999-4999-8999-999999999999"]'
    result=$(build "beta" "note" | probe "
print([ (o['command'], o['table']) for o in rollback ] ==
      [('update','block'),('listRemove','block'),('update','comment'),('update','discussion'),('update','block')],
      ''.join(s['text'] for s in rollback[0]['args']['segments']),
      len(rollback[0]['args']['segments']),
      rollback[1]['args']['uuid'] == r['discussion'],
      rollback[2]['args']['status'], rollback[3]['args']['status'])")
    [ "$result" = "True alpha beta 1 True -1 -1" ]
}

@test "existing block discussions are left untouched by the list op" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]' '["99999999-9999-4999-8999-999999999999"]'
    result=$(build "beta" "note" | probe "
print(list(list_op['args']) == ['uuid'],
      list_op['args']['uuid'] == r['discussion'],
      'discussions' not in seg_op['args'])")
    [ "$result" = "True True True" ]
}

# ---- перенарезка сегментов --------------------------------------------------

@test "block text is byte-identical after the anchor is split out" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {"bold": true}}, {"text": "beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build "beta" "note" | probe "print(''.join(s['text'] for s in seg_op['args']['segments']))")
    [ "$result" = "alpha beta gamma" ]
}

@test "anchor is split into its own segment with before and after kept" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build "beta" "note" | probe "print('|'.join(s['text'] for s in seg_op['args']['segments']))")
    [ "$result" = "alpha |beta| gamma" ]
}

@test "anchor at segment start produces no empty leading segment" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    result=$(build "alpha" "note" | probe "print('|'.join(s['text'] for s in seg_op['args']['segments']))")
    [ "$result" = "alpha| beta" ]
}

@test "anchor covering the whole segment leaves that segment alone" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {"code": true}}]'
    result=$(build "beta" "note" | probe "print('|'.join(s['text'] for s in seg_op['args']['segments']))")
    [ "$result" = "alpha |beta" ]
}

@test "discussion uuid on the anchor segment matches the created discussion" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build "beta" "note" | probe "
mid = [s for s in seg_op['args']['segments'] if s['text'] == 'beta'][0]
print(mid['discussions'] == [disc['args']['uuid']] == [r['discussion']])")
    [ "$result" = "True" ]
}

@test "splitting a link segment keeps the url on every part" {
    mkdoc '[{"text": "see the docs page", "type": 0, "enhancer": {}, "url": "https://example.com"}]'
    result=$(build "docs" "note" | probe "
segs = seg_op['args']['segments']
print(len(segs), all(s.get('url') == 'https://example.com' for s in segs))")
    [ "$result" = "3 True" ]
}

@test "anchor enhancer is inherited by the split parts" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {"bold": true}}]'
    result=$(build "beta" "note" | probe "print(all(s['enhancer'] == {'bold': True} for s in seg_op['args']['segments']))")
    [ "$result" = "True" ]
}

# ---- проверки перенарезки реально срабатывают -------------------------------

@test "resplit check catches a split that loses text" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build_broken "drop-tail" "beta")
    [[ "$result" == *"Текст блока изменился"* ]]
}

@test "resplit check catches a split that drops a segment field" {
    mkdoc '[{"text": "see the docs page", "type": 0, "enhancer": {}, "url": "https://example.com"}]'
    result=$(build_broken "drop-url" "docs")
    [[ "$result" == *"потеряла или изменила поля сегмента"* ]]
}

@test "resplit check catches a split that yields an empty segment" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {}}]'
    result=$(build_broken "insert-empty" "beta")
    [[ "$result" == *"пустой сегмент"* ]]
}

# ---- неоднозначность якоря --------------------------------------------------

@test "anchor occurring twice is rejected with both occurrences listed" {
    mkdoc '[{"text": "безлимитный тариф: лимит 100", "type": 0, "enhancer": {}}]'
    err=$(build_stderr "лимит" "note") || true
    [[ "$err" == *"встречается в блоке 2 раз(а)"* ]]
    [[ "$err" == *"--occurrence=N"* ]]
}

@test "occurrence selects the requested hit" {
    mkdoc '[{"text": "безлимитный тариф: лимит 100", "type": 0, "enhancer": {}}]'
    result=$(build "лимит" "note" --occurrence=2 | probe "print('|'.join(s['text'] for s in seg_op['args']['segments']))")
    [ "$result" = "безлимитный тариф: |лимит| 100" ]
}

@test "occurrence beyond the number of hits is rejected" {
    mkdoc '[{"text": "безлимитный тариф: лимит 100", "type": 0, "enhancer": {}}]'
    err=$(build_stderr "лимит" "note" --occurrence=3) || true
    [[ "$err" == *"Запрошено вхождение 3"* ]]
}

@test "occurrence counting follows visible text, not segment boundaries" {
    mkdoc '[{"text": "лимит и ", "type": 0, "enhancer": {}}, {"text": "лимит", "type": 0, "enhancer": {"code": true}}]'
    result=$(build "лимит" "note" --occurrence=2 | probe "
print('|'.join(s['text'] for s in seg_op['args']['segments']),
      [s.get('enhancer') for s in seg_op['args']['segments'] if s.get('discussions')])")
    [ "$result" = "лимит и |лимит [{'code': True}]" ]
}

# ---- отказы -----------------------------------------------------------------

@test "anchor crossing a segment boundary is rejected as split, not missing" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {"code": true}}]'
    err=$(build_stderr "alpha beta" "note") || true
    [[ "$err" == *"разорван границей сегментов"* ]]
    [[ "$err" == *"[0] «alpha »"* ]]
    [[ "$err" == *"[1] «beta» [code]"* ]]
}

@test "anchor crossing a boundary exits non-zero" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {"code": true}}]'
    status=0
    build "alpha beta" "note" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ]
}

@test "anchor absent from the block text is reported as missing" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    err=$(build_stderr "delta" "note") || true
    [[ "$err" == *"Якоря нет в тексте блока"* ]]
    [[ "$err" == *"alpha beta gamma"* ]]
}

@test "empty anchor is rejected" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    err=$(build_stderr "" "note") || true
    [[ "$err" == *"Якорь пустой"* ]]
}

@test "empty comment text is rejected" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    err=$(build_stderr "beta" "") || true
    [[ "$err" == *"Текст комментария пустой"* ]]
}

@test "block without segments is rejected with the segment listing" {
    mkdoc '[]'
    err=$(build_stderr "beta" "note") || true
    [[ "$err" == *"(сегментов нет)"* ]]
}

@test "unknown block id is reported with a hint about get-blocks" {
    mkdoc '[{"text": "alpha", "type": 0, "enhancer": {}}]'
    err=$(python3 "$OPS_PY" "$DOC" "44444444-4444-4444-4444-444444444444" "alpha" "note" "$NOW" "$USER" 2>&1 >/dev/null) || true
    [[ "$err" == *"не найден на странице"* ]]
    [[ "$err" == *"get-blocks"* ]]
}

@test "unknown flag is rejected" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    err=$(build_stderr "beta" "note" --nope) || true
    [[ "$err" == *"неизвестный флаг"* ]]
}

@test "doc json is accepted on stdin" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    result=$(python3 "$OPS_PY" - "$BLOCK" "beta" "note" "$NOW" "$USER" < "$DOC" 2>/dev/null | probe "print(len(ops))")
    [ "$result" = "5" ]
}
