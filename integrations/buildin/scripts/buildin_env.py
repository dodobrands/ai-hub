#!/usr/bin/env python3
"""Поиск .env и чтение токена — общий код python-скриптов buildin.

Порядок повторяет hub-meta/scripts/load-env.sh: сначала ближайший .env вверх от
скрипта (в клоне это корень репозитория), затем профиль пользователя. Копия
этого поиска жила в каждом скрипте, и копии начали расходиться — в них завёлся
путь конкретной рабочей машины. Машинно-специфичных путей здесь нет намеренно:
плагин ставится в разные каталоги, и зашитый путь работает ровно у одного клона.
"""
import os

ENV_WALK_UP_LEVELS = 6


def env_candidates():
    """Пути к .env в порядке приоритета, от ближайшего к скрипту."""
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(ENV_WALK_UP_LEVELS):
        yield os.path.join(d, ".env")
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    yield os.path.join(xdg, "ai-hub", ".env")
    yield os.path.expanduser("~/.ai-hub/.env")
    yield os.path.expanduser("~/.claude/plugins/cache/ai-hub/.env")


def read_token(name="BUILDIN_UI_TOKEN"):
    seen = []
    for path in env_candidates():
        if path in seen or not os.path.exists(path):
            continue
        seen.append(path)
        for line in open(path, encoding="utf-8"):
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError(
        "%s не найден. Искал в: %s. Обновите токен через buildin-login.sh"
        % (name, ", ".join(seen) or "нигде — ни один .env не существует"))
