#!/usr/bin/env bats
# CI-обёртка над comment.sh: сам тест — plain bash, чтобы на маке его можно было
# гонять без bats прямо под /bin/bash 3.2 (целевой шелл скриптов хаба).

@test "comment: argument parsing, input forms, dry-run and rollback under /bin/bash" {
    run /bin/bash "$BATS_TEST_DIRNAME/comment.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}
