# Time — DEPRECATED

Коннектор к Time переехал из ai-hub в отдельный плагин **`dodo-time`** на MCP.
Здесь остались только заглушки команд, которые подсказывают, как переехать.

## Почему

Старый коннектор ходил в Mattermost API личным токеном, который пользователь добывал
сам (`/ai-hub:time-login`, cookie из браузера) и хранил в `.env`. Новый работает через
MCP-сервер Тайма с OAuth: браузерный вход через корпоративный Google, токен живёт на
стороне сервера и в `.env` не попадает. Права — ровно ваши: закрытый для вас канал
закрыт и для агента, и это обеспечивает сам Тайм.

## Что делать

```bash
claude plugin uninstall time@ai-hub
claude plugin install dodo-time@dodo-ai-marketplace
```

Нет маркетплейса `dodo-ai-marketplace` — спросите ссылку в канале
[ai-hub-public](https://dodobrands.time-messenger.ru/dodo-brands/channels/ai-hub-public).
Коннектор приходит вместе с плагином; вручную то же самое:

```bash
claude mcp add --transport http --client-id dodo-ai-agent \
  dodo-time https://marketplace.dodois.io/mcp/time
```

После установки почистите хвосты старого коннектора: `TIME_TOKEN`, `TIME_BOT_TOKEN`,
`TIME_BASE_URL` в `.env` рабочих репозиториев и упоминания `/ai-hub:time-chat`,
`/ai-hub:time-login`, `time@ai-hub` в своих `CLAUDE.md` / `AGENTS.md`.

## Что изменилось в поведении

`dodo-time` **только читает**: каналы, треды, поиск, реакции, непрочитанное.
Отправки сообщений больше нет — агент, который читает произвольные каналы и умеет
в них писать, исполняет инструкции из чужих сообщений и пишет вашим токеном.
Если вам нужна была именно отправка — напишите в ai-hub-public, соберём спрос.

## Когда заглушки уедут

Каталог удалим целиком после того, как команды перестанут пользоваться `time@ai-hub`.
