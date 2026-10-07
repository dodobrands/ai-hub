#!/usr/bin/env bats
# Файлы карточки в kaiten-cards.sh: attach, files, download. Сети нет: curl подменяется стабом,
# который пишет свои аргументы в журнал и отвечает по URL — карточкой с файлами обоих поколений,
# метаданными файла с подписанной ссылкой или содержимым файла.
#
# `|| false` после `[[ ]]`: в bash 3.2 (на маке bats идёт под ним) упавшее `[[ ]]` в середине
# теста тест не роняет.

CARD_UID="739b91f1-9e11-4933-bdb9-a8569dd36a79"
RESTRICTED_ID="f0cecaad-cb23-4a81-a6bd-43ea8a945515"
LEGACY_ID="555"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
    SANDBOX="$(mktemp -d)"

    mkdir -p "$SANDBOX/integrations/kaiten/scripts" "$SANDBOX/integrations/hub-meta/scripts"
    cp "$REPO_ROOT/integrations/kaiten/scripts/kaiten.sh" "$REPO_ROOT/integrations/kaiten/scripts/kaiten-cards.sh" \
        "$SANDBOX/integrations/kaiten/scripts/"
    cp "$REPO_ROOT/integrations/hub-meta/scripts/load-env.sh" "$SANDBOX/integrations/hub-meta/scripts/"

    cat > "$SANDBOX/.env" <<'ENV'
KAITEN_TOKEN=test-token
KAITEN_DOMAIN=example.invalid
ENV

    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$SANDBOX/curl.log"
printf -- '---\n' >> "$SANDBOX/curl.log"
for url; do :; done
out=""
prev=""
for a; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
case "\$url" in
    */api/latest/cards/42)
        printf '%s\n200' '{"id":42,"uid":"$CARD_UID","files":[
            {"id":"$RESTRICTED_ID","name":"new.png","type":11,"size":"10","entity_type":"card","url":"https://signed.invalid/stale"},
            {"id":$LEGACY_ID,"name":"old.txt","type":1,"size":3,"url":"https://files.invalid/old.txt"},
            {"id":556,"name":"gone.txt","type":1,"size":3,"deleted":true,"url":"https://files.invalid/gone.txt"}]}' ;;
    */api/latest/cards/43)
        printf '%s\n200' '{"id":43}' ;;
    */api/latest/cards/$CARD_UID/files/$RESTRICTED_ID)
        printf '%s\n200' '{"id":"$RESTRICTED_ID","url":"https://signed.invalid/fresh"}' ;;
    */api/latest/cards/$CARD_UID/files)
        printf '%s\n200' '{"id":"new-file-uuid"}' ;;
    https://signed.invalid/fresh)
        printf 'restricted-bytes' > "\$out" ;;
    https://files.invalid/old.txt)
        printf 'legacy-bytes' > "\$out" ;;
    *)
        exit 22 ;;
esac
STUB
    chmod +x "$SANDBOX/bin/curl"
    PATH="$SANDBOX/bin:$PATH"
    export PATH

    CARDS="$SANDBOX/integrations/kaiten/scripts/kaiten-cards.sh"
    printf '<html>report</html>' > "$SANDBOX/report.html"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "attach uploads by card uid, never by numeric id" {
    run bash "$CARDS" attach 42 "$SANDBOX/report.html"
    [ "$status" -eq 0 ]
    grep -q "https://example.invalid/api/latest/cards/$CARD_UID/files" "$SANDBOX/curl.log"
    ! grep -q "api/latest/cards/42/files" "$SANDBOX/curl.log"
    grep -q "file=@\"$SANDBOX/report.html\"" "$SANDBOX/curl.log"
}

@test "attach fails before upload when the card has no uid" {
    run bash "$CARDS" attach 43 "$SANDBOX/report.html"
    [ "$status" -ne 0 ]
    [[ "$output" == *"has no uid"* ]] || false
    ! grep -q -- "-F" "$SANDBOX/curl.log"
}

@test "attach rejects a non-numeric card id" {
    run bash "$CARDS" attach "$CARD_UID" "$SANDBOX/report.html"
    [ "$status" -ne 0 ]
    [ ! -f "$SANDBOX/curl.log" ]
}

@test "files lists both generations without urls and skips deleted" {
    run bash "$CARDS" files 42
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" -eq 2 ]
    [ "$(jq -r '.[0].restricted' <<< "$output")" = "true" ]
    [ "$(jq -r '.[0].size' <<< "$output")" = "10" ]
    [ "$(jq -r '.[1].restricted' <<< "$output")" = "false" ]
    [[ "$output" != *"url"* ]] || false
}

@test "download of a restricted file asks for a fresh signed link and sends no token there" {
    run bash "$CARDS" download 42 "$RESTRICTED_ID" "$SANDBOX/out.png"
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/out.png")" = "restricted-bytes" ]
    ! grep -q "signed.invalid/stale" "$SANDBOX/curl.log"
    # The last curl call is the download; Authorization must not appear in its arguments.
    last_call="$(awk 'BEGIN{RS="---\n"} {c=$0} END{print c}' "$SANDBOX/curl.log")"
    [[ "$last_call" == *"https://signed.invalid/fresh"* ]] || false
    [[ "$last_call" != *"Authorization"* ]] || false
}

@test "download of a legacy file uses its public url" {
    run bash "$CARDS" download 42 "$LEGACY_ID" "$SANDBOX/out.txt"
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/out.txt")" = "legacy-bytes" ]
}

@test "download of an unknown file fails with a clear message" {
    run bash "$CARDS" download 42 nope "$SANDBOX/out.bin"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found on card 42"* ]] || false
    [ ! -f "$SANDBOX/out.bin" ]
}
