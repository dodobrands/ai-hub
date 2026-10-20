#!/usr/bin/env bats
# Unit tests for buildin-comment.py — block- and segment-type guards, anchor lookup, resplit checks,
# thread operations.
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
# $1 — segments (JSON), $2 — discussions блока (JSON, по умолчанию пусто),
# $3 — тип блока (по умолчанию 1 = абзац, который гард по типу пропускает).
mkdoc() {
    python3 - "$BLOCK" "$SPACE" "$1" "${2:-[]}" "${3:-1}" > "$DOC" <<'PY'
import json, sys
block_id, space_id, segments, discussions, btype = sys.argv[1:6]
print(json.dumps({"data": {"blocks": {block_id: {
    "uuid": block_id,
    "spaceId": space_id,
    "type": int(btype),
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
elif how == "extra-segments":
    # текст сохраняем, но дробим хвост — меняется только ЧИСЛО сегментов
    def broken(s, i, p, a, d):
        out = orig(s, i, p, a, d)
        tail = out[i + 2]
        out[i + 2:i + 3] = [dict(tail, text=tail["text"][:1]), dict(tail, text=tail["text"][1:])]
        return out
    bc.split_segments = broken
elif how == "tag-neighbor":
    # тред вешается ещё и на соседний кусок разреза
    def broken(s, i, p, a, d):
        out = orig(s, i, p, a, d)
        out[i]["discussions"] = [d]
        return out
    bc.split_segments = broken
elif how == "touch-neighbor":
    # сегмент ВНЕ разреза меняется, текст при этом целый
    def broken(s, i, p, a, d):
        out = orig(s, i, p, a, d)
        out[-1] = dict(out[-1], enhancer={"bold": True})
        return out
    bc.split_segments = broken
elif how == "touch-left-neighbor":
    # то же, но СЛЕВА: правую половину условия соседей ломает touch-neighbor,
    # левую — только эта поломка, и только если якорь не в первом сегменте
    def broken(s, i, p, a, d):
        out = orig(s, i, p, a, d)
        out[0] = dict(out[0], enhancer={"bold": True})
        return out
    bc.split_segments = broken
elif how == "drop-threads":
    # разрез теряет треды, которые уже висели на разрезаемом сегменте
    def broken(s, i, p, a, d):
        out = orig(s, i, p, a, d)
        for x in out[i:i + 3]:
            x["discussions"] = [t for t in (x.get("discussions") or []) if t == d]
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

@test "with --page the page is touched like the UI does, right before the block" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build "beta" "note" "--page=55555555-5555-4555-8555-555555555555" | python3 -c "
import json, sys
ops = json.load(sys.stdin)['ops']
print(len(ops), [(o['id'][:8], o['command'], o['path']) for o in ops[-2:]], sorted(ops[-2]['args']))")
    [ "$result" = "6 [('55555555', 'update', []), ('11111111', 'update', [])] ['updatedAt', 'updatedBy']" ]
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
    [[ "$err" == *"встречается в блоке 2 раз(а)"* ]] || false
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
    [[ "$err" == *"разорван границей сегментов"* ]] || false
    [[ "$err" == *"[0] «alpha »"* ]] || false
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
    [[ "$err" == *"Якоря нет в тексте блока"* ]] || false
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
    [[ "$err" == *"не найден на странице"* ]] || false
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

@test "resplit check catches a split that changes the segment count" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build_broken "extra-segments" "beta")
    [[ "$result" == *"изменила число сегментов"* ]]
}

@test "resplit check catches a split that tags more than one part" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build_broken "tag-neighbor" "beta")
    [[ "$result" == *"ровно на одном новом сегменте"* ]]
}

@test "resplit check catches a split that touches a neighbouring segment" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}, {"text": " tail", "type": 0, "enhancer": {}}]'
    result=$(build_broken "touch-neighbor" "beta")
    [[ "$result" == *"задела соседние сегменты"* ]]
}

# ---- неоднозначность: перекрывающиеся вхождения ------------------------------

@test "overlapping occurrences count as ambiguous" {
    mkdoc '[{"text": "банана", "type": 0, "enhancer": {}}]'
    err=$(build_stderr "ана" "note") || true
    [[ "$err" == *"встречается в блоке 2 раз(а)"* ]]
}

@test "overlapping occurrence is selectable" {
    mkdoc '[{"text": "банана", "type": 0, "enhancer": {}}]'
    result=$(build "ана" "note" --occurrence=2 | probe "print('|'.join(s['text'] for s in seg_op['args']['segments']))")
    [ "$result" = "бан|ана" ]
}

# ---- значения с ведущими дефисами -------------------------------------------

@test "values starting with dashes survive after the end-of-options marker" {
    mkdoc '[{"text": "флаг --force включает режим", "type": 0, "enhancer": {}}]'
    result=$(python3 "$OPS_PY" -- "$DOC" "$BLOCK" "--force" "-- не согласен" "$NOW" "$USER" 2>/dev/null \
        | probe "print('|'.join(s['text'] for s in seg_op['args']['segments']), repr(comment['args']['text'][0]['text']))")
    [ "$result" = "флаг |--force| включает режим '-- не согласен'" ]
}

@test "a mode flag with a value is rejected, not taken for the mode" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    err=$(python3 "$OPS_PY" --verdict=yes -- "$DOC" "$DOC" "$BLOCK" "x" 2>&1 >/dev/null) || true
    [[ "$err" == *"неизвестный флаг: --verdict=yes"* ]]
}

@test "unknown flag before the marker is still rejected" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    err=$(python3 "$OPS_PY" --nope -- "$DOC" "$BLOCK" "beta" "note" "$NOW" "$USER" 2>&1 >/dev/null) || true
    [[ "$err" == *"неизвестный флаг: --nope"* ]]
}

# ---- узкий откат для проигравшего гонку --------------------------------------

@test "records-only rollback carries no segment write" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    result=$(build "beta" "note" | probe "
rec = r['rollback_records']
print([(o['command'], o['table']) for o in rec] ==
      [('listRemove','block'),('update','comment'),('update','discussion'),('update','block')],
      any(o.get('path') == ['data'] for o in rec),
      rec[0]['args']['uuid'] == r['discussion'])")
    [ "$result" = "True False True" ]
}

# --- гард по типу блока -----------------------------------------------------
#
# Третий тихий провал рядом с разрывом границы и неоднозначностью: у картинки
# якорь по имени файла НАХОДИТСЯ, запись проходит, и сверка после записи
# довольна — сегмент реально несёт discussions. Отсюда и проверка порядка:
# поймать это можно только ДО поиска якоря.

@test "every whitelisted prose type is accepted" {
    for t in 1 3 4 5 6 7 12 13 38; do
        mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]' '[]' "$t"
        build "beta" "note" >/dev/null || { echo "prose type $t was refused"; return 1; }
    done
}

@test "every refused type is rejected by type, not by anchor" {
    for t in 0 9 14 21 23 25 27 28; do
        mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]' '[]' "$t"
        err=$(build_stderr "beta" "note") || true
        [[ "$err" == *"Блок типа $t"* ]] || { echo "type $t got: $err"; return 1; }
    done
}

@test "image block is refused and its segments are shown to be the file name" {
    mkdoc '[{"text": "picture.png", "type": 0, "enhancer": {}}]' '[]' 14
    err=$(build_stderr "picture" "note") || true
    [[ "$err" == *"Блок типа 14 (картинка)"* ]] || false
    [[ "$err" == *"имя файла"* ]] || false
    [[ "$err" == *"picture.png"* ]]
}

@test "image block refusal exits non-zero" {
    mkdoc '[{"text": "picture.png", "type": 0, "enhancer": {}}]' '[]' 14
    status=0
    build "picture" "note" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ]
}

@test "table and its rows are refused by naming collectionProperties" {
    for t in 27 28; do
        mkdoc '[]' '[]' "$t"
        err=$(build_stderr "cell" "note") || true
        [[ "$err" == *"collectionProperties"* ]] || { echo "type $t got: $err"; return 1; }
        [[ "$err" == *"не сработает в принципе"* ]] || { echo "type $t got: $err"; return 1; }
    done
}

@test "code and page title are refused for the missing highlight, not for hidden text" {
    for t in 0 25; do
        mkdoc '[{"text": "return block_type in ALLOWED", "type": 0, "enhancer": {}}]' '[]' "$t"
        err=$(build_stderr "block_type in ALLOWED" "note") || true
        [[ "$err" == *"не подсветится"* ]] || { echo "type $t got: $err"; return 1; }
    done
}

@test "unknown block type is refused so a new Buildin type cannot slip through" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]' '[]' 99
    err=$(build_stderr "beta" "note") || true
    [[ "$err" == *"Блок типа 99 команде неизвестен"* ]] || false
    [[ "$err" == *"PROSE_TYPES"* ]]
}

@test "type guard runs before the anchor lookup" {
    mkdoc '[{"text": "picture.png", "type": 0, "enhancer": {}}]' '[]' 14
    err=$(build_stderr "no-such-anchor" "note") || true
    [[ "$err" == *"Блок типа 14"* ]] || false
    [[ "$err" != *"Якоря нет в тексте блока"* ]]
}

@test "whitelist and refusal map do not overlap" {
    run python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('bc', sys.argv[1])
bc = importlib.util.module_from_spec(spec); spec.loader.exec_module(bc)
both = set(bc.PROSE_TYPES) & set(bc.REFUSED_TYPES)
print('overlap:', sorted(both))
sys.exit(1 if both else 0)
" "$OPS_PY"
    [ "$status" -eq 0 ]
}

# --- гард по типу сегмента ---------------------------------------------------
#
# Тот же тихий провал уровнем ниже: разрез инлайн-формулы проходит, сверка
# после записи довольна, а на странице вместо формулы ошибки разбора. Проверено
# живьём: x^{2} по «{2» превратилась в три формулы, все три — ошибка разбора.

FORMULA='[{"text": "Формула: ", "type": 0, "enhancer": {}}, {"text": "x^{2}", "type": 8, "enhancer": {}}, {"text": " конец", "type": 0, "enhancer": {}}]'
DATE='[{"text": "срок: ", "type": 0, "enhancer": {}}, {"text": "‣", "type": 1, "enhancer": {}, "startDate": "2026/10/16", "startTime": "14:30"}]'

@test "anchor inside an inline equation is refused" {
    mkdoc "$FORMULA"
    err=$(build_stderr "{2" "note") || true
    [[ "$err" == *"Якорь режет сегмент [1] (инлайн-формула)"* ]] || false
    [[ "$err" == *"только целиком — якорем «x^{2}»"* ]]
}

@test "whole inline equation is commented without a cut" {
    mkdoc "$FORMULA"
    result=$(build "x^{2}" "note" | probe "
segs = seg_op['args']['segments']
print(len(segs), segs[1]['type'], segs[1]['text'], segs[1]['discussions'] == [r['discussion']])")
    [ "$result" = "3 8 x^{2} True" ]
}

@test "date chip is commented whole by its placeholder" {
    mkdoc "$DATE"
    result=$(build "‣" "note" | probe "
segs = seg_op['args']['segments']
print(len(segs), segs[1]['type'], segs[1]['startDate'], segs[1]['discussions'] == [r['discussion']])")
    [ "$result" = "2 1 2026/10/16 True" ]
}

@test "real link segment is still cut with the url on every part" {
    mkdoc '[{"text": "see the docs page", "type": 3, "enhancer": {}, "url": "https://example.com"}]'
    result=$(build "docs" "note" | probe "
segs = seg_op['args']['segments']
print(len(segs), all(s['type'] == 3 and s['url'] == 'https://example.com' for s in segs))")
    [ "$result" = "3 True" ]
}

@test "unknown segment type is refused so a new inline object cannot be cut" {
    mkdoc '[{"text": "alpha beta", "type": 99, "enhancer": {}}]'
    err=$(build_stderr "beta" "note") || true
    [[ "$err" == *"сегмент [0] типа 99"* ]] || false
    [[ "$err" == *"CUTTABLE_SEGMENTS"* ]]
}

@test "unknown segment type is refused even when taken whole" {
    mkdoc '[{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 99, "enhancer": {}}]'
    err=$(build_stderr "beta" "note") || true
    [[ "$err" == *"сегмент [1] типа 99"* ]]
}

@test "segment without a type is refused" {
    mkdoc '[{"text": "alpha beta", "enhancer": {}}]'
    err=$(build_stderr "beta" "note") || true
    [[ "$err" == *"сегмент [0] без типа"* ]]
}

@test "missing anchor listing names the date and the mention by kind" {
    mkdoc '[{"text": "срок ", "type": 0, "enhancer": {}}, {"text": "‣", "type": 1, "enhancer": {}, "startDate": "2026/10/16", "startTime": "14:30"}, {"text": "", "type": 7, "enhancer": {}, "uuid": "55555555-5555-4555-8555-555555555555"}]'
    err=$(build_stderr "16 октября" "note") || true
    [[ "$err" == *"[1] «‣» [дата 2026/10/16 14:30]"* ]] || false
    [[ "$err" == *"[2] «» [упоминание человека]"* ]]
}

@test "cuttable and whole-only segment types do not overlap" {
    run python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('bc', sys.argv[1])
bc = importlib.util.module_from_spec(spec); spec.loader.exec_module(bc)
both = set(bc.CUTTABLE_SEGMENTS) & set(bc.WHOLE_SEGMENTS)
print('overlap:', sorted(both))
sys.exit(1 if both else 0)
" "$OPS_PY"
    [ "$status" -eq 0 ]
}

@test "resplit check catches a split that touches the segment before the anchor" {
    mkdoc '[{"text": "head ", "type": 0, "enhancer": {}}, {"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build_broken "touch-left-neighbor" "beta")
    [[ "$result" == *"задела соседние сегменты"* ]]
}

@test "threads already on the segment survive the split" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}, "discussions": ["88888888-8888-4888-8888-888888888888"]}]'
    result=$(build "beta" "note" | probe "
segs = seg_op['args']['segments']
old = '88888888-8888-4888-8888-888888888888'
print(all(old in (s.get('discussions') or []) for s in segs),
      sorted(x for s in segs for x in (s.get('discussions') or []) if x != old) == [r['discussion']])")
    [ "$result" = "True True" ]
}

@test "resplit check catches a split that drops pre-existing threads" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}, "discussions": ["88888888-8888-4888-8888-888888888888"]}]'
    result=$(build_broken "drop-threads" "beta")
    [[ "$result" == *"потеряла треды, уже висевшие на сегменте"* ]]
}

# ---- вердикт исхода записи ---------------------------------------------------

# Состояние блока файлом: $1 — треды в списке, $2 — треды с подсветкой.
mkstate() {
    python3 -c "
import json, sys
block_id, listed, lit = sys.argv[1:4]
lit = json.loads(lit)
seg = {'text': 'alpha beta', 'type': 0, 'enhancer': {}}
if lit:
    seg['discussions'] = lit
print(json.dumps({'data': {'blocks': {block_id: {
    'uuid': block_id, 'discussions': json.loads(listed),
    'data': {'segments': [seg]}}}}}))
" "$BLOCK" "$1" "$2"
}

verdict() { python3 "$OPS_PY" --verdict -- "$1" "$2" "$BLOCK" "ours"; }

@test "verdict: highlighted thread is a success" {
    mkstate '[]' '[]' > "$BATS_TEST_TMPDIR/b.json"
    mkstate '["ours"]' '["ours"]' > "$BATS_TEST_TMPDIR/a.json"
    result=$(verdict "$BATS_TEST_TMPDIR/b.json" "$BATS_TEST_TMPDIR/a.json" | tr '\n' '|')
    [ "$result" = "ok||" ]
}

@test "verdict: error envelope is unverified, not a lost race" {
    mkstate '[]' '[]' > "$BATS_TEST_TMPDIR/b.json"
    printf '{"code":500,"msg":"no rights"}' > "$BATS_TEST_TMPDIR/a.json"
    [ "$(verdict "$BATS_TEST_TMPDIR/b.json" "$BATS_TEST_TMPDIR/a.json" | head -1)" = "unverified" ]
}

@test "verdict: non-json body is unverified" {
    mkstate '[]' '[]' > "$BATS_TEST_TMPDIR/b.json"
    printf 'upstream timeout' > "$BATS_TEST_TMPDIR/a.json"
    [ "$(verdict "$BATS_TEST_TMPDIR/b.json" "$BATS_TEST_TMPDIR/a.json" | head -1)" = "unverified" ]
}

@test "verdict: thread missing from the block list means the write did not apply" {
    mkstate '[]' '[]' > "$BATS_TEST_TMPDIR/b.json"
    mkstate '[]' '[]' > "$BATS_TEST_TMPDIR/a.json"
    [ "$(verdict "$BATS_TEST_TMPDIR/b.json" "$BATS_TEST_TMPDIR/a.json" | head -1)" = "not-applied" ]
}

@test "verdict: listed but unlit thread is a lost race" {
    mkstate '[]' '[]' > "$BATS_TEST_TMPDIR/b.json"
    mkstate '["ours"]' '[]' > "$BATS_TEST_TMPDIR/a.json"
    [ "$(verdict "$BATS_TEST_TMPDIR/b.json" "$BATS_TEST_TMPDIR/a.json" | head -1)" = "lost-ours" ]
}

@test "verdict: a thread that lost its highlight is named" {
    mkstate '[]' '[]' > "$BATS_TEST_TMPDIR/b.json"
    mkstate '["ours","theirs"]' '["ours"]' > "$BATS_TEST_TMPDIR/a.json"
    result=$(verdict "$BATS_TEST_TMPDIR/b.json" "$BATS_TEST_TMPDIR/a.json" | tr '\n' '|')
    [ "$result" = "ok|theirs|" ]
}

@test "verdict: a thread orphaned before the run is not blamed on us" {
    mkstate '["theirs"]' '[]' > "$BATS_TEST_TMPDIR/b.json"
    mkstate '["theirs","ours"]' '["ours"]' > "$BATS_TEST_TMPDIR/a.json"
    result=$(verdict "$BATS_TEST_TMPDIR/b.json" "$BATS_TEST_TMPDIR/a.json" | tr '\n' '|')
    [ "$result" = "ok||" ]
}

# ---- резолв треда -----------------------------------------------------------

THREAD=66666666-6666-4666-8666-666666666666

# Документ с тредом: $1 — resolved (true|false), $2 — status треда (по умолчанию 1).
mkthread() {
    python3 - "$THREAD" "$SPACE" "$BLOCK" "$1" "${2:-1}" > "$DOC" <<'PY'
import json, sys
thread, space, block, resolved, status = sys.argv[1:6]
print(json.dumps({"data": {"discussions": {thread: {
    "uuid": thread, "spaceId": space, "parentId": block, "status": int(status),
    "resolved": resolved == "true", "comments": ["77777777-7777-4777-8777-777777777777"]}}}}))
PY
}

resolve() { python3 "$OPS_PY" --resolve="$1" -- "$DOC" "$THREAD" 2>/dev/null; }
resolve_stderr() { python3 "$OPS_PY" --resolve="$1" -- "$DOC" "$THREAD" 2>&1 >/dev/null; }
resolve_ops() { resolve "$1" | python3 -c "import json, sys; print(json.load(sys.stdin)['ops'])"; }

@test "resolve is one narrow write of the resolved flag, exactly as the UI sends it" {
    mkthread false
    result=$(resolve true | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(r['ops'] == [{'id': '$THREAD', 'command': 'update', 'table': 'discussion',
                    'path': [], 'args': {'resolved': True}}], r['space'] == '$SPACE')")
    [ "$result" = "True True" ]
}

@test "unresolve writes the flag back to false" {
    mkthread true
    [ "$(resolve_ops false)" = "[{'id': '$THREAD', 'command': 'update', 'table': 'discussion', 'path': [], 'args': {'resolved': False}}]" ]
}

@test "a thread already in the target state gets no write" {
    mkthread true
    [ "$(resolve_ops true)" = "[]" ]
    mkthread false
    [ "$(resolve_ops false)" = "[]" ]
}

@test "thread missing from the page is refused with a hint about comments" {
    mkdoc '[{"text": "alpha", "type": 0, "enhancer": {}}]'
    err=$(resolve_stderr true) || true
    [[ "$err" == *"Треда $THREAD на странице нет"* ]] || false
    [[ "$err" == *"buildin-pages.sh comments"* ]]
}

@test "deleted thread is refused" {
    mkthread false -1
    err=$(resolve_stderr true) || true
    [[ "$err" == *"Тред $THREAD удалён"* ]]
}

@test "resolve flag value other than true or false is rejected" {
    mkthread false
    err=$(python3 "$OPS_PY" --resolve=yes -- "$DOC" "$THREAD" 2>&1 >/dev/null) || true
    [[ "$err" == *"--resolve ожидает true или false"* ]]
}

resolve_verdict() { python3 "$OPS_PY" --resolve-verdict="$2" -- "$1" "$THREAD"; }

@test "resolve verdict: flag in place is ok, unchanged flag is not-applied" {
    mkthread true
    [ "$(resolve_verdict "$DOC" true)" = "ok" ]
    [ "$(resolve_verdict "$DOC" false)" = "not-applied" ]
}

@test "resolve verdict: error envelope or missing thread is unverified" {
    printf '{"code":500,"msg":"no rights"}' > "$BATS_TEST_TMPDIR/a.json"
    [ "$(resolve_verdict "$BATS_TEST_TMPDIR/a.json" true)" = "unverified" ]
    mkdoc '[{"text": "alpha", "type": 0, "enhancer": {}}]'
    [ "$(resolve_verdict "$DOC" true)" = "unverified" ]
}

# ---- ответ в тред -----------------------------------------------------------

reply() { # $1=text [flags...]
    local text="$1"; shift
    python3 "$OPS_PY" --reply "$@" -- "$DOC" "$THREAD" "$text" "$NOW" "$USER" 2>/dev/null
}
reply_stderr() { python3 "$OPS_PY" --reply -- "$DOC" "$THREAD" "$1" "$NOW" "$USER" 2>&1 >/dev/null; }

@test "reply is a comment record plus a list op on the thread, exactly as the UI sends it" {
    mkthread false
    result=$(reply "ответ" | python3 -c "
import json, sys
r = json.load(sys.stdin)
rec, lst = r['ops']
print(len(r['ops']), rec['command'], rec['table'], rec['args']['parentId'] == '$THREAD',
      rec['args']['text'], lst['command'], lst['table'], lst['path'], lst['args'] == {'uuid': r['comment']})")
    [ "$result" = "2 set comment True [{'text': 'ответ', 'type': 0, 'enhancer': {}}] listAfter discussion ['comments'] True" ]
}

@test "reply record has the same shape as the first message of a new thread" {
    mkthread false
    reply "ответ" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['ops'][0]['args']))" > "$BATS_TEST_TMPDIR/reply.json"
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    build "beta" "ответ" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['ops'][1]['args']))" > "$BATS_TEST_TMPDIR/first.json"
    run python3 -c "
import json, sys
a, b = ({k: v for k, v in json.load(open(p)).items() if k not in ('uuid', 'parentId')} for p in sys.argv[1:3])
print(a, b)
sys.exit(0 if a == b else 1)
" "$BATS_TEST_TMPDIR/reply.json" "$BATS_TEST_TMPDIR/first.json"
    [ "$status" -eq 0 ]
}

@test "reply rollback takes the message out of the thread and retires it" {
    mkthread false
    result=$(reply "ответ" | python3 -c "
import json, sys
r = json.load(sys.stdin)
rb = r['rollback']
print([(o['command'], o['table'], o['path']) for o in rb],
      rb[0]['args'] == {'uuid': r['comment']}, rb[1]['id'] == r['comment'], rb[1]['args']['status'])")
    [ "$result" = "[('listRemove', 'discussion', ['comments']), ('update', 'comment', [])] True True -1" ]
}

@test "reply into a resolved thread is refused with a hint to reopen it" {
    mkthread true
    err=$(reply_stderr "ответ") || true
    [[ "$err" == *"Тред $THREAD закрыт"* ]] || false
    [[ "$err" == *"comment-unresolve"* ]]
}

@test "reply to a thread missing from the page is refused" {
    mkdoc '[{"text": "alpha", "type": 0, "enhancer": {}}]'
    err=$(reply_stderr "ответ") || true
    [[ "$err" == *"Треда $THREAD на странице нет"* ]]
}

@test "empty reply text is refused" {
    mkthread false
    err=$(reply_stderr "") || true
    [[ "$err" == *"Текст ответа пустой"* ]]
}

reply_verdict() { python3 "$OPS_PY" --reply-verdict -- "$1" "$THREAD" "$2"; }

@test "reply verdict: our message in the thread is ok, an absent one is not-applied" {
    mkthread false
    [ "$(reply_verdict "$DOC" 77777777-7777-4777-8777-777777777777)" = "ok" ]
    [ "$(reply_verdict "$DOC" 88888888-8888-4888-8888-888888888888)" = "not-applied" ]
}

@test "reply verdict: error envelope or missing thread is unverified" {
    printf '{"code":500,"msg":"no rights"}' > "$BATS_TEST_TMPDIR/a.json"
    [ "$(reply_verdict "$BATS_TEST_TMPDIR/a.json" 77777777-7777-4777-8777-777777777777)" = "unverified" ]
}

# ---- проверка файла отката --------------------------------------------------

# Файл отката из массива операций $1 — тем же конвертом, что пишет команда.
mkrollback() { # $1 — операции, $2 — сверка check (необязательна)
    python3 -c "
import json, sys
body = {'requestId': 'r', 'transactions': [
    {'id': 't', 'spaceId': sys.argv[2], 'operations': json.loads(sys.argv[1])}]}
if sys.argv[3]:
    body['check'] = json.loads(sys.argv[3])
print(json.dumps(body))
" "$1" "$SPACE" "${2:-}" > "$BATS_TEST_TMPDIR/rb.json"
}
check_rb() { python3 "$OPS_PY" --check-rollback -- "$BATS_TEST_TMPDIR/rb.json"; }

@test "rollback files of comment and comment-reply pass the check unchanged" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    built=$(build "beta" "note")
    ops=$(echo "$built" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['rollback']))")
    after=$(echo "$built" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['check']['segments']))")
    mkrollback "$ops" "{\"page\": \"55555555-5555-4555-8555-555555555555\", \"block\": \"$BLOCK\", \"segments\": $after}"
    [ "$(check_rb | python3 -c "import json, sys; r = json.load(sys.stdin); print(r['space'], json.dumps(r['ops']))")" = "$SPACE $ops" ]
    mkthread false
    ops=$(reply "ответ" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['rollback']))")
    mkrollback "$ops"
    [ "$(check_rb | python3 -c "import json, sys; r = json.load(sys.stdin); print(r['space'], json.dumps(r['ops']))")" = "$SPACE $ops" ]
}

@test "anything but rollback operations of the comment commands is refused with the reason" {
    run python3 - "$OPS_PY" "$BATS_TEST_TMPDIR" "$BLOCK" "$SPACE" <<'PY'
import json, subprocess, sys
ops_py, tmp, block, space = sys.argv[1:5]
d = "66666666-6666-4666-8666-666666666666"
def tx(ops, space=space):
    return {"requestId": "r", "transactions": [{"id": "t", "spaceId": space, "operations": ops}]}
ok_op = {"id": block, "command": "update", "table": "block", "path": [], "args": {}}
page = "55555555-5555-4555-8555-555555555555"
def data_op(bid, text):
    return {"id": bid, "command": "update", "table": "block", "path": ["data"],
            "args": {"segments": [{"text": text, "type": 0, "enhancer": {}}]}}
def check(bid, text):
    return {"page": page, "block": bid, "segments": [{"text": t, "type": 0, "enhancer": {}} for t in text.split("|")]}
# Части настоящего отката comment: тред d на блоке block, сообщение c.
c, other_d, other_c = "88888888-8888-4888-8888-888888888881", "66666666-0000-4000-8000-0000000000d2", "88888888-0000-4000-8000-0000000000c2"
def retire(table, rid):
    return {"id": rid, "command": "update", "table": table, "path": [], "args": {"status": -1}}
def unlist_thread(bid, did):
    return {"id": bid, "command": "listRemove", "table": "block", "path": ["discussions"], "args": {"uuid": did}}
def unlist_reply(did, cid):
    return {"id": did, "command": "listRemove", "table": "discussion", "path": ["comments"], "args": {"uuid": cid}}
records = [unlist_thread(block, d), retire("comment", c), retire("discussion", d), ok_op]
link = lambda url, ds=None: dict({"text": "beta", "type": 3, "url": url, "enhancer": {}}, **({"discussions": ds} if ds else {}))
plain = {"text": "alpha ", "type": 0, "enhancer": {}}
after_link = {"page": page, "block": block, "segments": [plain, link("https://good.example", [d])]}
def restore(segs):
    return {"id": block, "command": "update", "table": "block", "path": ["data"], "args": {"segments": segs}}
cases = [
    ({"requestId": "r"}, "нет ровно одной транзакции"),
    ({"transactions": tx([ok_op])["transactions"] * 2}, "нет ровно одной транзакции"),
    (tx([ok_op], space=""), "нет spaceId"),
    (tx([]), "нет операций"),
    (tx(["op"]), "не объект"),
    (tx([dict(ok_op, id="not-a-uuid")]), "id не UUID"),
    (tx([dict(ok_op, args="x")]), "args не объект"),
    (tx([dict(ok_op, command="set")]), "в откате не бывает"),
    (tx([{"id": block, "command": "listRemove", "table": "block", "path": ["subNodes"], "args": {"uuid": d}}]),
     "listRemove не из списка"),
    (tx([{"id": block, "command": "listRemove", "table": "block", "path": ["discussions"], "args": {}}]),
     "listRemove без uuid"),
    (tx([{"id": d, "command": "update", "table": "discussion", "path": ["data"], "args": {"segments": []}}]),
     "не возврат segments"),
    (tx([dict(ok_op, table="space")]), "update таблицы space"),
    (tx([{"id": d, "command": "update", "table": "discussion", "path": [], "args": {"resolved": False}}]),
     "не только status"),
    (tx([{"id": d, "command": "update", "table": "discussion", "path": [], "args": {"status": 1}}]),
     "только гасит"),
    (dict(tx([ok_op]), check={"page": "x"}), "check не по формату"),
    (dict(tx([ok_op]), check={"page": page, "block": block}), "check не по формату"),
    (dict(tx([ok_op]), check={"page": page, "segments": []}), "check не по формату"),
    # подложенные файлы: архивация страницы и чужой текст в блок
    (tx([dict(ok_op, args={"status": -1})]), "update блока меняет не только метки времени"),
    (tx([dict(ok_op, args={"title": "x"})]), "update блока меняет не только метки времени"),
    (tx([data_op(block, "alpha beta")]), "без сверки"),
    (dict(tx([data_op(d, "alpha beta")]), check=check(block, "alpha beta")), "сегменты возвращаются блоку"),
    # подложенные файлы второго круга ревью: из разрешённых операций собрано чужое
    (tx([unlist_thread(block, other_d), unlist_reply(other_d, other_c)]), "нет гасимых записей"),
    (tx(records + [unlist_reply(other_d, other_c)]), "файл эту запись не гасит"),
    (tx([retire("comment", c), dict(ok_op, id=other_d)]), "с которого ничего не снимает"),
    (dict(tx([restore([plain, link("https://good.example")])]), check=after_link), "вместе с гашением одного своего треда"),
    (dict(tx([restore([plain, link("https://evil.example")])] + records), check=after_link), "не обратен разрезу"),
    (dict(tx([data_op(block, "ВЗЛОМ")] + records), check=dict(after_link, segments=[plain, link("x", [d])])),
     "не обратен разрезу"),
    # чужая подсветка: в сверке на сегменте ещё тред other_d, а возврат её снимает
    (dict(tx([restore([plain, link("https://good.example")])] + records),
          check=dict(after_link, segments=[dict(plain, discussions=[other_d]), link("https://good.example", [d])])),
     "не обратен разрезу"),
]
bad = []
for body, want in cases:
    path = tmp + "/rb.json"
    json.dump(body, open(path, "w"))
    run = subprocess.run([sys.executable, ops_py, "--check-rollback", "--", path], capture_output=True, text=True)
    if run.returncode == 0 or want not in run.stderr:
        bad.append((want, run.returncode, run.stderr.strip()[:200]))
# Отказ не подсказывает обходной путь: файл, отправленный вручную через
# buildin.sh, миновал бы все проверки отката.
json.dump(tx([data_op(block, "alpha beta")]), open(tmp + "/rb.json", "w"))
run = subprocess.run([sys.executable, ops_py, "--check-rollback", "--", tmp + "/rb.json"], capture_output=True, text=True)
if "buildin.sh" in run.stderr:
    bad.append(("отказ советует buildin.sh", run.stderr.strip()[:200]))
for b in bad:
    print("NOT REFUSED AS EXPECTED:", b)
sys.exit(1 if bad else 0)
PY
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "build hands over the rollback check: page, block and the segments it writes" {
    mkdoc '[{"text": "alpha beta gamma", "type": 0, "enhancer": {}}]'
    result=$(build "beta" "note" "--page=55555555-5555-4555-8555-555555555555" | python3 -c "
import json, sys
r = json.load(sys.stdin)
c = r['check']
seg_op = [o for o in r['ops'] if o.get('path') == ['data']][0]
print(sorted(c) == ['block', 'page', 'segments'], c['page'] == '55555555-5555-4555-8555-555555555555',
      c['block'] == '$BLOCK', c['segments'] == seg_op['args']['segments'])")
    [ "$result" = "True True True True" ]
}

@test "reply hands over the rollback check with the page only" {
    mkthread false
    result=$(reply "ответ" "--page=55555555-5555-4555-8555-555555555555" | python3 -c "
import json, sys
print(json.load(sys.stdin)['check'])")
    [ "$result" = "{'page': '55555555-5555-4555-8555-555555555555'}" ]
}

# План отката: файл, текущая страница и пользователь → применить или отказать.
# Каждый случай — отдельный прогон --rollback-plan с ожидаемым итогом.
plan_cases() { # $1 — какой набор случаев
    python3 - "$OPS_PY" "$BATS_TEST_TMPDIR" "$BLOCK" "$SPACE" "$1" <<'PY2'
import copy, json, subprocess, sys
ops_py, tmp, block, space, which = sys.argv[1:6]
page, me, other = "55555555-5555-4555-8555-555555555555", "77777777-0000-4000-8000-000000000001", "77777777-0000-4000-8000-000000000002"
D, C1, C2 = "66666666-6666-4666-8666-666666666666", "88888888-8888-4888-8888-888888888881", "88888888-8888-4888-8888-888888888882"
C3 = "88888888-8888-4888-8888-888888888883"
snap = [{"text": "alpha beta", "type": 0, "enhancer": {}}]
after = [{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {}, "discussions": [D]}]
def touch(table, rid, status=False):
    args = {"updatedAt": 1, "updatedBy": me}
    if status:
        args["status"] = -1
    return {"id": rid, "command": "update", "table": table, "path": [], "args": args}
comment_ops = [{"id": block, "command": "update", "table": "block", "path": ["data"], "args": {"segments": snap}},
               {"id": block, "command": "listRemove", "table": "block", "path": ["discussions"], "args": {"uuid": D}},
               touch("comment", C1, True), touch("discussion", D, True), touch("block", block)]
reply_ops = [{"id": D, "command": "listRemove", "table": "discussion", "path": ["comments"], "args": {"uuid": C2}},
             touch("comment", C2, True)]
def body(ops, check):
    b = {"transactions": [{"spaceId": space, "operations": ops}]}
    if check is not None:
        b["check"] = check
    return b
OTHER_BLOCK, D2 = "22222222-0000-4000-8000-000000000b02", "66666666-0000-4000-8000-0000000000d2"
def doc(segments=after, thread_by=me, comments=(C1,), extra=None, with_block=True, with_records=True,
        thread_parent=block, c1_parent=D):
    msgs = {C1: {"uuid": C1, "createdBy": me, "status": 1, "parentId": c1_parent}}
    for cid, rec in (extra or {}).items():
        msgs[cid] = dict({"parentId": D}, **rec)
    data = {"blocks": {block: {"uuid": block, "discussions": [D], "data": {"segments": segments}}} if with_block else {}}
    if with_records:
        data["discussions"] = {D: {"uuid": D, "createdBy": thread_by, "parentId": thread_parent, "comments": list(comments)}}
        data["comments"] = msgs
    return {"data": data}
full_check = {"page": page, "block": block, "segments": after}
cases = {
  "comment": [
    ("fresh, no replies -> full", body(comment_ops, full_check), doc(), [], True, 5, ""),
    ("narrow drops the segments", body(comment_ops, full_check), doc(), ["--narrow"], True, 4, ""),
    ("stale -> refuse, hint narrow", body(comment_ops, full_check), doc(segments=snap), [], False, 0, "--narrow"),
    ("stale, narrow -> ok without segments", body(comment_ops, full_check), doc(segments=snap), ["--narrow"], True, 4, ""),
    ("block missing -> refuse", body(comment_ops, full_check), doc(with_block=False), [], False, 0, "--narrow"),
    ("block missing, narrow -> refuse before the write", body(comment_ops, full_check), doc(with_block=False),
     ["--narrow"], False, 0, "", "блока треда"),
    ("live foreign reply -> refuse", body(comment_ops, full_check),
     doc(comments=(C1, C2), extra={C2: {"uuid": C2, "createdBy": other, "status": 1}}), [], False, 0, "comment-resolve",
     "чужие сообщения"),
    ("live foreign reply, narrow too", body(comment_ops, full_check),
     doc(comments=(C1, C2), extra={C2: {"uuid": C2, "createdBy": other, "status": 1}}), ["--narrow"], False, 0, "comment-resolve",
     "чужие сообщения"),
    ("own live reply -> roll it back first", body(comment_ops, full_check),
     doc(comments=(C1, C2), extra={C2: {"uuid": C2, "createdBy": me, "status": 1}}), [], False, 0, "откатите ответы",
     "ваши ответы"),
    ("own and foreign replies -> the foreign one decides", body(comment_ops, full_check),
     doc(comments=(C1, C2, C3), extra={C2: {"uuid": C2, "createdBy": me, "status": 1},
                                       C3: {"uuid": C3, "createdBy": other, "status": 1}}), [], False, 0, "comment-resolve",
     "чужие сообщения (1)"),
    ("retired foreign reply -> ok", body(comment_ops, full_check),
     doc(comments=(C1, C2), extra={C2: {"uuid": C2, "createdBy": other, "status": -1}}), [], True, 5, ""),
    ("thread by someone else -> refuse", body(comment_ops, full_check), doc(thread_by=other), [], False, 0, ""),
    ("records gone -> refuse", body(comment_ops, full_check), doc(with_records=False), [], False, 0, ""),
    # Запись снимается только со своего списка: тред — с блока из его parentId,
    # сообщение треда гасится только вместе с этим тредом.
    ("thread hangs on another block -> refuse", body(comment_ops, full_check), doc(thread_parent=OTHER_BLOCK),
     [], False, 0, "", "не из списка"),
    ("message from another thread -> refuse", body(comment_ops, full_check), doc(c1_parent=D2),
     [], False, 0, "", "не из гасимого треда"),
    # Тред честно снимается со своего блока, а сегменты файл возвращает другому.
    ("thread from one block, segments restored to another -> refuse",
     body([comment_ops[0], dict(comment_ops[1], id=OTHER_BLOCK)] + comment_ops[2:4] + [touch("block", OTHER_BLOCK)],
          full_check),
     doc(thread_parent=OTHER_BLOCK), [], False, 0, "", "не на блоке из сверки"),
  ],
  "reply": [
    ("own reply -> ok", body(reply_ops, {"page": page}),
     doc(comments=(C1, C2), extra={C2: {"uuid": C2, "createdBy": me, "status": 1}}), [], True, 2, ""),
    ("someone else's reply -> refuse", body(reply_ops, {"page": page}),
     doc(comments=(C1, C2), extra={C2: {"uuid": C2, "createdBy": other, "status": 1}}), [], False, 0, ""),
    ("no check -> refuse", body(reply_ops, None),
     doc(comments=(C1, C2), extra={C2: {"uuid": C2, "createdBy": me, "status": 1}}), [], False, 0, ""),
    ("own reply, but from another thread -> refuse", body(reply_ops, {"page": page}),
     doc(comments=(C1, C2), extra={C2: {"uuid": C2, "createdBy": me, "status": 1, "parentId": D2}}), [], False, 0, "",
     "не из списка"),
  ],
}[which]
bad = []
for name, b, d, flags, want_apply, want_ops, want_hint, *want_reason in cases:
    json.dump(b, open(tmp + "/rb.json", "w")); json.dump(d, open(tmp + "/doc.json", "w"))
    run = subprocess.run([sys.executable, ops_py, "--rollback-plan", "--user=" + me] + flags + ["--", tmp + "/rb.json", tmp + "/doc.json"],
                         capture_output=True, text=True)
    try:
        plan = json.loads(run.stdout)
    except ValueError:
        bad.append((name, "no plan", run.stderr.strip()[:200])); continue
    if ((plan["apply"], len(plan["ops"])) != (want_apply, want_ops) or want_hint not in plan["hint"]
            or (want_reason and want_reason[0] not in plan["reason"])):
        bad.append((name, plan["apply"], len(plan["ops"]), plan["reason"][:90], plan["hint"][:60]))
for x in bad:
    print("WRONG PLAN:", x)
sys.exit(1 if bad else 0)
PY2
}

@test "rollback plan for a comment: replies, authorship, freshness and narrow" {
    run plan_cases comment
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "rollback plan names the open thread to close first, but not a closed one or a reply" {
    run python3 - "$OPS_PY" "$BATS_TEST_TMPDIR" "$BLOCK" "$SPACE" <<'PY2'
import json, subprocess, sys
ops_py, tmp, block, space = sys.argv[1:5]
page, me = "55555555-5555-4555-8555-555555555555", "77777777-0000-4000-8000-000000000001"
D, C1, C2 = "66666666-6666-4666-8666-666666666666", "88888888-8888-4888-8888-888888888881", "88888888-8888-4888-8888-888888888882"
snap = [{"text": "alpha beta", "type": 0, "enhancer": {}}]
after = [{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {}, "discussions": [D]}]
retire = lambda t, r: {"id": r, "command": "update", "table": t, "path": [], "args": {"status": -1}}
thread_ops = [{"id": block, "command": "update", "table": "block", "path": ["data"], "args": {"segments": snap}},
              {"id": block, "command": "listRemove", "table": "block", "path": ["discussions"], "args": {"uuid": D}},
              retire("comment", C1), retire("discussion", D)]
reply_ops = [{"id": D, "command": "listRemove", "table": "discussion", "path": ["comments"], "args": {"uuid": C2}},
             retire("comment", C2)]
def doc(resolved):
    return {"data": {"blocks": {block: {"uuid": block, "discussions": [D], "data": {"segments": after}}},
                     "discussions": {D: {"uuid": D, "createdBy": me, "parentId": block, "resolved": resolved,
                                         "comments": [C1, C2]}},
                     "comments": {C1: {"uuid": C1, "createdBy": me, "parentId": D, "status": 1},
                                  C2: {"uuid": C2, "createdBy": me, "parentId": D, "status": -1}}}}
def plan(ops, check, d):
    json.dump({"transactions": [{"spaceId": space, "operations": ops}], "check": check}, open(tmp + "/rb.json", "w"))
    json.dump(d, open(tmp + "/doc.json", "w"))
    r = subprocess.run([sys.executable, ops_py, "--rollback-plan", "--user=" + me, "--", tmp + "/rb.json", tmp + "/doc.json"],
                       capture_output=True, text=True)
    return json.loads(r.stdout)
full = {"page": page, "block": block, "segments": after}
got = [plan(thread_ops, full, doc(False))["open_threads"], plan(thread_ops, full, doc(True))["open_threads"],
       plan(reply_ops, {"page": page}, dict(doc(False), data=dict(doc(False)["data"], comments={
           C1: {"uuid": C1, "createdBy": me, "parentId": D, "status": 1},
           C2: {"uuid": C2, "createdBy": me, "parentId": D, "status": 1}})))["open_threads"]]
print(got)
sys.exit(0 if got == [[D], [], []] else 1)
PY2
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "rollback plan for a reply: only your own message, and only with a check" {
    run plan_cases reply
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "rollback verdict: all changes on the page is ok, none is not-applied, a mix or no owner is unverified" {
    run python3 - "$OPS_PY" "$BATS_TEST_TMPDIR" "$BLOCK" <<'PY2'
import json, subprocess, sys
ops_py, tmp, block = sys.argv[1:4]
D, C = "66666666-6666-4666-8666-666666666666", "88888888-8888-4888-8888-888888888882"
snap = [{"text": "alpha beta", "type": 0, "enhancer": {}}]
after = [{"text": "alpha ", "type": 0, "enhancer": {}}, {"text": "beta", "type": 0, "enhancer": {}, "discussions": [D]}]
retire = {"id": D, "command": "update", "table": "discussion", "path": [], "args": {"status": -1}}
full = [{"id": block, "command": "update", "table": "block", "path": ["data"], "args": {"segments": snap}},
        {"id": block, "command": "listRemove", "table": "block", "path": ["discussions"], "args": {"uuid": D}}, retire]
narrow = full[1:]
reply = [{"id": D, "command": "listRemove", "table": "discussion", "path": ["comments"], "args": {"uuid": C}}]
def page(listed, segments, comments=None):
    data = {"blocks": {block: {"uuid": block, "discussions": listed, "data": {"segments": segments}}}}
    if comments is not None:
        data["discussions"] = {D: {"uuid": D, "comments": comments}}
    return {"code": 200, "data": data}
cases = [
    ("full landed", full, page([], snap), "ok"),
    ("full not landed", full, page([D], after), "not-applied"),
    ("unlisted, but segments not back", full, page([], after), "unverified"),
    ("error envelope", full, {"code": 500, "msg": "x"}, "unverified"),
    ("narrow landed, segments untouched", narrow, page([], after), "ok"),
    ("narrow not landed", narrow, page([D], after), "not-applied"),
    ("reply removed", reply, page([D], after, comments=["x"]), "ok"),
    ("reply still there", reply, page([D], after, comments=["x", C]), "not-applied"),
    ("thread gone from the page", reply, page([D], after), "unverified"),
]
bad = []
for name, ops, doc, want in cases:
    json.dump(ops, open(tmp + "/ops.json", "w")); json.dump(doc, open(tmp + "/after.json", "w"))
    got = subprocess.run([sys.executable, ops_py, "--rollback-verdict", "--", tmp + "/after.json", tmp + "/ops.json"],
                         capture_output=True, text=True).stdout.strip()
    if got != want:
        bad.append((name, got, want))
for x in bad:
    print("WRONG VERDICT:", x)
sys.exit(1 if bad else 0)
PY2
    echo "$output"
    [ "$status" -eq 0 ]
}

# ---- @-упоминания -----------------------------------------------------------

JDOE=55555555-5555-4555-8555-555555555555
ASMITH=99999999-9999-4999-8999-999999999999

# Ответ /api/spaces/<space>/members с двумя участниками.
mkmembers() {
    printf '{"code":200,"data":[{"user":{"uuid":"%s","nickname":"j.doe"}},{"user":{"uuid":"%s","nickname":"a.smith"}}]}' \
        "$JDOE" "$ASMITH" > "$BATS_TEST_TMPDIR/members.json"
}

@test "a mention leads the message as a type 7 segment, exactly as the UI writes it" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    mkmembers
    result=$(build "beta" "посмотри" "--mention=$JDOE" "--members=$BATS_TEST_TMPDIR/members.json" | probe "print(comment['args']['text'])")
    [ "$result" = "[{'text': '', 'type': 7, 'uuid': '$JDOE', 'enhancer': {}}, {'text': ' посмотри', 'type': 0, 'enhancer': {}}]" ]
}

@test "several mentions are separated by spaces and repeats collapse" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    mkmembers
    result=$(build "beta" "гляньте" "--mention=$JDOE" "--mention=$ASMITH" "--mention=$JDOE" "--members=$BATS_TEST_TMPDIR/members.json" \
        | probe "print([s.get('uuid') or s['text'] for s in comment['args']['text']])")
    [ "$result" = "['$JDOE', ' ', '$ASMITH', ' гляньте']" ]
}

@test "a mention of someone outside the space is refused with a hint where uuids live" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    mkmembers
    err=$(build_stderr "beta" "note" "--mention=88888888-8888-4888-8888-888888888888" "--members=$BATS_TEST_TMPDIR/members.json") || true
    [[ "$err" == *"среди участников пространства нет 88888888-8888-4888-8888-888888888888"* ]] || false
    [[ "$err" == *"buildin-pages.sh members <page>"* ]]
}

@test "a mention without a members list is refused" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    printf '{"code":500,"msg":"no rights"}' > "$BATS_TEST_TMPDIR/members.json"
    err=$(build_stderr "beta" "note" "--mention=$JDOE" "--members=$BATS_TEST_TMPDIR/members.json") || true
    [[ "$err" == *"список участников пространства не получен"* ]]
}

@test "a reply carries the mention the same way" {
    mkthread false
    mkmembers
    result=$(python3 "$OPS_PY" --reply "--mention=$JDOE" "--members=$BATS_TEST_TMPDIR/members.json" -- \
        "$DOC" "$THREAD" "ответ" "$NOW" "$USER" 2>/dev/null \
        | python3 -c "import json, sys; print([s.get('uuid') or s['text'] for s in json.load(sys.stdin)['ops'][0]['args']['text']])")
    [ "$result" = "['$JDOE', ' ответ']" ]
}

@test "mentions are checked only after the block and the thread are found" {
    mkdoc '[{"text": "alpha beta", "type": 0, "enhancer": {}}]'
    err=$(python3 "$OPS_PY" "--mention=$JDOE" -- "$DOC" "44444444-4444-4444-4444-444444444444" "beta" "note" "$NOW" "$USER" 2>&1 >/dev/null) || true
    [[ "$err" == *"не найден на странице"* ]] || false
    err=$(python3 "$OPS_PY" --reply "--mention=$JDOE" -- "$DOC" "$THREAD" "ответ" "$NOW" "$USER" 2>&1 >/dev/null) || true
    [[ "$err" == *"Треда $THREAD на странице нет"* ]]
}
