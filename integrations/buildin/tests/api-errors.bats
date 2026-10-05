#!/usr/bin/env bats
# CI-обёртка над api-errors.sh: сам тест — plain bash, чтобы на маке его можно
# было гонять без bats прямо под /bin/bash 3.2 (целевой шелл скриптов хаба).

@test "buildin API: не-успешный code в теле останавливает работу под /bin/bash" {
    run /bin/bash "$BATS_TEST_DIRNAME/api-errors.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}
