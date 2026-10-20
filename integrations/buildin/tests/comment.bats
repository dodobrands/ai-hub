#!/usr/bin/env bats
# CI-обёртка над харнессами bash-слоя: сами они — plain bash, чтобы на маке их
# можно было гонять без bats прямо под /bin/bash 3.2 (целевой шелл скриптов
# хаба). Два теста, а не один: при падении сразу видно, какая часть сломалась.
#
# Харнесс получает пустой TMPDIR и обязан оставить его пустым: дефолтные файлы
# отката команд ложатся туда, и без своего TMPDIR в харнессе прогоны копили их
# в настоящем временном каталоге тысячами.

run_harness() {
    export TMPDIR="$BATS_TEST_TMPDIR/outer"
    mkdir -p "$TMPDIR"
    run /bin/bash "$BATS_TEST_DIRNAME/$1"
    echo "$output"
    [ "$status" -eq 0 ]
    leftover=$(ls -A "$TMPDIR")
    [ -z "$leftover" ] || { echo "харнесс оставил в TMPDIR: $leftover"; false; }
}

@test "comment: argument parsing, input forms, dry-run, rollback and races under /bin/bash" {
    run_harness comment.sh
}

@test "thread commands: reply, resolve, rollback and mentions under /bin/bash" {
    run_harness comment-threads.sh
}
