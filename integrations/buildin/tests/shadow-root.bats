#!/usr/bin/env bats
# CI-обёртка над shadow-root.sh: сам тест — plain bash, чтобы на маке его можно
# было гонять без bats прямо под /bin/bash 3.2 (целевой шелл скриптов хаба).

@test "shadow: корень дерева приходит снаружи, а не зашит в скрипт" {
    run /bin/bash "$BATS_TEST_DIRNAME/shadow-root.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}
