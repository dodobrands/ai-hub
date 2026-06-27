#!/usr/bin/env python3
"""Построитель операций UI API для дерева блоков Buildin (с вложенностью).

Читает JSON-массив блоков и печатает JSON-массив операций транзакции.
Каждый блок: {"type": int, "data": {...}, "children": [<block>, ...]?,
              "textColor": str?, "backgroundColor": str?}

textColor/backgroundColor — поблочные поля цвета (как в Notion: grey, red,
green, yellow, blue, purple, orange, pink, brown, teal). Их читает UI Buildin;
без проброса цветные callout-ы/колонки задать нельзя.

Вложенные блоки (строки таблицы, дети toggle, подпункты списков) создаются с
parentId, указывающим на контейнер, и привязываются в его subNodes. Это и даёт
таблицы, сворачиваемые секции и вложенные списки, которые плоский append выразить
не может.

Usage:
    buildin-blocks.py <page_id> <space_id> <now_ms> <user_id> <blocks_json> [after_block_id] [before_block_id]

Если передан after_block_id — первый блок верхнего уровня вставляется после него
(режим insert-blocks-after). Если передан before_block_id (а after_block_id пуст) —
первый блок вставляется ПЕРЕД ним (режим insert-blocks-before, нужен для вставки
в самое начало страницы). Иначе блоки добавляются в конец страницы.
"""
import json
import sys
import uuid

page_id = sys.argv[1]
space_id = sys.argv[2]
now = int(sys.argv[3])
user_id = sys.argv[4]
blocks_json = sys.argv[5]
after_block_id = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else None
before_block_id = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None

DEFAULT_FORMAT = {'commentAlignment': 'top'}

blocks = json.loads(blocks_json)
ops = []


def emit(block, parent_id, after=None, before=None):
    """Создать блок под parent_id и рекурсивно его детей. Вернуть uuid блока."""
    block_id = str(uuid.uuid4())
    block_data = block.get('data', {})
    # Глубоко мёржим format, чтобы commentAlignment не терялся, когда блок
    # задаёт свой format (таблицы, code и т.п.).
    data = {'pageFixedWidth': True, **block_data}
    data['format'] = {**DEFAULT_FORMAT, **block_data.get('format', {})}

    ops.append({
        'id': block_id,
        'command': 'set',
        'table': 'block',
        'path': [],
        'args': {
            'uuid': block_id,
            'spaceId': space_id,
            'parentId': parent_id,
            'type': block.get('type', 1),
            'textColor': block.get('textColor', ''),
            'backgroundColor': block.get('backgroundColor', ''),
            'status': 1,
            'permissions': [],
            'createdAt': now,
            'createdBy': user_id,
            'updatedBy': user_id,
            'updatedAt': now,
            'data': data,
        },
    })
    # listBefore используется только для вставки в самое начало (нет предыдущего
    # соседа); во всех остальных случаях порядок задаётся через listAfter.
    if before:
        list_cmd = 'listBefore'
        list_args = {'uuid': block_id, 'before': before}
    else:
        list_cmd = 'listAfter'
        list_args = {'uuid': block_id}
        if after:
            list_args['after'] = after
    ops.append({
        'id': parent_id,
        'command': list_cmd,
        'table': 'block',
        'path': ['subNodes'],
        'args': list_args,
    })

    prev_child = None
    for child in block.get('children', []):
        prev_child = emit(child, block_id, after=prev_child)

    return block_id


prev = after_block_id
for idx, block in enumerate(blocks):
    if idx == 0 and before_block_id and not after_block_id:
        # Первый блок — перед целевым; остальные цепляются после него по порядку.
        prev = emit(block, page_id, before=before_block_id)
    else:
        prev = emit(block, page_id, after=prev)

# Обновить таймстемп страницы
ops.append({
    'id': page_id,
    'command': 'update',
    'table': 'block',
    'path': [],
    'args': {'updatedBy': user_id, 'updatedAt': now},
})

print(json.dumps(ops, ensure_ascii=False))
