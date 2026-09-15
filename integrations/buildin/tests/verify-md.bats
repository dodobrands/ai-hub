#!/usr/bin/env bats
# CI-обёртка над verify-md.py: сам тест — plain python, чтобы его можно было
# гонять напрямую, без bats.

@test "verify-md: collapse sections are walked, heading levels match both sides" {
    run python3 "$BATS_TEST_DIRNAME/verify-md.py"
    echo "$output"
    [ "$status" -eq 0 ]
}
