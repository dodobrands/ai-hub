#!/usr/bin/env bash
# CI-гейт: версия плагина в .claude-plugin/marketplace.json совпадает с его
# integrations/<plugin>/.claude-plugin/plugin.json.
#
# Зачем: версия — это ключ кеша установки (~/.claude/plugins/cache/<marketplace>/
# <plugin>/<version>/). Каталог маркетплейса говорит, что зарелизено, а plugin.json
# лежит внутри плагина, и правят их разными коммитами. Расхождение молча делает
# ответ на вопрос «какая версия зарелизена» неверным: установка не падает, просто
# каталог рекламирует не то. К сентябрю 2026 так разъехались семь плагинов, самое
# старое расхождение — с апреля.
#
# Плагин, которого нет в каталоге, — предупреждение, а не провал: непубликация
# бывает намеренной.
#
# Любой провал → exit≠0 → CI красный.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 - <<'PY'
import glob
import json
import os
import sys

with open(".claude-plugin/marketplace.json", encoding="utf-8") as f:
    catalog = {p["name"]: p.get("version") for p in json.load(f)["plugins"]}

mismatched, unpublished = [], []
for path in sorted(glob.glob("integrations/*/.claude-plugin/plugin.json")):
    with open(path, encoding="utf-8") as f:
        plugin = json.load(f)
    name, version = plugin["name"], plugin.get("version")
    if name not in catalog:
        unpublished.append((name, version, path))
    elif catalog[name] != version:
        mismatched.append((name, catalog[name], version, path))

for name, version, path in unpublished:
    print(f"warning: {name} {version} нет в каталоге ({path}) — "
          f"добавьте в marketplace.json или оставьте, если не публикуется")

if mismatched:
    print()
    print("Версии разошлись между каталогом и плагином:")
    for name, cat_v, plug_v, path in mismatched:
        print(f"  {name}: marketplace.json {cat_v} / plugin.json {plug_v}  ({path})")
    print()
    print("Приведите обе записи к одной версии. Если непонятно, какая верна, —")
    print("берите бо́льшую: на неё уже могли завязаться установки, а понижение")
    print("версии не доедет до тех, у кого стоит старшая.")
    sys.exit(1)

print(f"версии совпадают: проверено плагинов — {len(catalog)}, "
      f"не опубликовано — {len(unpublished)}")
PY
