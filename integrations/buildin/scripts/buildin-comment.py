#!/usr/bin/env python3
"""Построитель операций UI API для комментария к фразе внутри блока Buildin.

Читает ответ GET /api/docs/<page_id> и печатает JSON-массив операций транзакции —
отправляет их `buildin-pages.sh comment` общим хелпером transaction().

Комментарий к фразе — это три операции в ОДНОЙ транзакции:
  1. discussion — тред, привязанный к блоку (parentId = uuid блока);
  2. comment    — первое сообщение треда (parentId = uuid треда);
  3. update блока — якорь выносится в отдельный сегмент с discussions:[<тред>].
Без третьей операции тред создаётся, но остаётся неприкреплённым: на странице
его не видно, а найти можно только через API.

Якорь обязан целиком лежать внутри ОДНОГО сегмента. Сегмент — отрезок текста с
единым форматированием, поэтому фраза, задевающая границу жирного/кода/ссылки,
выделена быть не может. Такой якорь отвергается с разбором сегментов: молча
привязать тред не туда хуже, чем не привязать вовсе.

Usage:
    buildin-comment.py <doc_json> <block_id> <anchor> <text> <now_ms> <user_id>
                       [--rollback-out <path>]

<doc_json> — файл с ответом /api/docs (или «-» для stdin).
--rollback-out — куда сохранить payload отката: готовое тело запроса к
/api/records/transactions, возвращающее блоку его текущие data и discussions.
"""
import copy
import json
import os
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


def find_anchor(segments, anchor):
    """Индекс сегмента и позицию якоря в нём. Первое вхождение."""
    if not anchor:
        raise AnchorError("Якорь пустой — нечего выделять.")
    for i, s in enumerate(segments or []):
        pos = s.get("text", "").find(anchor)
        if pos != -1:
            return i, pos
    full = segment_text(segments)
    # Якорь виден на странице, но разорван границей форматирования — самая
    # частая причина промаха, и по одному «не найдено» её не отличить от опечатки.
    split = anchor in full
    reason = (
        "Якорь есть в тексте блока, но разорван границей сегментов."
        if split
        else "Якоря нет в тексте блока."
    )
    hint = (
        "Возьмите фразу короче — целиком внутри одного форматирования."
        if split
        else "Сверьте фразу с текстом блока (важны регистр и пробелы)."
    )
    raise AnchorError(
        "%s Якорь должен целиком лежать внутри одного сегмента.\n"
        "Текст блока: «%s»\nСегменты:\n%s\n%s" % (reason, full, describe_segments(segments), hint)
    )


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


def build_ops(block, block_id, anchor, text, now, user_id):
    """Три операции транзакции. Возвращает (ops, discussion_id, new_data)."""
    space_id = block.get("spaceId", "")
    data = copy.deepcopy(block.get("data") or {})
    segments = data.get("segments") or []

    index, pos = find_anchor(segments, anchor)
    discussion_id, comment_id = str(uuid.uuid4()), str(uuid.uuid4())
    data["segments"] = split_segments(segments, index, pos, anchor, discussion_id)

    # Комментарий не правит документ: перенарезка сегментов обязана быть
    # побайтово нейтральной для текста. Проверяем до отправки, а не assert'ом —
    # под python3 -O assert исчезает, и защита пропала бы молча.
    old_text, new_text = segment_text(segments), segment_text(data["segments"])
    if old_text != new_text:
        raise AnchorError(
            "Текст блока изменился бы при перенарезке сегментов — отмена.\n"
            "было:  «%s»\nстало: «%s»" % (old_text, new_text)
        )

    ops = [
        {
            "id": discussion_id,
            "command": "set",
            "table": "discussion",
            "path": [],
            "args": {
                "uuid": discussion_id,
                "spaceId": space_id,
                "parentId": block_id,
                "createdAt": now,
                "createdBy": user_id,
                "updatedAt": now,
                "updatedBy": user_id,
                "deletedBy": None,
                "version": 1,
                "status": 1,
                "resolved": False,
                "comments": [comment_id],
                "context": [{"text": anchor, "type": 0, "enhancer": {}}],
            },
        },
        {
            "id": comment_id,
            "command": "set",
            "table": "comment",
            "path": [],
            "args": {
                "uuid": comment_id,
                "spaceId": space_id,
                "parentId": discussion_id,
                "version": 1,
                "status": 1,
                "createdAt": now,
                "createdBy": user_id,
                "updatedAt": now,
                "updatedBy": user_id,
                "text": [{"text": text, "type": 0, "enhancer": {}}],
            },
        },
        {
            "id": block_id,
            "command": "update",
            "table": "block",
            "path": [],
            "args": {
                "data": data,
                "discussions": list(block.get("discussions") or []) + [discussion_id],
                "updatedAt": now,
                "updatedBy": user_id,
            },
        },
    ]
    return ops, discussion_id


def rollback_body(block, block_id, now, user_id):
    """Тело запроса к /api/records/transactions, возвращающее блок как есть.

    Сохраняем готовым запросом, а не голыми полями: откат — это одна команда
    `buildin.sh POST /api/records/transactions "$(cat <файл>)"`, без сборки
    конверта руками в момент, когда уже что-то пошло не так.
    """
    return {
        "requestId": str(uuid.uuid4()),
        "transactions": [
            {
                "id": str(uuid.uuid4()),
                "spaceId": block.get("spaceId", ""),
                "operations": [
                    {
                        "id": block_id,
                        "command": "update",
                        "table": "block",
                        "path": [],
                        "args": {
                            "data": copy.deepcopy(block.get("data") or {}),
                            "discussions": list(block.get("discussions") or []),
                            "updatedAt": now,
                            "updatedBy": user_id,
                        },
                    }
                ],
            }
        ],
    }


def parse_args(argv):
    positional, rollback_out = [], None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--rollback-out":
            i += 1
            if i >= len(argv):
                raise SystemExit("Error: --rollback-out без значения")
            rollback_out = argv[i]
        else:
            positional.append(a)
        i += 1
    if len(positional) != 6:
        raise SystemExit(__doc__.strip())
    doc_json, block_id, anchor, text, now, user_id = positional
    return doc_json, block_id, anchor, text, int(now), user_id, rollback_out


def main():
    doc_json, block_id, anchor, text, now, user_id, rollback_out = parse_args(sys.argv[1:])

    raw = sys.stdin.read() if doc_json == "-" else open(doc_json, encoding="utf-8").read()
    blocks = (json.loads(raw).get("data") or {}).get("blocks") or {}
    block = blocks.get(block_id)
    if block is None:
        raise SystemExit(
            "Error: блок %s не найден на странице. "
            "Идентификаторы блоков — поле uuid в выводе `buildin-pages.sh get-blocks`." % block_id
        )

    try:
        ops, discussion_id = build_ops(block, block_id, anchor, text, now, user_id)
    except AnchorError as e:
        raise SystemExit("Error: %s" % e)

    if rollback_out:
        body = rollback_body(block, block_id, now, user_id)
        with open(rollback_out, "w", encoding="utf-8") as f:
            json.dump(body, f, ensure_ascii=False, indent=1)

    # discussion_id уходит в stderr: stdout занят операциями для transaction().
    sys.stderr.write("discussion: %s%s" % (discussion_id, os.linesep))
    print(json.dumps(ops, ensure_ascii=False))


if __name__ == "__main__":
    main()
