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

Комментировать разрешено только прозаические блоки. У части типов segments
хранят не то, что человек видит на странице: у картинки там имя файла, а у
таблицы текст ячеек вообще лежит в data.collectionProperties. У заголовка
страницы и код-блока текст видимый, но подсветку фразы Buildin в них не
рисует — тред прикрепляется, выделения нет. Во всех этих случаях якорь
«находится», команда рапортует успех, и проверка после записи ничего не
замечает: сегмент реально несёт discussions.

Usage:
    buildin-comment.py [--occurrence=N] -- <doc_json> <block_id> <anchor> <text>
                       <now_ms> <user_id>

<doc_json> — файл с ответом /api/docs (или «-» для stdin).
--occurrence N — какое вхождение якоря выделить (1-based), когда их несколько.
"""
import copy
import json
import sys
import uuid


class AnchorError(Exception):
    """Якорь не удалось выделить — сообщение уже человекочитаемое."""


# Типы блоков Buildin — та же карта, что в комментарии кейса read) файла
# buildin-pages.sh. Разрешены только прозаические: проверено живьём, что
# подсветку фразы Buildin рисует именно в них.
PROSE_TYPES = {
    1: "абзац",
    3: "todo",
    4: "маркированный список",
    5: "нумерованный список",
    6: "toggle",
    7: "заголовок",
    12: "цитата",
    13: "callout",
    38: "toggle-заголовок",
}

# У каждого отказа своя причина и свой следующий шаг: за этими типами стоят
# ТРИ разных провала — подсветки не будет, в segments не видимый текст,
# текста в segments нет вовсе. Общее «неподходящий блок» не подсказало бы,
# что делать дальше.
_NO_HIGHLIGHT = ("тред прикрепится к блоку и будет виден в сайдбаре, "
                 "но сама фраза не подсветится")
_IN_TABLE = "текст ячеек лежит в data.collectionProperties, а не в segments"
_TABLE_HINT = ("Якорь по segments в таблице не сработает в принципе — "
               "прокомментируйте абзац рядом с таблицей.")
_NEIGHBOUR_HINT = "Прокомментируйте соседний прозаический блок."

REFUSED_TYPES = {
    0: ("заголовок страницы", _NO_HIGHLIGHT,
        "Комментарий ко всей странице оставьте в панели комментариев страницы."),
    9: ("разделитель", "у блока нет текста", _NEIGHBOUR_HINT),
    14: ("картинка", "в segments лежит имя файла, а не видимый текст",
         "Видимая подпись к картинке в segments не хранится вовсе, якорем она "
         "недостижима — прокомментируйте соседний абзац."),
    21: ("закладка", "в segments лежат URL и метаданные, а не видимый текст", _NEIGHBOUR_HINT),
    23: ("формула", "в segments лежит исходник формулы, а не отрисованный вид", _NEIGHBOUR_HINT),
    25: ("код", _NO_HIGHLIGHT,
         "Прокомментируйте соседний прозаический блок, назвав строку кода словами."),
    27: ("таблица", _IN_TABLE, _TABLE_HINT),
    28: ("строка таблицы", _IN_TABLE, _TABLE_HINT),
}


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
    """Смещения всех вхождений якоря в видимом тексте, включая перекрывающиеся.

    Шаг в один символ, а не в длину якоря: «ана» в «банана» встречается дважды,
    и поиск без перекрытий объявил бы такой якорь однозначным, молча выделив
    самое левое место, — ровно та тихая привязка не туда, от которой заведён
    отказ по неоднозначности.
    """
    offsets, start = [], 0
    while True:
        i = text.find(anchor, start)
        if i == -1:
            return offsets
        offsets.append(i)
        start = i + 1


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
        # Треды, уже висевшие на разрезаемом сегменте, обязаны пережить разрез
        # на каждой части. Их потеря — тихая пропажа чужой подсветки, то есть
        # ровно то, от чего защищает вся команда, а сравнение полей её не ловит:
        # discussions из него исключены намеренно.
        src_threads = set(src.get("discussions") or [])
        new_threads = set(p.get("discussions") or []) - {discussion_id}
        if new_threads != src_threads:
            raise AnchorError(
                "Перенарезка потеряла треды, уже висевшие на сегменте: было %s, стало %s."
                % (sorted(src_threads), sorted(new_threads))
            )
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


def check_block_type(block, segments):
    """Отказать, если подсветка фразы в блоке этого типа не появится.

    Третий гард рядом с разрывом границы сегментов и неоднозначным якорем, и
    заведён от того же провала: якорь находится, команда рапортует успех, а на
    странице ничего не выделено. Проверка после записи его не ловит — сегмент
    реально несёт discussions, поэтому «наша подсветка на месте» истинно и для
    картинки, у которой в сегментах лежит имя файла.

    Список закрытый: неизвестный тип отвергается тоже. Открытый чёрный список
    пропустил бы новый тип Buildin с метаданными в сегментах, и баг вернулся бы
    незамеченным — ровно так, как этот и обнаружился.
    """
    btype = block.get("type")
    if btype in PROSE_TYPES:
        return

    allowed = ", ".join("%d (%s)" % (t, PROSE_TYPES[t]) for t in sorted(PROSE_TYPES))
    known = REFUSED_TYPES.get(btype)
    if known:
        name, reason, hint = known
        head = "Блок типа %s (%s) комментировать нельзя: %s." % (btype, name, reason)
    else:
        head = ("Блок типа %s команде неизвестен: нет уверенности, что его segments — "
                "это видимый на странице текст." % btype)
        hint = ("Если этот тип показывает на странице именно такой текст — "
                "добавьте его в PROSE_TYPES.")
    raise AnchorError(
        "%s\nТекст сегментов: «%s»\n"
        "Комментарий к фразе поддерживают только прозаические блоки: %s.\n%s"
        % (head, segment_text(segments), allowed, hint)
    )


def build_ops(block, block_id, anchor, text, now, user_id, occurrence=None):
    """Операции транзакции и операции отката. Без сети и без записи на диск."""
    if not text:
        raise AnchorError("Текст комментария пустой — нечего отправлять.")

    space_id = block.get("spaceId", "")
    data = block.get("data") or {}
    segments = data.get("segments") or []

    check_block_type(block, segments)
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

    # Снятие созданных записей: тред вон из списка блока, сам тред и сообщение
    # гасятся (status -1 — конвенция удаления в этом плагине), чтобы после
    # отката не осталось треда, который команда comments ещё видит.
    retire = [
        {"id": block_id, "command": "listRemove", "table": "block", "path": ["discussions"],
         "args": {"uuid": discussion_id}},
        {"id": comment_id, "command": "update", "table": "comment", "path": [],
         "args": {"status": -1, "updatedAt": now, "updatedBy": user_id}},
        {"id": discussion_id, "command": "update", "table": "discussion", "path": [],
         "args": {"status": -1, "updatedAt": now, "updatedBy": user_id}},
        {"id": block_id, "command": "update", "table": "block", "path": [],
         "args": {"updatedAt": now, "updatedBy": user_id}},
    ]
    # Полный откат — когда наша запись в блоке: возвращаем ещё и сегменты.
    rollback = [
        {"id": block_id, "command": "update", "table": "block", "path": ["data"],
         "args": {"segments": copy.deepcopy(segments)}},
    ] + retire
    # Узкий откат — когда блок уже переписал кто-то другой. Возвращать наши
    # сегменты там нельзя: в блоке лежат чужие, и восстановление снапшота
    # стёрло бы подсветку того, кто выиграл гонку.
    return {"ops": ops, "rollback": rollback, "rollback_records": retire,
            "discussion": discussion_id, "comment": comment_id}


def read_block(doc, block_id):
    """Блок из ответа /api/docs, либо None, если его там нет."""
    blocks = (doc.get("data") or {}).get("blocks") or {}
    return blocks.get(block_id)


def block_state(block):
    """(треды в списке блока, треды с подсветкой в сегментах)."""
    segments = ((block.get("data") or {}).get("segments")) or []
    listed = set(block.get("discussions") or [])
    lit = {t for s in segments for t in (s.get("discussions") or [])}
    return listed, lit


def verdict(before, after, block_id, ours):
    """Исход записи по снимкам блока до и после неё: (статус, потерявшие подсветку).

    Четыре разных исхода, потому что и делать с ними надо разное:
      unverified  — блока нет в ответе: это конверт ошибки или чужая страница,
                    об исходе записи ничего не известно, гасить ничего нельзя;
      not-applied — нашего треда нет даже в списке блока. listAfter аддитивен, и
                    конкурент наш id из списка не убирает, значит транзакция не
                    легла. Создавать было нечего, повтор безопасен;
      lost-ours   — тред в списке, но подсветки нет: нас перезаписали;
      ok          — подсветка на месте.

    Раньше все три неудачных исхода сводились к «нас перезаписали», и на отказ
    API команда отвечала самоочисткой несуществующих записей или гашением
    собственного успешного треда.
    """
    after_block = read_block(after, block_id)
    if after_block is None:
        return "unverified", []

    after_listed, after_lit = block_state(after_block)
    if ours in after_lit:
        before_listed, before_lit = block_state(read_block(before, block_id) or {})
        # Давно осиротевшие — те, что были в списке без подсветки ещё до нас, —
        # вычитаем: это не наша работа и не повод для тревоги.
        return "ok", sorted((after_listed - after_lit) - (before_listed - before_lit))
    if ours not in after_listed:
        return "not-applied", []
    return "lost-ours", []


def parse_args(argv):
    positional, occurrence, end_of_opts, as_verdict = [], None, False, False
    for a in argv:
        if end_of_opts or not a.startswith("--"):
            positional.append(a)
        elif a == "--verdict":
            as_verdict = True
        elif a == "--":
            # Всё после «--» — значения. Без этого якорь или текст с ведущими
            # дефисами («--force», «-- не согласен») не доходит до билдера
            # никакой формой ввода: они едут через argv, в том числе из @file.
            end_of_opts = True
        elif a.startswith("--occurrence="):
            raw = a.split("=", 1)[1]
            if not raw.isdigit() or int(raw) < 1:
                raise SystemExit("Error: --occurrence ожидает целое число >= 1, получено: %r" % raw)
            occurrence = int(raw)
        else:
            raise SystemExit("Error: неизвестный флаг: %s" % a)
    if as_verdict:
        if len(positional) != 4:
            raise SystemExit("Usage: buildin-comment.py --verdict -- <before_json> <after_json> "
                             "<block_id> <discussion_id>")
        return ("verdict",) + tuple(positional)
    if len(positional) != 6:
        raise SystemExit(__doc__.strip())
    doc_json, block_id, anchor, text, now, user_id = positional
    return ("build", doc_json, block_id, anchor, text, int(now), user_id, occurrence)


def load_doc(path):
    """Ответ /api/docs или пустой документ, если это не JSON (конверт ошибки)."""
    try:
        return json.loads(sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read())
    except ValueError:
        return {}


def main():
    parsed = parse_args(sys.argv[1:])
    if parsed[0] == "verdict":
        _, before_path, after_path, block_id, ours = parsed
        status, lost = verdict(load_doc(before_path), load_doc(after_path), block_id, ours)
        print(status)
        print(" ".join(lost))
        return

    _, doc_json, block_id, anchor, text, now, user_id, occurrence = parsed

    block = read_block(load_doc(doc_json), block_id)
    if block is None:
        raise SystemExit(
            "Error: блок %s не найден на странице. "
            "Идентификаторы блоков — поле uuid в выводе `buildin-pages.sh get-blocks`." % block_id
        )

    try:
        result = build_ops(block, block_id, anchor, text, now, user_id, occurrence)
    except AnchorError as e:
        raise SystemExit("Error: %s" % e)

    # Без ensure_ascii=False: вывод разбирает json.load, ему \uXXXX всё равно,
    # а печать не-ASCII падает под не-UTF-8 локалью (LC_ALL=C).
    print(json.dumps(result))


if __name__ == "__main__":
    main()
