#!/usr/bin/env bats
# Склейка URL в kaiten.sh: эндпоинт без ведущего слэша не должен превращаться
# в ".../api/latestspaces" (Kaiten отвечает на такое 401, и причина выглядит как
# нехватка прав). Сети нет: curl подменяется стабом, который печатает полученный URL.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
    SANDBOX="$(mktemp -d)"

    # Раскладка, которую ждёт kaiten.sh: <root>/integrations/{kaiten,hub-meta}/scripts/
    mkdir -p "$SANDBOX/integrations/kaiten/scripts" "$SANDBOX/integrations/hub-meta/scripts"
    cp "$REPO_ROOT/integrations/kaiten/scripts/kaiten.sh" "$SANDBOX/integrations/kaiten/scripts/"
    cp "$REPO_ROOT/integrations/hub-meta/scripts/load-env.sh" "$SANDBOX/integrations/hub-meta/scripts/"

    # hub_load_env вычищает секреты из окружения и берёт их только из .env,
    # поэтому токен кладём в .env песочницы, а не в export.
    cat > "$SANDBOX/.env" <<'ENV'
KAITEN_TOKEN=test-token
KAITEN_DOMAIN=example.invalid
ENV

    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Печатает последний аргумент (URL) + перевод строки и HTTP-код: kaiten.sh забирает
# код из последней строки ответа, а остальное считает телом.
for last; do :; done
printf '%s\n200' "$last"
STUB
    chmod +x "$SANDBOX/bin/curl"
    PATH="$SANDBOX/bin:$PATH"
    export PATH
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "эндпоинт со слэшем: URL склеивается как есть" {
    run bash "$SANDBOX/integrations/kaiten/scripts/kaiten.sh" GET /spaces
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.invalid/api/latest/spaces"* ]]
}

@test "эндпоинт без слэша: слэш добавляется, а не съедается" {
    run bash "$SANDBOX/integrations/kaiten/scripts/kaiten.sh" GET spaces
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.invalid/api/latest/spaces"* ]]
    [[ "$output" != *"latestspaces"* ]]
}

@test "вложенный путь без слэша тоже нормализуется" {
    run bash "$SANDBOX/integrations/kaiten/scripts/kaiten.sh" GET cards/42
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.invalid/api/latest/cards/42"* ]]
}

@test "дефолтный эндпоинт остаётся /users/current" {
    run bash "$SANDBOX/integrations/kaiten/scripts/kaiten.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.invalid/api/latest/users/current"* ]]
}
