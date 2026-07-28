---
name: publish-page
description: Create or update a page in Buildin.ai wiki (UI API)
argument-hint: "<parent_page_id_or_url> [page_title]"
allowed-tools: ["Bash", "Read", "Glob", "Grep", "Write", "Edit", "Task", "AskUserQuestion"]
---

# Publish Page — создание и обновление страницы в Buildin (UI API)

Создаёт или обновляет страницу в Buildin.ai. Поддерживает создание из markdown-файлов, текста или структурированного контента.

## Константы

Каталог скриптов резолвится так, чтобы команда работала из **любого** репозитория
(standalone-клон, subtree-overlay, marketplace-install). Выполни строку-резолвер
перед вызовом скриптов; если bash-блоки запускаются отдельными shell'ами и
переменная между ними не сохраняется — повтори её в начале нужного блока.

```bash
# resolve-buildin-dir:start — первый существующий из кандидатов: плагин-кеш → overlay → standalone
BUILDIN_SCRIPTS=$(ls -d "${CLAUDE_PLUGIN_ROOT:-/nope}/scripts" "$PWD"/integrations/*/integrations/buildin/scripts "$PWD"/integrations/buildin/scripts 2>/dev/null | head -1)
# resolve-buildin-dir:end
```

## Входные параметры

Аргумент: `$ARGUMENTS` — parent_page_id и опционально заголовок.

Формат: `<parent_page_id> [page_title]`

## Workflow

### Фаза 0: Проверь авторизацию

```bash
bash "$BUILDIN_SCRIPTS/buildin-login.sh" check
```

Если `error:*` — запусти `/ai-hub:buildin-login` для логина.

> ℹ️ Создавать новую страницу или дополнять существующую? Если пользователь просит
> «добавить / дописать / обновить» уже существующую страницу — переходи к разделу
> [«Обновление существующей страницы»](#обновление-существующей-страницы) вместо Фаз 1–4.

### Фаза 1: Подготовка

1. Разбери аргументы:
   - Первый аргумент — `parent_page_id` (UUID родительской страницы)
   - Второй аргумент (опционально) — заголовок страницы
2. Если заголовок не указан, спроси пользователя через AskUserQuestion

### Фаза 2: Сбор контента

1. Спроси пользователя, что опубликовать:
   - **Файл** — путь к markdown/текстовому файлу в репозитории
   - **Текст** — пользователь введёт текст напрямую
   - **Пустая страница** — создать страницу только с заголовком
2. Если указан файл, прочитай его содержимое через Read

### Фаза 3: Создание страницы

```bash
bash "$BUILDIN_SCRIPTS/buildin-pages.sh" create "<parent_page_id>" "<title>"
```

Запомни ID созданной страницы из вывода.

### Фаза 4: Наполнение контентом

Если есть контент для публикации:

#### Вариант A (рекомендуется): markdown-файл через конвертер

Если контент — это markdown-файл, используй готовый конвертер. Он сам собирает
расширенные блоки (таблицы, сворачиваемые секции, вложенные списки, mermaid):

```bash
python3 "$BUILDIN_SCRIPTS/md-to-blocks.py" "<path/to/doc.md>" > /tmp/blocks.json
bash "$BUILDIN_SCRIPTS/buildin-pages.sh" append-blocks "<page_id>" "$(cat /tmp/blocks.json)"
```

Маппинг заголовков совпадает с тем, что выдаёт `read-page` (round-trip): `#`→level 1,
`##`→level 2, `###`→level 3. То есть прочитанную через `read-page` страницу можно
без сдвига уровней отредактировать и опубликовать обратно.

Поддержка markdown:
- `#`…`###` → заголовок (7); `<!-- collapse -->` перед заголовком → сворачиваемая секция (38)
- `-`/`*` (вложенность по отступу) → список (4); `1.` → нумерованный (5); `- [ ]` → чек-лист (3)
- `> текст` (ведущий эмодзи → иконка) → callout (13)
- `---` → divider (9); ` ```lang ` → код (25); ` ```mermaid ` → диаграмма с preview
- `| таблица |` → нативная таблица (27 + строки 28)
- inline: `**bold**`, `*italic*`, `` `code` ``, `[t](url)`

#### Вариант B: ручная сборка блоков (JSON)

Block types (числовые):
- `1` — paragraph · `3` — todo · `4` — bulleted · `5` — numbered · `7` — heading (`level` 1–3)
- `9` — divider · `12` — quote · `13` — callout (`icon`) · `23` — equation
- `25` — code (`format.language`; mermaid + `format.codePreviewFormat:"preview"`)
- `38` — сворачиваемый заголовок-секция (`level` 1–4) · `27` — таблица + строки `28`
- `10` — колоночный контейнер · `11` — колонка (`data.columnRatio`: число, доля ширины)

Вложенные блоки задаются полем `children` — `append-blocks` создаёт их с правильным
`parentId`/`subNodes` (toggle с детьми, строки таблицы, подпункты списков, колонки):

```json
{"type": 38, "data": {"level": 1, "segments": [{"type": 0, "text": "Секция", "enhancer": {}}]},
 "children": [{"type": 1, "data": {"segments": [{"type": 0, "text": "внутри", "enhancer": {}}]}}]}
```

#### Цвет блока (`textColor` / `backgroundColor`)

Любой блок принимает поблочный цвет (палитра как в Notion): `grey`, `red`, `green`,
`yellow`, `blue`, `purple`, `orange`, `pink`, `brown`, `teal`. Чаще всего нужен
`backgroundColor` на callout-е (`13`). Пустая строка / отсутствие поля → без заливки.

```json
{"type": 13, "backgroundColor": "red",
 "data": {"icon": {"type": "emoji", "value": "🚫"},
          "segments": [{"type": 0, "text": "Чего делать нельзя", "enhancer": {}}]}}
```

#### Колонки (`10` + `11`)

Колонки бок о бок: контейнер `10` с детьми-колонками `11`, в каждой — свои блоки.
`columnRatio` задаёт пропорцию ширины (равные колонки → одинаковое число у всех):

```json
{"type": 10, "children": [
  {"type": 11, "data": {"columnRatio": 1}, "children": [
    {"type": 13, "backgroundColor": "green", "data": {"segments": [{"type": 0, "text": "Делаем", "enhancer": {}}]}}]},
  {"type": 11, "data": {"columnRatio": 1}, "children": [
    {"type": 13, "backgroundColor": "red", "data": {"segments": [{"type": 0, "text": "Не делаем", "enhancer": {}}]}}]}
]}
```

Segment-формат: `{"type": 0, "text": "Hello", "enhancer": {"bold": true}}`;
inline-код `enhancer:{"code": true}`; ссылка `{"type": 3, "text": "click", "url": "https://…", "enhancer": {}}`.

#### Типы блоков, которые встречаются, но НЕ собираются вручную

Эти блоки существуют в Buildin, но создаются отдельными UI-флоу и ссылаются на
другие объекты — через `append-blocks` их задавать не нужно (их `data` тяжёлая и
контекстно-зависимая, ручная сборка даст битый блок):

- `18` / `19` — инлайн-база данных (table/board view): `data.schema` + `collectionPageProperties`
- `16` / `29` / `32` — ссылка/упоминание страницы (`data.ref.uuid` указывает на существующий объект)
- `15` — страница-папка с описанием (вариант страницы, а не блок контента)
- `36` — mind-map / канвас (`data.format.mindMappingFormat`, геометрия)
- `20` — embed (например, видео; вариант закладки)
- `2` / `31` — пустые структурные узлы (`data: {}`)
- `14` — image: требует загруженный файл (`data.ossName`) — грузится командой `buildin-pages.sh append-image <page> <file>` (getS3FileUploadInfo → PUT в S3 → image-блок)

> Перечень собран сканированием реальных страниц пространства; задавать через publish
> следует только контентные блоки из списка выше.

Отправка блоков:

```bash
# В конец страницы
bash "$BUILDIN_SCRIPTS/buildin-pages.sh" append-blocks "<page_id>" '<json_array>'

# После / перед конкретным блоком (block_id — поле "uuid" из get-blocks)
bash "$BUILDIN_SCRIPTS/buildin-pages.sh" insert-blocks-after  "<page_id>" "<block_id>" '<json_array>'
bash "$BUILDIN_SCRIPTS/buildin-pages.sh" insert-blocks-before "<page_id>" "<block_id>" '<json_array>'
```

### Фаза 5: Результат

1. Выведи ссылку на созданную страницу
2. Покажи краткую сводку: заголовок, количество блоков, parent page

## Обновление существующей страницы

Когда нужно дописать контент в уже существующую страницу (а не создавать новую) —
не используй `create`. Работай с блоками напрямую:

1. **Найди точку вставки.** Получи верхнеуровневые блоки и их `uuid`:

   ```bash
   bash "$BUILDIN_SCRIPTS/buildin-pages.sh" get-blocks "<page_id>"
   ```

   В выводе у каждого блока есть поле `uuid` — это и есть `block_id` для вставки.
   Заголовки имеют `type: 7` и поле `data.level` (1–3) — по ним удобно находить нужную секцию.

2. **Подготовь блоки.** Собери markdown во временный файл и сконвертируй:

   ```bash
   python3 "$BUILDIN_SCRIPTS/md-to-blocks.py" /tmp/new-section.md > /tmp/blocks.json
   ```

3. **Вставь в нужное место** (а не только в конец):

   ```bash
   # В конец страницы
   bash "$BUILDIN_SCRIPTS/buildin-pages.sh" append-blocks "<page_id>" "$(cat /tmp/blocks.json)"

   # Перед разделом (например, добавить новую секцию перед «Выводами»):
   bash "$BUILDIN_SCRIPTS/buildin-pages.sh" insert-blocks-before "<page_id>" "<heading_block_uuid>" "$(cat /tmp/blocks.json)"

   # После конкретного блока:
   bash "$BUILDIN_SCRIPTS/buildin-pages.sh" insert-blocks-after  "<page_id>" "<block_uuid>" "$(cat /tmp/blocks.json)"
   ```

   `insert-blocks-before`/`insert-blocks-after` работают с верхнеуровневыми блоками страницы.
   Если целевой блок — самый первый, `insert-blocks-before` корректно вставит контент в начало.

   **Удаление блока** (например, чтобы заменить блок — удали старый, вставь новый):

   ```bash
   # Первым аргументом block_id (из get-blocks), НЕ page_id — в отличие от insert/append.
   bash "$BUILDIN_SCRIPTS/buildin-pages.sh" delete-block "<block_uuid>"
   ```

4. **Проверь результат** — перечитай страницу и убедись, что блоки встали в нужном порядке:

   ```bash
   bash "$BUILDIN_SCRIPTS/buildin-pages.sh" read "<page_id>"
   ```

## Обработка ошибок

- HTTP 401 → Токен истёк, запусти `/ai-hub:buildin-login`
- API code 500 → Проверь формат транзакции
- Нет BUILDIN_UI_TOKEN → Запусти `/ai-hub:buildin-login`
