#!/usr/bin/env python3
"""Построитель операций UI API для комментария к фразе внутри блока Buildin.

Читает ответ GET /api/docs/<page_id> и печатает JSON-объект
{"ops": [...], "rollback": [...], "discussion": "<uuid>", "comment": "<uuid>"} —
отправляет операции `buildin-pages.sh comment` общим хелпером transaction(),
а из `rollback` тем же хелпером собирает файл отката. Своего конверта
транзакции здесь намеренно нет: две копии разошлись бы молча.

Комментарий к фразе — это несколько операций в ОДНОЙ транзакции:
  1. discussion — тред, привязанный к блоку (parentId = uuid блока);
  2. comment    — первое сообщение треда (parentId = uuid треда);
  3. update блока по path ['data'] — якорь выносится в отдельный сегмент
     с discussions: [<тред>];
  4. listAfter по path ['discussions'] — тред добавляется в список блока.
Без 3 и 4 тред создаётся, но остаётся неприкреплённым: на странице его не
видно. Операции 3–4 узкие намеренно: полная перезапись блока стирала бы
чужие ключи data и выбивала чужие треды из списка (проверено на живой
странице — listAfter аддитивен, а полный список нет).

Якорь обязан целиком лежать внутри ОДНОГО сегмента. Сегмент — отрезок текста с
единым форматированием, поэтому фраза, задевающая границу жирного/кода/ссылки,
выделена быть не может. Неоднозначный якорь (несколько вхождений) тоже
отвергается: молча привязать тред не туда хуже, чем не привязать вовсе.

Usage:
    buildin-comment.py <doc_json> <block_id> <anchor> <text> <now_ms> <user_id>
                       [--occurrence N]

<doc_json> — файл с ответом /api/docs (или «-» для stdin).
--occurrence N — какое вхождение якоря выделить (1-based), когда их несколько.
"""
import copy
import json
import sys
import uuid


class AnchorError(Exception):
    """Якорь не удалось выделить — сообщение уже человекочитаемое."""


def segment_text(segments):
    """Видимый текст блока: конкатенация сегментов."""
    return "".join(s.get("text", "") for s in (segments or []))


def describe_segments(segments):
    """Разбор сегментов для сообщения об ошибке: индекс, текст, форматирование."""
    lines = []
    for i, s in enumerate(segments or []):
        marks = [k for k, v in (s.get("enhancer") or {}).items() if v]
        if s.get("url"):
            marks.append("link")
        suffix = " [%s]" % ", ".join(marks) if marks else ""
        lines.append("  [%d] «%s»%s" % (i, s.get("text", ""), suffix))
    return "\n".join(lines) or "  (сегментов нет)"


def _all_offsets(text, anchor):
    """Смещения всех вхождений якоря в видимом тексте, без перекрытий."""
    offsets, start = [], 0
    while True:
        i = text.find(anchor, start)
        if i == -1:
            return offsets
        offsets.append(i)
        start = i + len(anchor)


def _locate(segments, offset, length):
    """(индекс сегмента, позиция внутри него) для вхождения по смещению.

    Возвращает None, если вхождение пересекает границу сегментов.
    """
    base = 0
    for i, s in enumerate(segments or []):
        t = s.get("text", "")
        if base <= offset < base + len(t):
            pos = offset - base
            return (i, pos) if pos + length <= len(t) else None
        base += len(t)
    return None


def find_anchor(segments, anchor, occurrence=None):
    """Индекс сегмента и позицию якоря в нём.

    Вхождения считаются по ВИДИМОМУ тексту — по тому, что человек видит на
    странице, — и только потом проецируются в сегменты. Иначе разбиение на
    сегменты (деталь хранения) меняло бы нумерацию вхождений.
    """
    if not anchor:
        raise AnchorError("Якорь пустой — нечего выделять.")

    full = segment_text(segments)
    offsets = _all_offsets(full, anchor)

    if not offsets:
        raise AnchorError(
            "Якоря нет в тексте блока. Якорь должен целиком лежать внутри одного сегмента.\n"
            "Текст блока: «%s»\nСегменты:\n%s\n"
            "Сверьте фразу с текстом блока (важны регистр и пробелы)." % (full, describe_segments(segments))
        )

    if occurrence is not None:
        if not 1 <= occurrence <= len(offsets):
            raise AnchorError(
                "Запрошено вхождение %d, а якорь встречается %d раз(а).\n"
                "Текст блока: «%s»" % (occurrence, len(offsets), full)
            )
        chosen = [offsets[occurrence - 1]]
    else:
        chosen = offsets

    if len(chosen) > 1:
        # Неоднозначность — тот же класс отказа, что и разрыв границей: команда
        # не угадывает, какое из вхождений имелось в виду.
        listing = []
        for n, off in enumerate(chosen, 1):
            lo, hi = max(0, off - 20), min(len(full), off + len(anchor) + 20)
            where = "внутри одного сегмента" if _locate(segments, off, len(anchor)) else "через границу сегментов"
            listing.append("  %d) …%s…  (%s)" % (n, full[lo:hi], where))
        raise AnchorError(
            "Якорь встречается в блоке %d раз(а) — непонятно, что выделять.\n"
            "Текст блока: «%s»\nВхождения:\n%s\n"
            "Удлините якорь до однозначного или выберите вхождение: --occurrence=N."
            % (len(chosen), full, "\n".join(listing))
        )

    hit = _locate(segments, chosen[0], len(anchor))
    if hit is None:
        raise AnchorError(
            "Якорь есть в тексте блока, но разорван границей сегментов. "
            "Якорь должен целиком лежать внутри одного сегмента.\n"
            "Текст блока: «%s»\nСегменты:\n%s\n"
            "Возьмите фразу короче — целиком внутри одного форматирования."
            % (full, describe_segments(segments))
        )
    return hit


def split_segments(segments, index, pos, anchor, discussion_id):
    """Разрезать сегмент на до/якорь/после, повесив тред на средний кусок.

    Сегмент копируется целиком, а не пересобирается из type/enhancer: у ссылок
    и упоминаний есть свои поля (url, uuid), и сборка «по известным ключам» их
    теряет — ссылка внутри якоря превратилась бы в простой текст.
    """
    src = segments[index]
    text = src.get("text", "")
    before, after = text[:pos], text[pos + len(anchor):]

    parts = []
    if before:
        head = copy.deepcopy(src)
        head["text"] = before
        parts.append(head)

    mid = copy.deepcopy(src)
    mid["text"] = anchor
    mid["discussions"] = list(src.get("discussions") or []) + [discussion_id]
    parts.append(mid)

    if after:
        tail = copy.deepcopy(src)
        tail["text"] = after
        parts.append(tail)

    return segments[:index] + parts + segments[index + 1:]


def check_resplit(old, new, index, discussion_id):
    """Перенарезка обязана менять ровно одно: разбиение одного сегмента.

    Проверки явные, а не assert: под python3 -O assert исчезает, и защита
    пропала бы молча. Сверка склейки текста стоит первой как регрессионный
    сторож на случай будущих правок split_segments — сама по себе она при
    нынешней реализации сработать не может, поэтому рядом стоят проверки,
    которые разойтись способны.
    """
    if segment_text(old) != segment_text(new):
        raise AnchorError(
            "Текст блока изменился бы при перенарезке сегментов — отмена.\n"
            "было:  «%s»\nстало: «%s»" % (segment_text(old), segment_text(new))
        )
    if len(new) - len(old) not in (0, 1, 2):
        raise AnchorError(
            "Перенарезка изменила число сегментов на %d — ожидалось 0, 1 или 2." % (len(new) - len(old))
        )

    src = old[index]
    parts = new[index:index + (len(new) - len(old)) + 1]
    tagged = [p for p in parts if discussion_id in (p.get("discussions") or [])]
    if len(tagged) != 1:
        raise AnchorError("Тред должен висеть ровно на одном новом сегменте, а висит на %d." % len(tagged))

    for p in parts:
        if not p.get("text"):
            raise AnchorError("Перенарезка дала пустой сегмент — отмена.")
        rest_src = {k: v for k, v in src.items() if k not in ("text", "discussions")}
        rest_new = {k: v for k, v in p.items() if k not in ("text", "discussions")}
        if rest_src != rest_new:
            raise AnchorError(
                "Перенарезка потеряла или изменила поля сегмента (url, type, enhancer…).\n"
                "было:  %s\nстало: %s" % (json.dumps(rest_src, ensure_ascii=False, sort_keys=True),
                                          json.dumps(rest_new, ensure_ascii=False, sort_keys=True))
            )
    # Сегменты вне разреза обязаны остаться теми же объектами по значению.
    if old[:index] != new[:index] or old[index + 1:] != new[index + len(parts):]:
        raise AnchorError("Перенарезка задела соседние сегменты — отмена.")


def build_ops(block, block_id, anchor, text, now, user_id, occurrence=None):
    """Операции транзакции и операции отката. Без сети и без записи на диск."""
    if not text:
        raise AnchorError("Текст комментария пустой — нечего отправлять.")

    space_id = block.get("spaceId", "")
    data = block.get("data") or {}
    segments = data.get("segments") or []

    index, pos = find_anchor(segments, anchor, occurrence)
    discussion_id, comment_id = str(uuid.uuid4()), str(uuid.uuid4())
    new_segments = split_segments(segments, index, pos, anchor, discussion_id)
    check_resplit(segments, new_segments, index, discussion_id)

    who = {"createdAt": now, "createdBy": user_id, "updatedAt": now, "updatedBy": user_id}
    ops = [
        {
            "id": discussion_id,
            "command": "set",
            "table": "discussion",
            "path": [],
            "args": dict(
                uuid=discussion_id, spaceId=space_id, parentId=block_id,
                deletedBy=None, version=1, status=1, resolved=False,
                comments=[comment_id],
                context=[{"text": anchor, "type": 0, "enhancer": {}}],
                **who
            ),
        },
        {
            "id": comment_id,
            "command": "set",
            "table": "comment",
            "path": [],
            "args": dict(
                uuid=comment_id, spaceId=space_id, parentId=discussion_id,
                version=1, status=1,
                text=[{"text": text, "type": 0, "enhancer": {}}],
                **who
            ),
        },
        # Узко: только segments. Полный data стирал бы чужие ключи блока.
        {"id": block_id, "command": "update", "table": "block", "path": ["data"],
         "args": {"segments": new_segments}},
        # Узко: списочная операция. Полный список discussions выбивал бы чужие треды.
        {"id": block_id, "command": "listAfter", "table": "block", "path": ["discussions"],
         "args": {"uuid": discussion_id}},
        {"id": block_id, "command": "update", "table": "block", "path": [],
         "args": {"updatedAt": now, "updatedBy": user_id}},
    ]

    # Откат зеркалит запись: те же узкие операции в обратную сторону плюс
    # гашение созданных записей (status -1 — конвенция удаления в этом плагине),
    # чтобы после отката не осталось треда, который команда comments ещё видит.
    rollback = [
        {"id": block_id, "command": "update", "table": "block", "path": ["data"],
         "args": {"segments": copy.deepcopy(segments)}},
        {"id": block_id, "command": "listRemove", "table": "block", "path": ["discussions"],
         "args": {"uuid": discussion_id}},
        {"id": comment_id, "command": "update", "table": "comment", "path": [],
         "args": {"status": -1, "updatedAt": now, "updatedBy": user_id}},
        {"id": discussion_id, "command": "update", "table": "discussion", "path": [],
         "args": {"status": -1, "updatedAt": now, "updatedBy": user_id}},
        {"id": block_id, "command": "update", "table": "block", "path": [],
         "args": {"updatedAt": now, "updatedBy": user_id}},
    ]
    return {"ops": ops, "rollback": rollback, "discussion": discussion_id, "comment": comment_id}


def parse_args(argv):
    positional, occurrence = [], None
    for a in argv:
        if a.startswith("--occurrence="):
            raw = a.split("=", 1)[1]
            if not raw.isdigit() or int(raw) < 1:
                raise SystemExit("Error: --occurrence ожидает целое число >= 1, получено: %r" % raw)
            occurrence = int(raw)
        elif a.startswith("--"):
            raise SystemExit("Error: неизвестный флаг: %s" % a)
        else:
            positional.append(a)
    if len(positional) != 6:
        raise SystemExit(__doc__.strip())
    doc_json, block_id, anchor, text, now, user_id = positional
    return doc_json, block_id, anchor, text, int(now), user_id, occurrence


def main():
    doc_json, block_id, anchor, text, now, user_id, occurrence = parse_args(sys.argv[1:])

    raw = sys.stdin.read() if doc_json == "-" else open(doc_json, encoding="utf-8").read()
    blocks = (json.loads(raw).get("data") or {}).get("blocks") or {}
    block = blocks.get(block_id)
    if block is None:
        raise SystemExit(
            "Error: блок %s не найден на странице. "
            "Идентификаторы блоков — поле uuid в выводе `buildin-pages.sh get-blocks`." % block_id
        )

    try:
        result = build_ops(block, block_id, anchor, text, now, user_id, occurrence)
    except AnchorError as e:
        raise SystemExit("Error: %s" % e)

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
