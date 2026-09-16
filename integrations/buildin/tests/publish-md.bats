#!/usr/bin/env bats
# CI-обёртка над publish-md.py: сам тест — plain python, чтобы его можно было
# гонять напрямую, без bats.

@test "publish-md: replace never leaves the page empty, spaceId is never guessed" {
    run python3 "$BATS_TEST_DIRNAME/publish-md.py"
    echo "$output"
    [ "$status" -eq 0 ]
}
