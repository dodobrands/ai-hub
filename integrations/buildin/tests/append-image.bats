#!/usr/bin/env bats
# CI-обёртка над append-image.sh: сам тест — plain bash, чтобы на маке его можно
# было гонять без bats прямо под /bin/bash 3.2 (целевой шелл скриптов хаба).

@test "append-image: API request bodies arrive as valid JSON under /bin/bash" {
    run /bin/bash "$BATS_TEST_DIRNAME/append-image.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}
