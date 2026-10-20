#!/usr/bin/env python3
"""Инлайн-сегменты Buildin текстом — общий код читателей read и comments.

У части сегментов text — не то, что видно на странице, и печатать его нельзя:
  1 — дата: text — заглушка «‣», сама дата в startDate/startTime/endDate/endTime;
  4 — упоминание страницы: text пуст, есть только uuid страницы;
  7 — упоминание человека: text пуст, есть только uuid участника.
Поля сняты с живой страницы. Раньше у каждого читателя была своя копия этого
кода, и копии разошлись: comments упоминания печатал, read их терял.

Названия страниц и ники спрашиваются у API лениво и по разу: страница без
упоминаний не делает ни одного лишнего запроса.
"""
import json
import re
import subprocess

MEMBERS_NOTE = "Участники пространства недоступны: вместо ников — первые 8 символов uuid."
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


class Inline:
    """Печать сегментов одной страницы: blocks — из ответа /api/docs, space_id —
    её пространство, buildin_sh — путь к клиенту API."""

    def __init__(self, blocks, space_id, buildin_sh):
        self.blocks = blocks or {}
        self.space_id = space_id or ""
        self.buildin_sh = buildin_sh
        self._nicknames = None
        self._pages = {}
        # Список участников не получен: короткий id тогда не отличить от
        # участника без ника, и читатели об этом пишут.
        self.members_unavailable = False

    def _get(self, endpoint):
        """data из ответа клиента. При ошибке он печатает конверт без data или
        ничего, и то и другое даёт None."""
        run = subprocess.run([self.buildin_sh, "GET", endpoint], capture_output=True, text=True)
        try:
            return json.loads(run.stdout).get("data")
        except ValueError:
            return None

    def name(self, uuid):
        """Ник участника, а без ника — короткий id. Почту не печатаем: вывод
        целиком уходит в контекст агента, чужие адреса там ни к чему."""
        if self._nicknames is None:
            members = self._get("/api/spaces/%s/members" % self.space_id) if self.space_id else None
            self.members_unavailable = not isinstance(members, list)
            users = [(m or {}).get("user") or {} for m in members] if isinstance(members, list) else []
            self._nicknames = {u.get("uuid"): u.get("nickname") for u in users}
        return self._nicknames.get(uuid) or (uuid[:8] if uuid else "?")

    def page(self, uuid):
        """Ссылка на упомянутую страницу: [Название](url), без названия — url.

        /api/docs кладёт в ответ лишь родителей страницы (проверено живьём),
        остальные названия спрашиваем у /api/blocks. uuid пришёл из чужого
        текста: не-UUID в запрос не идёт, иначе им можно было бы дёрнуть
        другой адрес API."""
        if not UUID_RE.match(uuid):
            return "(упоминание страницы)"
        if uuid not in self._pages:
            rec = self.blocks.get(uuid) or {}
            if not rec.get("title"):
                rec = self._get("/api/blocks/" + uuid) or {}
            url = "https://buildin.ai/" + "/".join(x for x in (rec.get("spaceId") or self.space_id, uuid) if x)
            self._pages[uuid] = "[%s](%s)" % (rec["title"], url) if rec.get("title") else url
        return self._pages[uuid]

    @staticmethod
    def date(seg):
        """Дата как в календаре, а не как её рисует UI: формат relative
        («сегодня», «вчера») зависит от дня чтения, агенту нужна сама дата."""
        def moment(day, time):
            return " ".join(x for x in ((day or "").replace("/", "-"), time or "") if x)
        start = moment(seg.get("startDate"), seg.get("startTime"))
        end = moment(seg.get("endDate"), seg.get("endTime"))
        if not start:
            return "(дата)"
        return start + (" → " + end if end else "")

    def text(self, segments, markup=False):
        """Текст сегментов. markup — markdown для read: код, жирный, курсив, ссылки."""
        segments = segments or []
        parts = []
        for i, s in enumerate(segments):
            kind = s.get("type")
            if kind == 7:
                # Пробел после упоминания — только перед словом: перед пробелом
                # он задвоился бы, перед запятой и в конце строки повис бы.
                nxt = segments[i + 1].get("text", "") if i + 1 < len(segments) else ""
                parts.append("@" + self.name(s.get("uuid", "")) + (" " if nxt[:1].isalnum() else ""))
                continue
            if kind == 4:
                parts.append(self.page(s.get("uuid", "")))
                continue
            if kind == 1:
                parts.append(self.date(s))
                continue
            text = s.get("text", "")
            if markup:
                enh = s.get("enhancer") or {}
                if enh.get("code"):
                    text = "`%s`" % text
                elif enh.get("bold"):
                    text = "**%s**" % text
                elif enh.get("italic"):
                    text = "*%s*" % text
                if s.get("url"):
                    text = "[%s](%s)" % (text, s["url"])
            parts.append(text)
        return "".join(parts)
