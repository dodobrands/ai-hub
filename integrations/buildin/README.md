# Buildin Integration

Интеграция с [Buildin.ai](https://buildin.ai) — вики-платформа для документации.

## Структура

```
integrations/buildin/
├── .claude-plugin/
│   └── plugin.json           # Манифест плагина
├── scripts/
│   ├── buildin.sh            # Level 1: HTTP-клиент (curl + Bearer JWT, UI API)
│   ├── buildin-pages.sh      # Level 2: CRUD + read (markdown) + комментарии + delete-block
│   ├── buildin-blocks.py     # Построитель транзакций для дерева блоков (вложенность)
│   ├── buildin-comment.py    # Построитель операций комментария: поиск якоря, перенарезка сегментов
│   ├── md-to-blocks.py       # Конвертер Markdown → блоки (таблицы, toggle, mermaid)
│   ├── buildin-publish-md.py # Движок publish-md: батчи, ретраи, режим --replace
│   ├── buildin-verify-md.py  # Сверка опубликованной страницы с исходным markdown
│   ├── buildin-nav.sh        # Level 2: Навигация и поиск по дереву
│   ├── buildin-shadow.sh     # Level 2: Shadow-индекс (локальный кеш)
│   └── buildin-login.sh      # Проверка и сохранение JWT-токена
├── tests/                     # bats-юниты: md-to-blocks, publish-md, verify-md, append-image, comment
├── shadow-index.json          # Локальный кеш структуры и саммари страниц
├── commands/
│   ├── read-page.md          # Скилл: чтение страницы (URL/UUID/поиск)
│   ├── publish-page.md       # Скилл: создание/обновление страницы
│   └── buildin-login.md      # Скилл: логин через browser MCP (Google SSO)
└── README.md
```

## Быстрый старт

### 1. Логин

Используй скилл `/ai-hub:buildin-login` — он откроет Buildin через Chrome DevTools MCP, выполнит Google SSO и сохранит JWT-токен в `.env` как `BUILDIN_UI_TOKEN`.

Или вручную:
```bash
# Проверить текущий токен
./integrations/buildin/scripts/buildin-login.sh check

# Сохранить токен из буфера обмена
./integrations/buildin/scripts/buildin-login.sh clipboard
```

JWT-токен живёт ~30 дней.

### 2. Проверь подключение

```bash
./integrations/buildin/scripts/buildin.sh GET /api/users/me
```

## Использование

Все команды принимают UUID или URL buildin.ai:

```bash
# Обе формы эквивалентны:
./integrations/buildin/scripts/buildin-pages.sh read 2a904afe-42e9-4ebd-a94e-f6fe0cbacf58
./integrations/buildin/scripts/buildin-pages.sh read https://buildin.ai/2a904afe-42e9-4ebd-a94e-f6fe0cbacf58
```

### Чтение и навигация

```bash
# Прочитать страницу как markdown (рекурсивно раскрывает columns, toggles)
./integrations/buildin/scripts/buildin-pages.sh read <id|url>

# Заголовок
./integrations/buildin/scripts/buildin-pages.sh title <id|url>

# Родительская страница
./integrations/buildin/scripts/buildin-nav.sh parent <id|url>

# Дочерние страницы (включая вложенные в columns/toggles)
./integrations/buildin/scripts/buildin-nav.sh children <id|url>

# Дерево страниц (2 уровня вглубь)
./integrations/buildin/scripts/buildin-nav.sh tree <id|url> 2

# Поиск по названию (до 4 уровней вглубь)
./integrations/buildin/scripts/buildin-nav.sh search <id|url> "query" 4
```

### Создание и редактирование

```bash
# Создать дочернюю страницу
./integrations/buildin/scripts/buildin-pages.sh create <parent_id|url> "Заголовок"

# Обновить заголовок
./integrations/buildin/scripts/buildin-pages.sh update <id|url> "Новый заголовок"

# Добавить текст
./integrations/buildin/scripts/buildin-pages.sh append-text <id|url> "Новый параграф"

# Опубликовать markdown-файл (по умолчанию дописывает в конец)
./integrations/buildin/scripts/buildin-pages.sh publish-md <id|url> doc.md
./integrations/buildin/scripts/buildin-pages.sh publish-md <id|url> doc.md --replace

# Добавить блоки (JSON)
./integrations/buildin/scripts/buildin-pages.sh append-blocks <id|url> '<json_blocks>'

# Вставить блоки после / перед конкретным блоком (block_id — поле uuid из get-blocks)
./integrations/buildin/scripts/buildin-pages.sh insert-blocks-after  <id|url> <block_uuid> '<json_blocks>'
./integrations/buildin/scripts/buildin-pages.sh insert-blocks-before <id|url> <block_uuid> '<json_blocks>'

# Удалить конкретный блок (не страницу!)
./integrations/buildin/scripts/buildin-pages.sh delete-block <block_uuid> [parent_id]

# Архивировать
./integrations/buildin/scripts/buildin-pages.sh archive <id|url>
```

### Комментарии

Комментарий в Buildin — это тред (`discussion`), привязанный к блоку, плюс сообщения
(`comment`) внутри треда. Тред всегда выделяет фразу внутри блока, поэтому у команды
создания есть обязательный аргумент-якорь.

```bash
DIR=integrations/buildin/scripts

# Прочитать все комментарии страницы
bash $DIR/buildin-pages.sh comments <id|url>

# Только комментарии одного блока — вторым аргументом или якорем в URL
bash $DIR/buildin-pages.sh comments <id|url> <block_uuid>
bash $DIR/buildin-pages.sh comments '<url>#<block_uuid>'

# Создать комментарий к фразе внутри блока
bash $DIR/buildin-pages.sh comment <id|url> <block_uuid> 'фраза-якорь' 'текст комментария'
```

`comment` принимает идентификаторы в тех же формах, что и `comments`: блок задаётся
вторым аргументом либо якорем `#<block_uuid>` в URL. `block_uuid` — поле `uuid` из
вывода `get-blocks`.

#### Ввод текста

Якорь и текст можно взять из файла (`@путь`) или из stdin (`-`) — длинный текст в
bash-строке неудобно экранировать:

```bash
bash $DIR/buildin-pages.sh comment <id|url> <block_uuid> 'фраза-якорь' @comment.md
cat comment.md | bash $DIR/buildin-pages.sh comment <id|url> <block_uuid> 'фраза-якорь' -
```

Сигилы экранируются удвоением: `@@j.doe глянь` даёт литеральный текст `@j.doe глянь`,
`--` — литеральный `-`. Пустой файл и пустой stdin отвергаются: тред без сообщения в
живой документ не уходит.

#### Якорь обязан быть однозначным

**Якорь целиком лежит внутри одного сегмента.** Сегмент — отрезок текста с единым
форматированием, поэтому фраза, задевающая границу жирного, кода или ссылки, выделена
быть не может. Команда отвергает такой якорь с разбором сегментов, а не привязывает
тред молча не туда:

```
Error: Якорь есть в тексте блока, но разорван границей сегментов. Якорь должен
целиком лежать внутри одного сегмента.
Текст блока: «лимит 100 запросов/мин»
Сегменты:
  [0] «лимит »
  [1] «100 запросов» [code]
  [2] «/мин»
Возьмите фразу короче — целиком внутри одного форматирования.
```

**Несколько вхождений — тоже отказ.** Якорь `лимит` по тексту
`безлимитный тариф: лимит 100` подошёл бы к двум местам, и первое из них — внутри
слова `безлимитный`. Команда перечисляет вхождения с контекстом и ждёт решения:
удлинить якорь до однозначного или выбрать явно через `--occurrence=N` (нумерация —
по видимому тексту блока, слева направо).

#### Что команда гарантирует, а что нет

`--dry-run` печатает операции транзакции и не трогает ни сеть, ни диск.

**Запись узкая.** `update` по `path: ['data']` меняет только `segments`, тред добавляется
в блок списочной операцией `listAfter` по `path: ['discussions']`. Полная перезапись
блока стирала бы чужие ключи `data` и выбивала из списка чужие треды — проверено на
живой странице: `listAfter` аддитивен, запись полного списка нет.

**Конкурентную правку команда не предотвращает, а обнаруживает.** `segments` всё равно
уходят целиком из снапшота, снятого в начале команды. Перед отправкой блок
перечитывается, и если сегменты успели измениться — запись отменяется с просьбой
повторить команду. Этого мало: несколько процессов успевают сделать оба чтения раньше
первой записи (на живой странице из трёх параллельных комментариев двое теряли
подсветку). Поэтому после записи результат сверяется по факту:

- своя подсветка не закрепилась — команда завершается ненулевым кодом и просит
  применить откат и повторить;
- подсветку потерял чужой тред, который был на месте при чтении, — громкое
  предупреждение с перечислением тредов (они остаются в списке блока, но на странице
  их не видно).

Давно осиротевшие треды — те, что были без подсветки ещё до запуска, — в
предупреждение не попадают: база сравнения берётся из снапшота команды.

**Откат.** Перед отправкой команда сохраняет payload отката — готовое тело запроса,
которое возвращает `segments` блока, убирает тред из списка блока и гасит созданные
`discussion`/`comment` (`status: -1`), чтобы после отката их не показывала и `comments`.
Файл кладётся через `mktemp` в `$TMPDIR` (имя непредсказуемо, права `0600`;
переопределяется опцией `--rollback-out=<path>`), его путь печатается в stderr.

```bash
bash $DIR/buildin.sh POST /api/records/transactions "$(cat <путь из stderr>)"
```

Откат возвращает блок в то состояние, в котором команда его **прочитала**, поэтому
применять его надо сразу: комментарии, легшие после чтения, он тоже откатит. Для
одиночной правки — а это обычный сценарий — разницы нет.

**Проверки перенарезки.** Сверка склейки текста сегментов стоит в билдере как
регрессионный сторож: при нынешней реализации разреза она сработать не может (склейка
равна исходному тексту по построению), но ловит будущую правку `split_segments` — это
проверено тестом с намеренно сломанным разрезом. Рядом стоят проверки, которые
разойтись способны: непустые части, допустимое изменение числа сегментов, сохранность
всех полей сегмента (`url`, `type`, `enhancer`) и неприкосновенность соседей.

Под капотом одна транзакция из пяти операций: `discussion` (тред), `comment`
(сообщение), узкий `update` сегментов, `listAfter` по `discussions` и обновление
`updatedAt` блока. Без двух последних тред создаётся, но остаётся неприкреплённым — на
странице его не видно.

### Расширенные блоки из Markdown

`md-to-blocks.py` конвертирует Markdown-файл в дерево блоков Buildin, а
`append-blocks`/`insert-blocks-after`/`insert-blocks-before` создают его целиком —
включая **вложенные** блоки (таблицы, сворачиваемые секции, многоуровневые списки),
которые плоский append выразить не может. Маппинг заголовков совпадает с выводом
`read` (round-trip): `#`→level 1, `##`→level 2, `###`→level 3.

```bash
DIR=integrations/buildin/scripts

# Обычный путь: одной командой, блоки дописываются в конец страницы
bash $DIR/buildin-pages.sh publish-md <id|url> doc.md

# Перепубликация документа целиком: содержимое страницы заменяется,
# ссылки на дочерние страницы сохраняются
bash $DIR/buildin-pages.sh publish-md <id|url> doc.md --replace

# Тот же конвертер отдельно — когда блоки нужны как JSON для точечной вставки
python3 $DIR/md-to-blocks.py doc.md > /tmp/blocks.json
bash $DIR/buildin-pages.sh insert-blocks-before <id|url> <block_uuid> "$(cat /tmp/blocks.json)"
```

```bash
# Сверить опубликованную страницу с исходником (рассчитано на --replace)
python3 $DIR/buildin-verify-md.py <id|url> doc.md
python3 $DIR/buildin-verify-md.py <id|url> doc.md --keep-h1   # если H1 публиковали
```

Сверка сравнивает страницу целиком с одним файлом, поэтому осмысленна после
`--replace`. После append лишнее на странице — норма, и такие расхождения
помечаются отдельной пометкой, а не выглядят поломкой.

`publish-md` добавляет к конвертеру то, чего нет в голом `append-blocks`: разбиение
на транзакции по 25 блоков, повтор сетевых обрывов и транзиентных ответов сервера
(429, 5xx), безопасный порядок замены — новые блоки заливаются первыми, старые
удаляются последними, поэтому сорванная публикация не оставляет страницу пустой, —
и сохранение блоков-ссылок на дочерние страницы при `--replace`. Операции собирает
всё тот же `buildin-blocks.py`.

Поддерживаемые блоки:

| Markdown | Блок Buildin | type |
|---|---|---|
| `#` … `###` | заголовок | 7 (level 1–3) |
| `<!-- collapse -->` перед заголовком | сворачиваемая секция (всё до след. заголовка того же/высшего уровня — внутрь) | 38 |
| `-` / `*` (вложенность по отступу) | маркированный список | 4 |
| `1.` `2.` | нумерованный список | 5 |
| `- [ ]` / `- [x]` | чек-лист | 3 |
| `> текст` (ведущий эмодзи → иконка) | выноска (callout) | 13 |
| `---` | разделитель | 9 |
| ` ```lang ` | блок кода | 25 |
| ` ```mermaid ` | mermaid с preview-рендером | 25 |
| `\| таблица \|` | нативная таблица | 27 + строки 28 |
| абзац | параграф | 1 |
| `**bold**` `*italic*` `` `code` `` `[t](url)` | inline-форматирование | — |

**Мягкие переносы.** Внутри пункта списка и внутри абзаца перенос строки не создаёт
новый блок: строка с отступом и без маркера считается продолжением пункта (как в
CommonMark) и клеится к его тексту через пробел — inline-разметка, разорванная
переносом, тоже собирается. А вот в выноске (`>`) **каждая строка остаётся отдельной
строкой** внутри одного callout — так задумано (шапки документов держат `> **Источник:**`
/ `> **Участники:**` разными строками), поэтому содержимое выноски верстать по ширине
не надо: перенос попадёт в опубликованную страницу как есть.

Опция `--shift-headings` сдвигает уровни заголовков на 1 (`##` → level 1), если
нужны более крупные секции. Изображения и цвета текста в Markdown-конвертере не
поддерживаются (отсутствуют в синтаксисе Markdown); картинку на страницу добавляет
отдельная команда `buildin-pages.sh append-image <page> <file> [caption]` — она
сама грузит файл в S3 Buildin (`getS3FileUploadInfo` → presigned PUT) и создаёт
image-блок (`type: 14`, `data.ossName`).

`read` понимает эти типы в обратную сторону — таблицы, `<!-- collapse -->` и
вложенность восстанавливаются при чтении страницы как Markdown.

### Shadow-индекс (локальный кеш)

Локальный кеш структуры и саммари страниц для мгновенного поиска без API-запросов. Растёт органически: каждое чтение страницы автоматически обновляет индекс.

```bash
# Мгновенный поиск по title + summary
./integrations/buildin/scripts/buildin-shadow.sh search "RFC"

# Дерево из кеша (без API)
./integrations/buildin/scripts/buildin-shadow.sh tree

# Полный дамп для LLM-анализа (субагент может прочитать и понять структуру)
./integrations/buildin/scripts/buildin-shadow.sh dump

# Статистика и устаревшие записи
./integrations/buildin/scripts/buildin-shadow.sh stats
./integrations/buildin/scripts/buildin-shadow.sh stale 30
```

Поиск через `buildin-nav.sh search` автоматически проверяет shadow-индекс перед обращением к API.

## Известные страницы

| Название | Page ID |
|----------|---------|
| _(add your root page here)_ | `YOUR_ROOT_PAGE_ID` |

## Особенности Buildin API

- **Поле `parent`** — `GET /v1/pages/{id}` возвращает `parent` объект: `{"type": "page_id", "page_id": "..."}` для дочерних страниц или `{"type": "space_id", "space_id": "..."}` для корневых. API пространств (`/v1/spaces`) недоступен.
- **Два формата блоков** — новый API хранит контент в `data`, legacy — в именованных полях (`heading_1`, `paragraph`). Скрипты поддерживают оба.
- **Нет `plain_text`** — заголовки берутся из `text.content` внутри `rich_text` items.
- **Поиск — `api/search` КРАЙНИЙ способ.** Официальный API (`/v1/search`) сломан (500). UI API `/api/search` работает, но качество низкое (нерелевантные результаты) и поиск scoped на конкретный space (не по всем — легко искать не в том пространстве). **Приоритет:** shadow-индекс → обход дерева от базовых страниц (`buildin-nav.sh children <page_id>`, попутно наполняет shadow-индекс) → и только потом `api/search` с явным space_id.
- **Доступ** — UI API (JWT из Google SSO) видит все страницы пользователя. Официальный API-токен видит только расшаренные боту страницы (иначе 403).
- **SDK** — [GitHub: next-space/buildin-api-sdk](https://github.com/next-space/buildin-api-sdk) (Java + TypeScript, OpenAPI spec)

## API Reference

Интеграция использует **UI API** (не официальный API). Base URL: `https://buildin.ai`, авторизация через JWT-токен из Google SSO.

| Метод | Endpoint | Описание |
|-------|----------|----------|
| GET | /api/users/me | Текущий пользователь |
| GET | /api/pages/{id} | Получить страницу с блоками |
| POST | /api/pages/{id}/transactions | Создание/редактирование (транзакции) |
| GET | /api/blocks/{id} | Получить блок по UUID |
| POST | /api/search | Поиск по пространству |

Официальный API (`api.buildin.ai`, `/v1/...`) также существует, но имеет ограничения: поиск сломан (500), нет доступа к пространствам, видит только расшаренные боту страницы.
