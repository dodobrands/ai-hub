---
name: testops
description: "Query Allure TestOps: search test cases, view launches, defects, test plans. Wrapper over TestOps REST API."
argument-hint: "<command> [args] — e.g. 'projects', 'testcases 2298 name~=Login', 'launch 12345'"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"]
---

# TestOps CLI — работа с Allure TestOps

Выполни запрос к Allure TestOps API через скрипты интеграции.

## Переменные окружения

Скрипты читают из `.env` в корне репозитория:
- `TESTOPS_URL` — базовый URL инстанса (напр. `https://your-company.qatools.cloud`)
- `TESTOPS_TOKEN` — персональный API-токен (Profile → API Tokens)

## Скрипты

### Низкоуровневый (произвольный API-вызов)
```bash
./integrations/testops/scripts/testops.sh <METHOD> <endpoint> [json_body]
# Пример: ./integrations/testops/scripts/testops.sh GET /project?page=0&size=10
```

### Высокоуровневый (подкоманды)
```bash
./integrations/testops/scripts/testops-api.sh <command> [args...]
```

## Доступные подкоманды

| Команда | Описание | Пример |
|---------|----------|--------|
| `projects [query]` | Поиск проектов | `testops-api.sh projects "MyService"` |
| `testcases <projectId> [rql]` | Поиск тест-кейсов (AQL) | `testops-api.sh testcases 2298 'name~="Login"'` |
| `testcase <id>` | Обзор тест-кейса | `testops-api.sh testcase 12345` |
| `testcase-scenario <id>` | Шаги тест-кейса | `testops-api.sh testcase-scenario 12345` |
| `testcase-history <id>` | История запусков тест-кейса | `testops-api.sh testcase-history 12345` |
| `launches <projectId> [rql]` | Поиск запусков (AQL) | `testops-api.sh launches 2298 'name~="Regression"'` |
| `launch <id>` | Детали запуска | `testops-api.sh launch 132069` |
| `launch-stats <id>` | Статистика запуска | `testops-api.sh launch-stats 132069` |
| `defects <projectId> [name]` | Поиск дефектов | `testops-api.sh defects 2298` |
| `defect <id>` | Детали дефекта | `testops-api.sh defect 456` |
| `jobs [projectId]` | Поиск джобов | `testops-api.sh jobs 2298` |
| `job <id>` | Детали джоба | `testops-api.sh job 789` |
| `testplans <projectId> [name]` | Поиск тест-планов | `testops-api.sh testplans 2298` |
| `testplan <id>` | Детали тест-плана | `testops-api.sh testplan 101` |
| `run-testplan <id> <name>` | Запуск тест-плана | `testops-api.sh run-testplan 101 "Release 1.0"` |

## AQL (Allure Query Language)

Для `testcases` и `launches` можно передавать AQL-запросы:

```
name = "Login Test"                       # точное совпадение
name ~= "Login"                           # содержит
automation = true                         # автоматизированные
tag in ["smoke", "regression"]            # по тегам
createdDate > 1672531200000               # дата (unix ms)
name ~= "Login" and automation = true     # AND
```

Документация AQL: https://docs.qameta.io/allure-testops/advanced/aql/

## Workflow

1. Определи, что именно нужно пользователю
2. Выбери подходящую подкоманду
3. Выполни через bash:
   ```bash
   ./integrations/testops/scripts/testops-api.sh <command> [args]
   ```
4. Покажи результат в читаемом виде
5. Если нужен raw API-вызов — используй `testops.sh` напрямую
