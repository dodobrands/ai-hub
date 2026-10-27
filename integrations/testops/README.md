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

## Таймауты

- Соединение — 15 с (`--connect-timeout`), весь запрос — 120 с (`--max-time`). Без VPN соединение
  устанавливается, а TLS-рукопожатие висит: без потолка скрипт ждал бы бесконечно.
- Переопределяются переменными `TESTOPS_CONNECT_TIMEOUT` и `TESTOPS_MAX_TIME` (секунды) — в окружении
  или в `.env`. Если переменная задана и там и там, побеждает `.env`. Значение не числом — отказ до
  запроса.
- Нет ответа — `testops.sh` завершается кодом 1, а в stderr пишет `Error: no response from TestOps …`.
  Строкой выше curl пишет причину, и по ней видно, что случилось:
  - `Could not resolve host`, `Failed to connect`, `Connection timed out` — TestOps недоступен: проверь
    сеть и VPN;
  - `Operation timed out` — TestOps отвечает медленно: подними `TESTOPS_MAX_TIME`. Запись (метод не GET
    и не HEAD) при этом могла пройти — скрипт добавляет `a write may have been applied`. Перед повтором
    проверь, не создана ли она.

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
├── tests/timeouts.bats           # Таймауты и ошибка «нет ответа», curl подменён стабом
└── README.md
```

## Зависимости

- `curl`, `jq`, `python3` (для url-encoding)
- Переменные `TESTOPS_URL` и `TESTOPS_TOKEN` в `.env`
