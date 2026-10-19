# Databricks Genie MCP Integration

Документация по подключению Databricks Genie как MCP (Model Context Protocol) сервера.

## MCP Endpoint

```
<workspace-url>/api/2.0/mcp/genie/<space_id>
```

## Авторизация

OAuth через databricks CLI — PAT не нужен. Один раз залогиниться:

```bash
databricks auth login --host https://<workspace>.azuredatabricks.net --profile <profile>
```

Свежий access token CLI выдаёт командой `databricks auth token --profile <profile>` и сам обновляет его
по refresh token. Токен живёт около часа, поэтому статичный заголовок в конфиге не годится — его надо
получать при каждом подключении.

## Подключение к Claude Code

Через `headersHelper`: Claude Code запускает команду при каждом подключении к серверу (и повторно после
401/403) и берёт заголовки из её stdout. Например, в `.mcp.json` проекта:

```json
{
  "mcpServers": {
    "databricks-genie": {
      "type": "http",
      "url": "https://<workspace>.azuredatabricks.net/api/2.0/mcp/genie/<space_id>",
      "headersHelper": "databricks auth token --profile <profile> -o json | jq -c '{Authorization: (\"Bearer \" + .access_token)}'"
    }
  }
}
```

Или для всех проектов: `claude mcp add-json databricks-genie '<тот же объект сервера>' --scope user`.

## Доступные MCP Tools

### 1. query_space_{SPACE_ID}

Отправка запроса на естественном языке.

**Input:**
```json
{
  "query": "your natural language question here",
  "conversation_id": "optional - для продолжения диалога"
}
```

**Output:**
- `conversationId` — ID беседы
- `messageId` — ID сообщения
- `status` — `FILTERING_CONTEXT`, `EXECUTING_QUERY`, `COMPLETED`, `FAILED`

### 2. poll_response_{SPACE_ID}

Получение результата запроса.

**Input:**
```json
{
  "conversation_id": "01f0f79dae1210ec802e21f0d13bf311",
  "message_id": "01f0f79dae1f18f894bc09695867a73a"
}
```

## Формат ответа MCP

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "structuredContent": {
      "content": {
        "queryAttachments": [
          {
            "query": "SELECT COUNT(DISTINCT `OrderId`) AS Order_Count\nFROM `analytics`.`gold`.`orders`\nWHERE `SaleDate` = current_date - 1",
            "description": "Описание что Genie понял из вопроса",
            "statement_response": {
              "statement_id": "uuid",
              "status": {"state": "SUCCEEDED"},
              "manifest": {
                "format": "JSON_ARRAY",
                "schema": {
                  "columns": [
                    {"name": "Order_Count", "type_name": "LONG"}
                  ]
                },
                "total_row_count": 1
              },
              "result": {
                "data_array": [
                  {"values": [{"string_value": "2470"}]}
                ]
              }
            }
          }
        ],
        "textAttachments": [
          "Yesterday there were **2470 orders**."
        ]
      },
      "conversationId": "...",
      "messageId": "...",
      "status": "COMPLETED"
    }
  }
}
```

## Преимущества MCP перед REST API

| Возможность | REST API | MCP |
|-------------|----------|-----|
| SQL Query | ✅ | ✅ |
| Text Answer | ✅ | ✅ |
| **Raw Data Results** | ❌ | ✅ |
| **Schema Info** | ❌ | ✅ |
| Statement ID | ✅ | ✅ |
| Conversation Support | ✅ | ✅ |
| Стандартный протокол | ❌ | ✅ (JSON-RPC 2.0) |

## Пример использования через curl

Токен передаётся curl через stdin-конфиг (`-K -`), а не аргументом командной строки — так он не виден
в списке процессов и не оседает в истории shell:

```bash
MCP_ENDPOINT="https://<workspace>.azuredatabricks.net/api/2.0/mcp/genie/<space_id>"

mcp() {  # $1 — тело JSON-RPC
    databricks auth token --profile <profile> -o json \
        | jq -r '"header = \"Authorization: Bearer " + .access_token + "\""' \
        | curl -s -K - -X POST "$MCP_ENDPOINT" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json, text/event-stream" \
            -d "$1"
}
```

### 1. Initialize

```bash
mcp '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "test-client", "version": "1.0.0"}
  }
}'
```

### 2. Query

```bash
mcp '{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "query_space_{SPACE_ID}",
    "arguments": {"query": "your natural language question"}
  }
}'
```

### 3. Poll Result

```bash
mcp '{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "poll_response_{SPACE_ID}",
    "arguments": {
      "conversation_id": "CONVERSATION_ID",
      "message_id": "MESSAGE_ID"
    }
  }
}'
```

## Server Info

```json
{
  "protocolVersion": "2024-11-05",
  "serverInfo": {
    "name": "DatabricksMCPServer",
    "version": "0.1.0"
  },
  "instructions": "Query the genie space to analyze structured data using natural language"
}
```

## Ссылки

- [MCP Protocol Specification](https://modelcontextprotocol.io/)
- [Databricks Genie API](https://docs.databricks.com/aws/en/genie/conversation-api)
