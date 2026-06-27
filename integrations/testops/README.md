# TestOps Integration

Интеграция с Allure TestOps через REST API — bash-скрипты и slash-команда.

## Установка

1. Добавь в `.env`:
   ```
   TESTOPS_URL=https://your-company.qatools.cloud
   TESTOPS_TOKEN=your_api_token_here
   ```

2. Симлинк уже создан — команда `/ai-hub:testops` доступна.

## Использование

### Slash-команда
```
/ai-hub:testops projects
/ai-hub:testops testcases 2298 'name~="Login"'
/ai-hub:testops launches 2298
```

### CLI напрямую
```bash
# Высокоуровневый (подкоманды)
./integrations/testops/scripts/testops-api.sh projects
./integrations/testops/scripts/testops-api.sh testcases 2298 'automation=true'
./integrations/testops/scripts/testops-api.sh launch 132069

# Низкоуровневый (произвольный API-вызов)
./integrations/testops/scripts/testops.sh GET '/project?page=0&size=10'
./integrations/testops/scripts/testops.sh POST '/rs/testcase?v2=true' '{"projectId":2298,"name":"New test"}'
```

## Покрытые API

| Домен | Операции |
|-------|----------|
| Projects | search, create, update |
| Test Cases | search (AQL), get overview, scenario, history, create, update |
| Launches | search (AQL), get, statistics |
| Defects | search, get |
| Jobs | search, get |
| Test Plans | search, get, run |

## Структура

```
integrations/testops/
├── .claude-plugin/plugin.json    # Метаданные плагина
├── commands/testops.md           # Slash-команда /ai-hub:testops
├── scripts/
│   ├── testops.sh                # Низкоуровневый API (method + endpoint)
│   └── testops-api.sh            # Высокоуровневые подкоманды
└── README.md
```

## Зависимости

- `curl`, `jq`, `python3` (для url-encoding)
- Переменные `TESTOPS_URL` и `TESTOPS_TOKEN` в `.env`
