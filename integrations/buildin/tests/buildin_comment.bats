#!/usr/bin/env bats
# Unit tests for buildin-comment.py — anchor lookup and the text invariant.
#
# Поиск якоря и перенарезка сегментов — единственное место команды `comment`,
# где ошибка тихая: тред привяжется не к той фразе или молча испортит текст
# блока. Поэтому здесь чистая функция без сети: doc-фикстура на вход, операции
# транзакции на выход.

BLOCK=11111111-1111-4111-8111-111111111111
SPACE=22222222-2222-4222-8222-222222222222
USER=33333333-3333-4333-8333-333333333333
NOW=1700000000000

setup() {
    OPS_PY="$BATS_TEST_DIRNAME/../scripts/buildin-comment.py"
    DOC="$BATS_TEST_TMPDIR/doc.json"
}

# Документ-фикстура: один блок с заданными сегментами.
# $1 — segments (JSON), $2 — discussions блока (JSON, по умолчанию пусто.)
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

# Операции транзакции на stdout; служебный вывод билдера в stderr не мешает.
ops() { # $1=anchor $2=text [extra args...]
    local anchor="$1" text="$2"; shift 2
    python3 "$OPS_PY" "$DOC" "$BLOCK" "$anchor" "$text" "$NOW" "$USER" "$@" 2>/dev/null
}

# stderr упавшего запуска; пустая строка, если запуск внезапно успешен.
ops_stderr() { # $1=anchor $2=text
    python3 "$OPS_PY" "$DOC" "$BLOCK" "$1" "$2" "$NOW" "$USER" 2>&1 >/dev/null
}

# Выражение python над операциями: $1 — код, печатающий результат.
probe() {
    python3 -c "
import json, sys
ops = json.load(sys.stdin)
disc, comment, block = ops
$1" 
}

@test "anchor inside one segment yields three ops: discussion, comment, block update" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(ops "beta" "note" | probe "print(len(ops), disc['table'], comment['table'], block['table'], block['command'])")
    [ "$result" = "3 discussion comment block update" ]
}

@test "block text is byte-identical after the anchor is split out" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {"bold": true}}, {"text": "beta gamma", "type": 0, "enhancer": {}}]'
    result=$(ops "beta" "note" | probe "print(''.join(s['text'] for s in block['args']['data']['segments']))")
    [ "$result" = "alpha beta gamma" ]
}

@test "anchor is split into its own segment with before and after kept" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(ops "beta" "note" | probe "print('|'.join(s['text'] for s in block['args']['data']['segments']))")
    [ "$result" = "alpha |beta| gamma" ]
}

@test "anchor at segment start produces no empty leading segment" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    result=$(ops "alpha" "note" | probe "print('|'.join(s['text'] for s in block['args']['data']['segments']))")
    [ "$result" = "alpha| beta" ]
}

@test "anchor covering the whole segment leaves that segment alone" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {"code": true}}]'
    result=$(ops "beta" "note" | probe "print('|'.join(s['text'] for s in block['args']['data']['segments']))")
    [ "$result" = "alpha |beta" ]
}

@test "discussion uuid on the anchor segment matches the created discussion" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(ops "beta" "note" | probe "
mid = [s for s in block['args']['data']['segments'] if s['text'] == 'beta'][0]
print(mid['discussions'] == [disc['args']['uuid']] == [disc['id']])")
    [ "$result" = "True" ]
}

@test "splitting a link segment keeps the url on every part" {
    mkdoc '[{"text": "see the docs page", "type": 0, "enhancer": {}, "url": "https://example.com"}]'
    result=$(ops "docs" "note" | probe "
segs = block['args']['data']['segments']
print(len(segs), all(s.get('url') == 'https://example.com' for s in segs))")
    [ "$result" = "3 True" ]
}

@test "anchor enhancer is inherited by the split parts" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {"bold": true}}]'
    result=$(ops "beta" "note" | probe "print(all(s['enhancer'] == {'bold': True} for s in block['args']['data']['segments']))")
    [ "$result" = "True" ]
}

@test "anchor crossing a segment boundary is rejected as split, not missing" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {"code": true}}]'
    err=$(ops_stderr "alpha beta" "note") || true
    [[ "$err" == *"разорван границей сегментов"* ]]
    [[ "$err" == *"[0] «alpha »"* ]]
    [[ "$err" == *"[1] «beta» [code]"* ]]
}

@test "anchor crossing a boundary exits non-zero" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {"code": true}}]'
    status=0
    ops "alpha beta" "note" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ]
}

@test "anchor absent from the block text is reported as missing" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    err=$(ops_stderr "delta" "note") || true
    [[ "$err" == *"Якоря нет в тексте блока"* ]]
    [[ "$err" == *"alpha beta gamma"* ]]
}

@test "empty anchor is rejected" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    err=$(ops_stderr "" "note") || true
    [[ "$err" == *"Якорь пустой"* ]]
}

@test "block without segments is rejected with the segment listing" {
    mkdoc '[]'
    err=$(ops_stderr "beta" "note") || true
    [[ "$err" == *"(сегментов нет)"* ]]
}

@test "unknown block id is reported with a hint about get-blocks" {
    mkdoc '[{"text": "alpha", "type": 0, "enhancer": {}}]'
    err=$(python3 "$OPS_PY" "$DOC" "44444444-4444-4444-4444-444444444444" "alpha" "note" "$NOW" "$USER" 2>&1 >/dev/null) || true
    [[ "$err" == *"не найден на странице"* ]]
    [[ "$err" == *"get-blocks"* ]]
}

@test "existing block discussions are appended to, not replaced" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]' '["99999999-9999-4999-8999-999999999999"]'
    result=$(ops "beta" "note" | probe "
d = block['args']['discussions']
print(len(d), d[0], d[1] == disc['id'])")
    [ "$result" = "2 99999999-9999-4999-8999-999999999999 True" ]
}

@test "discussion carries the anchor as context and targets the block" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    result=$(ops "beta" "note" | probe "
a = disc['args']
print(a['parentId'] == '$BLOCK', a['context'][0]['text'], a['spaceId'] == '$SPACE', a['resolved'])")
    [ "$result" = "True beta True False" ]
}

@test "comment carries the text and hangs on the discussion" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    result=$(ops "beta" "нужен пример" | probe "
a = comment['args']
print(a['parentId'] == disc['id'], a['text'][0]['text'], disc['args']['comments'] == [a['uuid']])")
    [ "$result" = "True нужен пример True" ]
}

@test "rollback file holds the pre-change data and discussions as a ready request" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]' '["99999999-9999-4999-8999-999999999999"]'
    rb="$BATS_TEST_TMPDIR/rollback.json"
    ops "beta" "note" --rollback-out "$rb" >/dev/null
    result=$(python3 -c "
import json
b = json.load(open('$rb'))
op = b['transactions'][0]['operations'][0]
print(b['transactions'][0]['spaceId'] == '$SPACE',
      op['id'] == '$BLOCK',
      ''.join(s['text'] for s in op['args']['data']['segments']),
      len(op['args']['data']['segments']),
      op['args']['discussions'])")
    [ "$result" = "True True alpha beta 1 ['99999999-9999-4999-8999-999999999999']" ]
}

@test "doc json is accepted on stdin" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    result=$(python3 "$OPS_PY" - "$BLOCK" "beta" "note" "$NOW" "$USER" < "$DOC" 2>/dev/null \
        | probe "print(len(ops))")
    [ "$result" = "3" ]
}
