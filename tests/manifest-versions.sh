#!/usr/bin/env bash
# CI-гейт: запись плагина в .claude-plugin/marketplace.json согласована с его
# .claude-plugin/plugin.json.
#
# Зачем: действующую версию Claude Code берёт из plugin.json — при установке
# она побеждает, а version записи каталога молча игнорируется
# (calculatePluginVersion precedence). Версия в каталоге — надпись: разъехавшись,
# она ничего не ломает, просто говорит неправду о том, что зарелизено. Оба файла
# правят руками и разными коммитами, поэтому разъезжаются они регулярно и
# незаметно.
#
# Пару «запись каталога ↔ plugin.json» гейт находит по source записи, а имена
# сверяет первыми: пока имя в plugin.json, имя записи и каталог плагина не
# сойдутся, пара не находится и версия не сверяется вовсе — расхождение выглядит
# безобидным предупреждением «нет в каталоге» при зелёном CI.
#
# Дубль имени Claude Code отвергает целиком (claude plugin validate: Duplicate
# plugin name), а словарь имён его бы схлопнул и спрятал, поэтому уникальность
# проверяется до всего остального.
#
# Плагин, которого нет в каталоге, — предупреждение, а не провал: непубликация
# бывает намеренной, и решают это владельцы плагина, а не этот гейт.
#
# Корневой .claude-plugin/plugin.json (сам ai-hub) записи в каталоге не имеет,
# сверять его не с чем. Появится запись — гейт подхватит её по source, как любую
# другую.
#
# Любой провал → exit≠0 → CI красный.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 - <<'PY'
import glob
import json
import os
import sys
from collections import Counter

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

entries = load(".claude-plugin/marketplace.json")["plugins"]

def block(header, lines, hint):
    print()
    print(header)
    for line in lines:
        print(f"  {line}")
    print()
    print(hint)

# Дубль имени разбирается до всего остального: дальше записи кладутся в словарь
# по имени, и дубль бы просто вытеснил настоящую запись, не оставив следа.
dupes = sorted(n for n, c in Counter(e["name"] for e in entries).items() if c > 1)
if dupes:
    block("В каталоге несколько записей с одним именем:", dupes,
          "Claude Code не примет такой marketplace.json. Оставьте одну запись,\n"
          "а лишнюю удалите, не выравнивая ей версию.")
    sys.exit(1)

# Каталог плагина берётся из source, а не достраивается из имени: так запись с
# нестандартной раскладкой (например сам хаб с source ".") проверяется наравне
# с остальными, а не падает как осиротевшая.
mismatched, orphaned, misnamed_entry = [], [], []
paired = set()
for entry in entries:
    name, source = entry["name"], entry.get("source") or ""
    path = os.path.join(os.path.normpath(source), ".claude-plugin", "plugin.json")
    if not os.path.isfile(path):
        orphaned.append((name, source, path))
        continue
    paired.add(path)
    plugin = load(path)
    if plugin.get("name") != name:
        misnamed_entry.append((name, source, plugin.get("name"), path))
    elif entry.get("version") != plugin.get("version"):
        mismatched.append((name, entry.get("version"), plugin.get("version"), path))

misnamed_dir, unpublished = [], []
for path in sorted(glob.glob("integrations/*/.claude-plugin/plugin.json")):
    plugin = load(path)
    name, directory = plugin.get("name"), path.split("/")[1]
    if name != directory:
        misnamed_dir.append((name, directory, path))
    if path not in paired:
        unpublished.append((name, plugin.get("version"), path))

# Аннотацией, а не обычной строкой: вывод гейта уходит в свёрнутую ::group::, и
# при зелёном job'е владелец плагина его не увидит.
for name, version, path in unpublished:
    print(f"::warning file={path}::{name} {version} нет в каталоге — "
          f"добавьте в marketplace.json или оставьте, если не публикуется")

if misnamed_dir:
    block("Имя в plugin.json не совпадает с каталогом плагина:",
          [f"{path}: name {name} / каталог {directory}"
           for name, directory, path in misnamed_dir],
          "Переименуйте name или каталог. По имени ищется пара в marketplace.json —\n"
          "пока они разойдутся, версия плагина не сверяется вовсе.")

if misnamed_entry:
    block("Запись каталога ведёт в плагин с другим именем:",
          [f"{name}: source {source} → plugin.json с именем {found} ({path})"
           for name, source, found, path in misnamed_entry],
          "Каталог рекламирует одно имя, а ставит другой плагин. Приведите name\n"
          "записи и name в plugin.json к одному значению.")

if orphaned:
    block("В каталоге есть запись, но plugin.json у неё нет:",
          [f"{name}: source {source} → {path} не найден"
           for name, source, path in orphaned],
          "Новая интеграция — создайте plugin.json с теми же name и version.\n"
          "Опечатка в name или source — поправьте их. Плагин удалён из\n"
          "репозитория — уберите запись из marketplace.json.")

if mismatched:
    block("Версии разошлись между каталогом и плагином:",
          [f"{name}: marketplace.json {cat_v} / plugin.json {plug_v}  ({path})"
           for name, cat_v, plug_v, path in mismatched],
          "Приведите обе записи к одной версии. Claude Code берёт версию из\n"
          "plugin.json. Выше каталог — значит правки плагина до пользователей не\n"
          "доехали, поднимите plugin.json. Выше plugin.json — отстал каталог.")

if misnamed_dir or misnamed_entry or orphaned or mismatched:
    sys.exit(1)

print(f"манифесты согласованы: записей в каталоге — {len(entries)}, "
      f"не опубликовано — {len(unpublished)}")
PY
