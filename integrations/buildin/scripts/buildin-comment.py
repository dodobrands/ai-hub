#!/usr/bin/env python3
"""Операции UI API для команд комментариев Buildin: построение и проверка.

Модуль строит операции comment, comment-reply и резолва, проверяет записанное
(вердикты после записи) и файлы отката (форма, план по странице). Сети здесь
нет: читает он ответы /api/docs из файлов, а шлёт операции buildin-comments.sh
общим хелпером transaction(). Своего конверта транзакции здесь намеренно нет:
две копии разошлись бы молча. Режимы и их аргументы — в Usage ниже.

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

Внутри блока режется только сегмент, у которого text — сам видимый текст:
обычный текст и ссылка. Дата и инлайн-формула хранят в text не то, что видно
на странице: у даты заглушку «‣», у формулы исходник LaTeX. Разрез формулы
проверен живьём: x^{2} по «{2» превратилась в три формулы, и Buildin рисует
все три ошибкой разбора. Такие объекты комментируются только целиком.

Ответ в тред — запись comment и listAfter в список comments треда, а резолв
треда (и его отмена) — одна узкая запись поля resolved. Ровно это шлёт UI:
ни ответ, ни резолв не трогают ни сегменты, ни список тредов блока.

Usage:
    buildin-comment.py [--occurrence=N] [--mention=<uuid>... --members=<file>] [--page=<page_id>] --
                       <doc_json> <block_id> <anchor> <text> <now_ms> <user_id>
    buildin-comment.py --verdict -- <before_json> <after_json> <block_id> <discussion_id>
    buildin-comment.py --reply [--mention=<uuid>... --members=<file>] --
                       <doc_json> <discussion_id> <text> <now_ms> <user_id>
    buildin-comment.py --reply-verdict -- <after_json> <discussion_id> <comment_id>
    buildin-comment.py --resolve=true|false -- <doc_json> <discussion_id>
    buildin-comment.py --resolve-verdict=true|false -- <after_json> <discussion_id>
    buildin-comment.py --check-rollback -- <rollback_file>
    buildin-comment.py --rollback-plan [--narrow] --user=<uuid> -- <rollback_file> <doc_json>
    buildin-comment.py --rollback-verdict -- <after_json> <ops_json>

<doc_json> — файл с ответом /api/docs (или «-» для stdin).
--occurrence N — какое вхождение якоря выделить (1-based), когда их несколько.
--mention — uuid участника, которого упомянуть в начале сообщения (можно
            несколько); --members — файл с ответом /api/spaces/<space>/members
            для их сверки.
--page — страница блока: как и UI, комментарий обновляет её updatedAt.
"""
import copy
import json
import re
import sys
import uuid


class AnchorError(Exception):
    """Якорь не удалось выделить — сообщение уже человекочитаемое."""


class ThreadError(Exception):
    """Тред не годится для операции — сообщение уже человекочитаемое."""


class RollbackError(Exception):
    """Файл не похож на откат команд комментариев — сообщение уже человекочитаемое."""


class MentionError(Exception):
    """Упоминание не прошло сверку с участниками — сообщение уже человекочитаемое."""


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

# Типы инлайн-сегментов — проверено живьём на черновой странице.
SEGMENT_NAMES = {
    0: "текст",
    1: "дата",
    3: "ссылка",
    4: "упоминание страницы",
    7: "упоминание человека",
    8: "инлайн-формула",
}

# Резать можно только то, у чего text — ровно видимый текст: каждый кусок
# разреза остаётся тем же текстом с тем же форматированием и ссылкой.
CUTTABLE_SEGMENTS = {0, 3}

# Цельные объекты: их text — не то, что видит человек, и разрез их ломает, а
# тред на объект целиком Buildin подсвечивает как обычно (цитатой в треде
# станет сам text). Упоминаний (4, 7) здесь нет намеренно: их text пуст, и
# якорь в них не попадает в принципе.
WHOLE_SEGMENTS = {
    1: "в text лежит заглушка «‣», а видимую дату Buildin рисует из startDate",
    8: "в text лежит исходник LaTeX, и разрез ломает формулу",
}


def segment_text(segments):
    """Видимый текст блока: конкатенация сегментов."""
    return "".join(s.get("text", "") for s in (segments or []))


# Невидимые пробелы: в типографированных русских текстах NBSP стоит перед тире и
# после коротких предлогов. Якорь с обычным пробелом в таком месте не найдётся, а
# в сообщении оба пробела выглядят одинаково — агент будет повторять тот же якорь.
INVISIBLE = {
    "\u00a0": "NBSP",
    "\u202f": "узкий NBSP",
    "\u2007": "цифровой пробел",
    "\u200b": "нулевой пробел",
    "\ufeff": "BOM",
}


def invisible_note(text):
    """Строка-предупреждение о невидимых символах в тексте, либо пустая."""
    found = {}
    for i, ch in enumerate(text):
        if ch in INVISIBLE:
            found.setdefault(INVISIBLE[ch], []).append(i)
    if not found:
        return ""
    parts = ["%s на позициях %s" % (name, ", ".join(map(str, pos))) for name, pos in sorted(found.items())]
    return "\nВнимание, в тексте есть невидимые символы: %s." % "; ".join(parts)


def segment_kind(s):
    """Подпись сегмента, чей text — не видимый текст, либо None.

    Без неё разбор показывает у даты голую «‣», а у упоминания пустые кавычки,
    и по нему не понять, почему видимая на странице дата якорем не находится.
    """
    t = s.get("type")
    if t in CUTTABLE_SEGMENTS:
        return None
    if t == 1:
        when = " ".join(x for x in (s.get("startDate"), s.get("startTime")) if x)
        return "дата %s" % when if when else "дата"
    if t is None:
        return "без типа"
    return SEGMENT_NAMES.get(t, "тип %s" % t)


def describe_segments(segments):
    """Разбор сегментов для сообщения об ошибке: индекс, текст, форматирование."""
    lines = []
    for i, s in enumerate(segments or []):
        marks = [k for k, v in (s.get("enhancer") or {}).items() if v]
        if s.get("url"):
            marks.append("link")
        kind = segment_kind(s)
        if kind:
            marks.append(kind)
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
            "Текст блока: «%s»%s\nСегменты:\n%s\n"
            "Сверьте фразу с текстом блока (важны регистр и пробелы)."
            % (full, invisible_note(full), describe_segments(segments))
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
            "Текст блока: «%s»%s\nВхождения:\n%s\n"
            "Удлините якорь до однозначного или выберите вхождение: --occurrence=N."
            % (len(chosen), full, invisible_note(full), "\n".join(listing))
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


def check_segment_type(segments, index, pos, anchor):
    """Отказать, если якорь режет сегмент, который резать нельзя.

    Гард того же класса, что и гард по типу блока, но на уровень ниже: разрез
    инлайн-формулы команда выполняет и рапортует успех, проверка после записи
    его не ловит — сегмент реально несёт discussions, — а на странице вместо
    формулы ошибки разбора.

    Список закрытый по той же причине, что и PROSE_TYPES: новый инлайн-объект
    Buildin с непрозрачным text должен отвергаться, пока его не проверят живьём.
    """
    seg = segments[index]
    stype = seg.get("type")
    if stype in CUTTABLE_SEGMENTS:
        return
    text = seg.get("text", "")
    if stype in WHOLE_SEGMENTS:
        if pos == 0 and len(anchor) == len(text):
            return
        raise AnchorError(
            "Якорь режет сегмент [%d] (%s): %s.\n"
            "Такой объект комментируется только целиком — якорем «%s».\n"
            "Сегменты:\n%s"
            % (index, SEGMENT_NAMES[stype], WHOLE_SEGMENTS[stype], text, describe_segments(segments))
        )
    kind = "типа %s" % stype if stype is not None else "без типа"
    raise AnchorError(
        "Якорь попал в сегмент [%d] %s — такой сегмент команда не режет: нет уверенности, "
        "что его text — видимый на странице текст и что разрез его не сломает.\n"
        "Сегменты:\n%s\n"
        "Если этот тип показывает на странице ровно свой text — добавьте его в CUTTABLE_SEGMENTS."
        % (index, kind, describe_segments(segments))
    )


def comment_segments(text, mentions=()):
    """Текст сообщения сегментами — в таком виде его хранит Buildin.

    Упоминание — сегмент type 7 с uuid человека и пустым text: ровно так его
    пишет UI (снято с живой страницы). Упоминания встают в начало, как
    «@Имя, …» в UI, и разделяются пробелом, как их набирает человек.

    Ограничения намеренные. Только в начале: позвать человека — это всё, что
    нужно агенту, а разметка упоминаний внутри текста потребовала бы своего
    синтаксиса и своего экранирования. Только люди: упоминание страницы
    (type 4) никого не уведомляет, а ссылка на страницу пишется текстом.
    """
    segs = []
    for uid in mentions:
        if segs:
            segs.append({"text": " ", "type": 0, "enhancer": {}})
        segs.append({"text": "", "type": 7, "uuid": uid, "enhancer": {}})
    lead = " " if mentions else ""
    return segs + [{"text": lead + text, "type": 0, "enhancer": {}}]


def check_mentions(mentions, members_doc):
    """Упоминания без повторов, сверенные с участниками пространства.

    Отдельного сообщения на уведомление UI при упоминании не шлёт ни по HTTP,
    ни по WebSocket — только сегмент в тексте (перехвачено на живой странице), —
    поэтому опечатка в uuid дала бы упоминание никого, и тот, кого хотели
    позвать, ничего не узнал бы.
    """
    if not mentions:
        return []
    data = members_doc.get("data") if isinstance(members_doc, dict) else None
    if not isinstance(data, list):
        raise MentionError("список участников пространства не получен — упоминание не проверить.")
    known = {(m.get("user") or {}).get("uuid") for m in data if isinstance(m, dict)}
    unknown = [u for u in mentions if u not in known]
    if unknown:
        raise MentionError(
            "среди участников пространства нет %s.\n"
            "Участники и их uuid: buildin-pages.sh members <page>."
            % ", ".join(unknown)
        )
    return list(dict.fromkeys(mentions))


def comment_record(comment_id, space_id, discussion_id, segments, who):
    """Запись comment — одна форма на первое сообщение треда и на ответ в него.

    Две копии разошлись бы молча: ответ, собранный иначе, чем первое
    сообщение, всплыл бы только в UI.
    """
    return {
        "id": comment_id,
        "command": "set",
        "table": "comment",
        "path": [],
        "args": dict(
            uuid=comment_id, spaceId=space_id, parentId=discussion_id,
            version=1, status=1, text=segments, **who
        ),
    }


def build_ops(block, block_id, anchor, text, now, user_id, occurrence=None, mentions=(), page_id=None):
    """Операции транзакции и операции отката. Без сети и без записи на диск."""
    if not text:
        raise AnchorError("Текст комментария пустой — нечего отправлять.")

    space_id = block.get("spaceId", "")
    data = block.get("data") or {}
    segments = data.get("segments") or []

    check_block_type(block, segments)
    index, pos = find_anchor(segments, anchor, occurrence)
    check_segment_type(segments, index, pos, anchor)
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
        comment_record(comment_id, space_id, discussion_id, comment_segments(text, mentions), who),
        # Узко: только segments. Полный data стирал бы чужие ключи блока.
        {"id": block_id, "command": "update", "table": "block", "path": ["data"],
         "args": {"segments": new_segments}},
        # Узко: списочная операция. Полный список discussions выбивал бы чужие треды.
        {"id": block_id, "command": "listAfter", "table": "block", "path": ["discussions"],
         "args": {"uuid": discussion_id}},
        {"id": block_id, "command": "update", "table": "block", "path": [],
         "args": {"updatedAt": now, "updatedBy": user_id}},
    ]
    if page_id:
        # Ровно как UI (снято с живой страницы): комментарий отмечается правкой
        # и самой страницы, а не только блока.
        ops.insert(-1, {"id": page_id, "command": "update", "table": "block", "path": [],
                        "args": {"updatedAt": now, "updatedBy": user_id}})

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
    # Сверка для файла отката: сегменты, какими их оставит наша запись, — по
    # ним comment-rollback узнает, не правил ли блок кто-то ещё. Собирается
    # здесь, рядом с check_rollback, который её проверяет: соберёт bash —
    # переименование поля с одной стороны всплывёт только в момент отката.
    check = {"page": page_id, "block": block_id, "segments": new_segments}
    return {"ops": ops, "rollback": rollback, "rollback_records": retire, "check": check,
            "discussion": discussion_id, "comment": comment_id}


def doc_data(doc):
    """data из ответа /api/docs; не объект — пустая страница.

    Разбор после записи не должен падать на странном ответе: упавший разбор
    оставляет трейсбек вместо понятного «исход неизвестен»."""
    data = doc.get("data") if isinstance(doc, dict) else None
    return data if isinstance(data, dict) else {}


def read_block(doc, block_id):
    """Блок из ответа /api/docs, либо None, если его там нет."""
    blocks = doc_data(doc).get("blocks") or {}
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


def find_thread(doc, discussion_id):
    """Тред из ответа /api/docs, либо None, если его там нет."""
    return (doc_data(doc).get("discussions") or {}).get(discussion_id)


def live_thread(doc, discussion_id):
    """Тред, с которым можно работать: он есть на странице и не удалён.

    Читать тред по id API не умеет — /api/discussions/<id> и соседние адреса
    отвечают 404, — поэтому тред ищется в ответе /api/docs страницы. Отсюда и
    страница в аргументах команд, работающих с тредом.
    """
    thread = find_thread(doc, discussion_id)
    if thread is None:
        raise ThreadError(
            "Треда %s на странице нет.\n"
            "Id треда — строка «Тред <uuid>» в выводе `buildin-pages.sh comments`, "
            "а страница нужна та, где висит тред." % discussion_id
        )
    if thread.get("status") == -1:
        raise ThreadError("Тред %s удалён." % discussion_id)
    return thread


def build_reply_ops(thread, discussion_id, text, now, user_id, mentions=(), page_id=None):
    """Операции ответа в тред и их откат. Без сети и без записи на диск.

    Ровно то, что шлёт UI (снято с живой страницы): запись comment и listAfter
    в список comments треда, сам тред и блок ответ не трогает. Операция над
    списком узкая: перезапись полного списка выбила бы параллельный ответ.
    """
    if not text:
        raise ThreadError("Текст ответа пустой — нечего отправлять.")
    # Закрытый тред Buildin на странице не показывает — подсветка и бейдж
    # пропадают, — и ответ в нём легко не заметить никому. Тихий успех хуже
    # отказа: открыть тред агент может сам, явной командой.
    if thread.get("resolved"):
        raise ThreadError(
            "Тред %s закрыт: на странице его не видно, и ответ в нём легко пропустить.\n"
            "Сначала откройте тред: buildin-pages.sh comment-unresolve <page> %s"
            % (discussion_id, discussion_id)
        )
    space_id = thread.get("spaceId", "")
    comment_id = str(uuid.uuid4())
    who = {"createdAt": now, "createdBy": user_id, "updatedAt": now, "updatedBy": user_id}
    ops = [
        comment_record(comment_id, space_id, discussion_id, comment_segments(text, mentions), who),
        {"id": discussion_id, "command": "listAfter", "table": "discussion", "path": ["comments"],
         "args": {"uuid": comment_id}},
    ]
    # Откат по образцу отката comment: сообщение вон из списка треда и гасится
    # (status -1), чтобы после отката его не показывала и команда comments.
    rollback = [
        {"id": discussion_id, "command": "listRemove", "table": "discussion", "path": ["comments"],
         "args": {"uuid": comment_id}},
        {"id": comment_id, "command": "update", "table": "comment", "path": [],
         "args": {"status": -1, "updatedAt": now, "updatedBy": user_id}},
    ]
    # Сверка — страница: по ней comment-rollback проверит, что гасит именно ваш ответ.
    return {"ops": ops, "rollback": rollback, "check": {"page": page_id}, "comment": comment_id,
            "discussion": discussion_id, "space": space_id}


def thread_verdict(after, discussion_id, landed):
    """Исход записи в тред по снимку после неё — общий для ответа и резолва.

      unverified  — треда нет в ответе: конверт ошибки или чужая страница;
      not-applied — тред на месте, а landed(тред) ложно: запись не легла;
      ok          — запись видна в треде.

    У ответа not-applied надёжен: listAfter аддитивен, и параллельный ответ наш
    id из списка не выбивает. У резолва флаг мог бы вернуть и чужой резолв, но
    тогда повтор всё равно безопасен — он идемпотентен.
    """
    thread = find_thread(after, discussion_id)
    if thread is None:
        return "unverified"
    return "ok" if landed(thread) else "not-applied"


def build_resolve_ops(thread, discussion_id, resolved):
    """Операция резолва треда или его отмены; пустой список — тред уже в нужном состоянии.

    Ровно то, что шлёт UI (снято с живой страницы): одна узкая запись поля
    resolved, даже без updatedAt. Сегменты и список тредов блока резолв не
    трогает — подсветку закрытого треда Buildin просто не рисует.

    Повторная запись того же значения не нужна никому, а version треда она
    всё равно подняла бы, поэтому вместо операции пустой список.
    """
    if bool(thread.get("resolved")) == resolved:
        return []
    return [{"id": discussion_id, "command": "update", "table": "discussion", "path": [],
             "args": {"resolved": resolved}}]


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def rollback_op_problem(op):
    """Чем операция не похожа на операцию отката comment/comment-reply, либо None.

    Список закрытый: откат только возвращает сегменты блока, убирает треды и
    сообщения из списков и гасит записи (status -1). Всё прочее отвергается —
    иначе тонкая команда отката стала бы способом отправить произвольную
    транзакцию, а файл по пути из чужого текста мог бы оказаться чем угодно.
    """
    if not isinstance(op, dict):
        return "не объект"
    table, command, path, args = op.get("table"), op.get("command"), op.get("path"), op.get("args")
    if not UUID_RE.match(str(op.get("id", ""))):
        return "id не UUID"
    if not isinstance(args, dict):
        return "args не объект"
    if command == "listRemove":
        if (table, path) not in (("block", ["discussions"]), ("discussion", ["comments"])):
            return "listRemove не из списка тредов блока и не из списка сообщений треда"
        if set(args) != {"uuid"} or not UUID_RE.match(str(args["uuid"])):
            return "listRemove без uuid записи"
        return None
    if command == "update" and path == ["data"]:
        if table != "block" or set(args) != {"segments"} or not isinstance(args["segments"], list):
            return "update data — не возврат segments блока"
        return None
    if command == "update" and path == []:
        if table == "block":
            # Блоку откат ставит только метку правки. status у блока — это
            # архивация страницы (ровно так её делает archive), и подложенный
            # файл отката не должен уметь её повторить.
            if not set(args) <= {"updatedAt", "updatedBy"}:
                return "update блока меняет не только метки времени: %s" % sorted(args)
            return None
        if table not in ("discussion", "comment"):
            return "update таблицы %s" % table
        if not set(args) <= {"status", "updatedAt", "updatedBy"}:
            return "update меняет не только status и метки времени: %s" % sorted(args)
        if "status" in args and args["status"] != -1:
            return "status %r: откат записи только гасит" % args["status"]
        return None
    return "%s по path %s в откате не бывает" % (command, path)


def check_rollback(body):
    """(spaceId, операции, сверка) из файла отката, либо RollbackError с причиной.

    Сверка — служебный ключ check: страница, а у отката comment ещё блок и
    его сегменты после нашей записи. У файлов, записанных до сверки, его нет.
    """
    txs = body.get("transactions") if isinstance(body, dict) else None
    if not isinstance(txs, list) or len(txs) != 1 or not isinstance(txs[0], dict):
        raise RollbackError(
            "в файле нет ровно одной транзакции — это не файл отката comment или comment-reply.")
    space, ops = txs[0].get("spaceId"), txs[0].get("operations")
    if not isinstance(space, str) or not space:
        raise RollbackError("у транзакции в файле нет spaceId.")
    if not isinstance(ops, list) or not ops:
        raise RollbackError("в транзакции нет операций.")
    for i, op in enumerate(ops):
        problem = rollback_op_problem(op)
        if problem:
            raise RollbackError(
                "операция [%d] не из отката команд комментариев: %s.\n  %s"
                % (i, problem, json.dumps(op, ensure_ascii=False)[:300]))
    check = body.get("check")
    if check is not None and not (
            isinstance(check, dict) and UUID_RE.match(str(check.get("page", "")))
            and (("block" not in check and "segments" not in check)
                 or (UUID_RE.match(str(check.get("block", ""))) and isinstance(check.get("segments"), list)))):
        raise RollbackError("служебный ключ check не по формату: нужна page, а block и segments — вместе.")
    for op in ops:
        if op.get("path") == ["data"]:
            check_segments_restore(op, check, ops)
    check_rollback_shape(ops, check)
    return space, ops, check


def retired_records(ops):
    """(таблица, id) записей, которые файл гасит (status -1)."""
    return {(op["table"], op["id"]) for op in ops
            if op["command"] == "update" and op["path"] == [] and op["args"].get("status") == -1}


def check_rollback_shape(ops, check):
    """Операции обязаны складываться в откат своих записей — иначе RollbackError.

    Закрытого списка операций мало: из разрешённых собирается и чужое. Файл из
    одних listRemove снимал бы чужие треды и ответы, ничего своего не гася, а
    проверка авторства смотрит именно на гасимые записи. Поэтому:
      - без гасимой записи файл — не откат: настоящий её гасит всегда;
      - listRemove убирает из списка только ту запись, которую файл гасит;
      - метку правки получает только блок, с которого файл снимает тред, или
        блок из сверки.
    Чья запись и с того ли списка её снимают, видно только по странице —
    это проверяет rollback_plan.
    """
    retired = retired_records(ops)
    if not retired:
        raise RollbackError("в файле нет гасимых записей: откат comment и comment-reply "
                            "всегда гасит свою запись.")
    blocks = {(check or {}).get("block")}
    for op in ops:
        if op["command"] != "listRemove":
            continue
        item = ("discussion" if op["table"] == "block" else "comment", op["args"]["uuid"])
        if item not in retired:
            raise RollbackError("listRemove убирает из списка %s, а файл эту запись не гасит." % item[1])
        if op["table"] == "block":
            blocks.add(op["id"])
    for op in ops:
        if op["table"] == "block" and op["command"] == "update" and op["path"] == [] \
                and op["id"] not in blocks:
            raise RollbackError("метку правки файл ставит блоку %s, с которого ничего не снимает." % op["id"])


def is_inverse_split(restored, after, discussion_id):
    """after — ровно разрез restored под тред discussion_id, как его делает comment.

    Разрез повторяется на возвращаемых сегментах и сравнивается со сверкой
    целиком, со всеми полями: сверка текста пропустила бы подменённую ссылку и
    снятую чужую подсветку."""
    marked = [i for i, seg in enumerate(after) if discussion_id in (seg.get("discussions") or [])]
    if len(marked) != 1:
        return False
    anchor = after[marked[0]].get("text", "")
    hit = _locate(restored, len(segment_text(after[:marked[0]])), len(anchor))
    return hit is not None and split_segments(restored, hit[0], hit[1], anchor, discussion_id) == after


def check_segments_restore(op, check, ops):
    """Возврат сегментов допустим только тот, что пишет comment, — иначе RollbackError.

    Операция над сегментами — запись произвольного содержимого в блок, и одна
    её форма в файле ничего не гарантирует. Настоящий откат возвращает тот
    блок, по которому сверка, вместе с гашением своего треда и ровно в том
    виде, из которого comment вырезал якорь. Поэтому без сверки возврат не
    применяется вовсе, а со сверкой — только если повторный разрез даёт сверку.
    """
    if check is None or "block" not in check:
        # Обходного пути отказ не подсказывает: отправленный вручную файл
        # миновал бы все проверки отката.
        raise RollbackError(
            "возврат сегментов без сверки (ключ check) не применяется: сверить блок не с "
            "чем, файл записан до появления сверки. Откат не применён; вручную его не "
            "отправляйте — разметку блока можно вернуть в интерфейсе Buildin.")
    if op["id"] != check["block"]:
        raise RollbackError("сегменты возвращаются блоку %s, а сверка — по блоку %s."
                            % (op["id"], check["block"]))
    threads = [rid for table, rid in retired_records(ops) if table == "discussion"]
    if len(threads) != 1:
        raise RollbackError("возврат сегментов допустим только вместе с гашением одного своего треда.")
    if not is_inverse_split(op["args"]["segments"], check["segments"], threads[0]):
        raise RollbackError("возврат сегментов не обратен разрезу comment: откат вернул бы блоку "
                            "не ту разметку, из которой вырезали якорь.")


def rollback_freshness(check, doc):
    """Можно ли вернуть снапшот блока — по ответу /api/docs его страницы.

      fresh      — сегменты блока те же, что записал comment: снапшот можно вернуть;
      stale      — блок меняли после нас: снапшот стёр бы чужие правки и подсветку;
      unverified — блока в ответе нет: конверт ошибки, блок удалён или не та страница.
    """
    block = read_block(doc, check["block"])
    if block is None:
        return "unverified"
    return "fresh" if ((block.get("data") or {}).get("segments") or []) == check["segments"] else "stale"


def rollback_plan(body, doc, user_id, narrow, path):
    """Что отправить на откат и можно ли: по файлу, текущей странице и пользователю.

    Возвращает dict(apply, reason, hint, space, ops). Отказ — когда откат
    стёр бы чужое:
      - записей из файла на странице нет — проверить нечего;
      - гасимые записи созданы не вами — так подложенный файл погасил бы
        чужой тред;
      - в гасимом треде есть живые сообщения, кроме вашего: тред гасится
        целиком, и ответ коллеги пропал бы молча. Сегменты на это не
        реагируют, поэтому сверка свежести такого не видит;
      - полный откат, а блок с тех пор меняли или его нет.
    Проверки ответов и авторства идут и для --narrow: он тоже гасит тред.
    """
    space, ops, check = check_rollback(body)

    def refuse(reason, hint=""):
        return {"apply": False, "reason": reason, "hint": hint, "space": space, "ops": []}

    if check is None:
        return refuse("в файле нет сверки (ключ check): он записан до неё, и проверить на странице нечего.")
    data = doc_data(doc)
    tables = {"discussion": data.get("discussions") or {}, "comment": data.get("comments") or {}}
    retired = sorted(retired_records(ops))
    missing = [rid for table, rid in retired if rid not in tables[table]]
    if missing:
        return refuse("записей из файла на странице нет (%s): откат уже применён или страница не та."
                      % ", ".join(missing))
    foreign = [rid for table, rid in retired if tables[table][rid].get("createdBy") != user_id]
    if foreign:
        return refuse("в файле чужие записи (%s): откат гасит только созданное вами." % ", ".join(foreign))
    # Свою запись снимают только с её списка: тред — с блока из его parentId,
    # ответ — с треда из его parentId. Сообщение, которое файл не убирает из
    # списка, гасится только вместе со своим тредом.
    unlisted = set()
    for op in ops:
        if op["command"] != "listRemove":
            continue
        item_table = "discussion" if op["table"] == "block" else "comment"
        rid = op["args"]["uuid"]
        unlisted.add(rid)
        if tables[item_table][rid].get("parentId") != op["id"]:
            return refuse("запись %s не из списка %s: откат убирал бы её не оттуда." % (rid, op["id"]))
    threads = {rid for table, rid in retired if table == "discussion"}
    for table, rid in retired:
        if table == "comment" and rid not in unlisted and tables["comment"][rid].get("parentId") not in threads:
            return refuse("сообщение %s не из гасимого треда: файл гасит его, не убирая из списка." % rid)
    if check.get("block") and any(tables["discussion"][t].get("parentId") != check["block"] for t in threads):
        return refuse("гасимый тред висит не на блоке из сверки %s." % check["block"])
    ours = {rid for table, rid in retired if table == "comment"}
    for table, rid in retired:
        if table != "discussion":
            continue
        live = [c for c in tables["discussion"][rid].get("comments") or []
                if c not in ours and (tables["comment"].get(c) or {}).get("status") != -1]
        resolve = ("Закрыть тред, сохранив обсуждение: buildin-pages.sh comment-resolve %s %s"
                   % (check["page"], rid))
        foreign = [c for c in live if (tables["comment"].get(c) or {}).get("createdBy") != user_id]
        if foreign:
            return refuse(
                "в треде %s есть чужие сообщения (%d): откат погасил бы их вместе с тредом."
                % (rid, len(foreign)), resolve)
        # Свои ответы откатываются своими файлами: сначала они, потом тред. Так
        # агент, ответивший в собственный тред, видит выход, а не отсылку к
        # «чужим» сообщениям (найдено живьём).
        if live:
            return refuse(
                "в треде %s есть ваши ответы (%d): откат погасил бы их вместе с тредом."
                % (rid, len(live)),
                "Сначала откатите ответы — их файлы в строке «rollback:» вывода comment-reply, "
                "потом этот файл. Или " + resolve[0].lower() + resolve[1:])
    if not narrow and any(op["path"] == ["data"] for op in ops):
        fresh = rollback_freshness(check, doc)
        if fresh != "fresh":
            reason = ("блок изменился после комментария — полный откат вернул бы старый снапшот "
                      "и стёр чужие правки и подсветку." if fresh == "stale"
                      else "блока из файла отката нет на странице — сверить не с чем.")
            return refuse(reason, "Снять только свой тред, не трогая сегменты: "
                                  "buildin-pages.sh comment-rollback %s --narrow" % path)
    # Узкий откат снимает тред со списка его блока. Блока нет — снимать не с
    # чего: POST ушёл бы вслепую и кончился кодом 2, а отказ до записи точнее.
    if narrow:
        gone = [t for t in threads if read_block(doc, tables["discussion"][t].get("parentId")) is None]
        if gone:
            return refuse("блока треда %s на странице нет — снимать тред не с чего." % ", ".join(gone))
    # Узкий откат — без возврата сегментов. Осиротевший id треда на сегменте
    # Buildin не подсвечивает (проверено живьём), поэтому их можно не трогать.
    chosen = [op for op in ops if op["path"] != ["data"]] if narrow else ops
    # Открытые гасимые треды команда сначала закрывает и сверяет заново: ответ
    # коллеги, пришедший в окне перед откатом, иначе не увидеть — погашенный
    # тред /api/docs не отдаёт, а закрытый отдаёт (проверено живьём).
    open_threads = sorted(t for t in threads if not tables["discussion"][t].get("resolved"))
    return {"apply": True, "reason": "", "hint": "", "space": space, "ops": chosen,
            "open_threads": open_threads}


def rollback_verdict(after, ops):
    """Исход отката по снимку страницы после записи.

    Сверяется то, что видно на странице: id, убранные из списков, и у полного
    отката — вернувшиеся сегменты блока. Status погашенных записей не
    сверяется: /api/docs не обязан их возвращать.

      unverified  — записи-владельца списка или блока нет в ответе (конверт
                    ошибки, не та страница) либо легла лишь часть изменений.
                    Транзакция атомарна, так что смесь значит чужую правку
                    после отката, и что именно легло — неизвестно;
      not-applied — не легло ни одно изменение: откат не применился, повтор безопасен;
      ok          — все изменения на странице.
    """
    data = doc_data(after)
    owners = {"block": data.get("blocks") or {}, "discussion": data.get("discussions") or {}}
    landed = []
    for op in ops:
        if op["command"] == "listRemove":
            owner = owners[op["table"]].get(op["id"])
            if owner is None:
                return "unverified"
            landed.append(op["args"]["uuid"] not in (owner.get(op["path"][0]) or []))
        elif op["path"] == ["data"]:
            block = owners["block"].get(op["id"])
            if block is None:
                return "unverified"
            landed.append(((block.get("data") or {}).get("segments") or []) == op["args"]["segments"])
    if all(landed):
        return "ok"
    return "not-applied" if not any(landed) else "unverified"


def load_doc(path):
    """Ответ /api/docs или пустой документ, если это не JSON (конверт ошибки)."""
    try:
        return json.loads(sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read())
    except ValueError:
        return {}


def mentions_from(opts):
    """Упоминания из --mention, сверенные с ответом /members из --members.

    Сверка идёт после проверки блока или треда: если их на странице нет, о
    том и надо сказать, а не о пустом списке участников.
    """
    members = load_doc(opts["members"]) if opts["members"] else None
    return check_mentions(opts["mentions"], members)


def build_comment(args, opts):
    """Режим по умолчанию: операции нового треда на фразе блока."""
    doc_json, block_id, anchor, text, now, user_id = args
    block = read_block(load_doc(doc_json), block_id)
    if block is None:
        raise SystemExit(
            "Error: блок %s не найден на странице. "
            "Идентификаторы блоков — поле uuid в выводе `buildin-pages.sh get-blocks`." % block_id
        )
    return build_ops(block, block_id, anchor, text, int(now), user_id, opts["occurrence"],
                     mentions_from(opts), opts["page"])


# Обработчики режимов: каждый получает позиционные аргументы и опции и сам
# печатает результат.

def run_build(args, opts):
    # Без ensure_ascii=False: вывод разбирает json.load, ему \uXXXX всё
    # равно, а печать не-ASCII падает под не-UTF-8 локалью (LC_ALL=C).
    print(json.dumps(build_comment(args, opts)))


def run_verdict(args, opts):
    before_path, after_path, block_id, ours = args
    status, lost = verdict(load_doc(before_path), load_doc(after_path), block_id, ours)
    print(status)
    print(" ".join(lost))


def run_reply(args, opts):
    doc_json, discussion_id, text, now, user_id = args
    thread = live_thread(load_doc(doc_json), discussion_id)
    print(json.dumps(build_reply_ops(thread, discussion_id, text, int(now), user_id,
                                     mentions_from(opts), opts["page"])))


def run_reply_verdict(args, opts):
    after_path, discussion_id, comment_id = args
    print(thread_verdict(load_doc(after_path), discussion_id,
                         lambda thread: comment_id in (thread.get("comments") or [])))


def run_resolve(args, opts):
    doc_json, discussion_id = args
    thread = live_thread(load_doc(doc_json), discussion_id)
    ops = build_resolve_ops(thread, discussion_id, opts["resolved"])
    print(json.dumps({"ops": ops, "space": thread.get("spaceId", "")}))


def run_resolve_verdict(args, opts):
    after_path, discussion_id = args
    print(thread_verdict(load_doc(after_path), discussion_id,
                         lambda thread: bool(thread.get("resolved")) == opts["resolved"]))


def run_check_rollback(args, opts):
    # Проверка файла без сети: подложенный или битый отвергается до запросов.
    space, ops, check = check_rollback(load_doc(args[0]))
    print(json.dumps({"space": space, "ops": ops, "check": check}))


def run_rollback_plan(args, opts):
    print(json.dumps(rollback_plan(load_doc(args[0]), load_doc(args[1]), opts["user"],
                                   opts["narrow"], args[0])))


def run_rollback_verdict(args, opts):
    after_path, ops_path = args
    # Операции — список, не ответ /api/docs: load_doc превратил бы их в {}.
    print(rollback_verdict(load_doc(after_path), json.load(open(ops_path, encoding="utf-8"))))


# Режимы билдера — одной таблицей: режим → (число позиционных после «--»,
# обработчик, берёт ли флаг значение true|false). Новый режим — одна строка
# здесь: раньше он регистрировался в трёх местах, и забытое всплывало только
# при вызове. build — режим по умолчанию, своего флага у него нет.
MODES = {
    "build": (6, run_build, False),                     # <doc_json> <block_id> <anchor> <text> <now_ms> <user_id>
    "verdict": (4, run_verdict, False),                 # <before_json> <after_json> <block_id> <discussion_id>
    "reply": (5, run_reply, False),                     # <doc_json> <discussion_id> <text> <now_ms> <user_id>
    "reply-verdict": (3, run_reply_verdict, False),     # <after_json> <discussion_id> <comment_id>
    "resolve": (2, run_resolve, True),                  # <doc_json> <discussion_id>
    "resolve-verdict": (2, run_resolve_verdict, True),  # <after_json> <discussion_id>
    "check-rollback": (1, run_check_rollback, False),   # <rollback_file>
    "rollback-plan": (2, run_rollback_plan, False),     # <rollback_file> <doc_json>
    "rollback-verdict": (2, run_rollback_verdict, False),  # <after_json> <ops_json>
}


def parse_args(argv):
    """(режим, позиционные, опции); ошибка разбора — SystemExit с причиной."""
    positional, end_of_opts, mode = [], False, "build"
    opts = {"occurrence": None, "resolved": None, "mentions": [], "members": None, "page": None,
            "narrow": False, "user": None}
    for a in argv:
        flag, has_value, raw = a.partition("=")
        if end_of_opts or not a.startswith("--"):
            positional.append(a)
        elif a == "--":
            # Всё после «--» — значения. Без этого якорь или текст с ведущими
            # дефисами («--force», «-- не согласен») не доходит до билдера
            # никакой формой ввода: они едут через argv, в том числе из @file.
            end_of_opts = True
        elif flag[2:] in MODES and flag != "--build":
            mode = flag[2:]
            if MODES[mode][2]:
                if raw not in ("true", "false"):
                    raise SystemExit("Error: %s ожидает true или false, получено: %r" % (flag, raw))
                opts["resolved"] = raw == "true"
            elif has_value:
                raise SystemExit("Error: неизвестный флаг: %s" % a)
        elif flag == "--occurrence" and has_value:
            if not raw.isdigit() or int(raw) < 1:
                raise SystemExit("Error: --occurrence ожидает целое число >= 1, получено: %r" % raw)
            opts["occurrence"] = int(raw)
        elif flag == "--mention" and has_value:
            opts["mentions"].append(raw)
        elif flag in ("--members", "--page", "--user") and has_value:
            opts[flag[2:]] = raw
        elif a == "--narrow":
            opts["narrow"] = True
        else:
            raise SystemExit("Error: неизвестный флаг: %s" % a)
    if len(positional) != MODES[mode][0]:
        raise SystemExit(__doc__.strip())
    return mode, positional, opts


def main():
    mode, args, opts = parse_args(sys.argv[1:])
    try:
        MODES[mode][1](args, opts)
    except (AnchorError, ThreadError) as e:
        raise SystemExit("Error: %s" % e)
    except RollbackError as e:
        raise SystemExit("Error: файл отката отвергнут, %s" % e)
    except MentionError as e:
        raise SystemExit("Error: упоминание отвергнуто — %s" % e)


if __name__ == "__main__":
    main()
