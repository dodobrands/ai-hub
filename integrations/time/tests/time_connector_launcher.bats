#!/usr/bin/env bats
# Launcher tests for scripts/time-connector.sh — env discovery, team-config resolution,
# runtime detection and the no-token guard. Network-free: the TS server is replaced by a stub
# and the runtime by fake `bun`/`node` binaries on PATH.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX/home"   # isolate profile-level .env fallbacks
    mkdir -p "$HOME" "$SANDBOX/repo/integrations/time/scripts" "$SANDBOX/repo/integrations/time/connector" \
             "$SANDBOX/repo/integrations/hub-meta/scripts" "$SANDBOX/bin"
    cp "$ROOT/integrations/time/scripts/time-connector.sh" "$SANDBOX/repo/integrations/time/scripts/"
    cp "$ROOT/integrations/hub-meta/scripts/load-env.sh" "$SANDBOX/repo/integrations/hub-meta/scripts/"
    echo '// stub' > "$SANDBOX/repo/integrations/time/connector/server.ts"
    mkdir -p "$SANDBOX/repo/integrations/time/connector/node_modules/@modelcontextprotocol/sdk"
    # fake runtimes: print what they were asked to run, never touch the network
    printf '#!/bin/bash\necho "FAKE-BUN $*"\n' > "$SANDBOX/bin/bun"
    printf '#!/bin/bash\nif [[ "$1" == "--version" ]]; then echo "v%s"; exit 0; fi\necho "FAKE-NODE $*"\n' "${FAKE_NODE_VERSION:-22.12.0}" > "$SANDBOX/bin/node"
    chmod +x "$SANDBOX/bin/bun" "$SANDBOX/bin/node"
    LAUNCHER="$SANDBOX/repo/integrations/time/scripts/time-connector.sh"
    # clean slate: no inherited secrets or overrides
    unset TIME_BOT_TOKEN TIME_TEAM_CONFIG TIME_CONNECTOR_RUNTIME TIME_CONNECTOR_ALLOWED_USERS HUB_ENV_FILE HUB_OVERLAY_ROOT
    export PATH="$SANDBOX/bin:/usr/bin:/bin"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "print-env: no token → TIME_BOT_TOKEN=missing, exit 0, no secrets printed" {
    run bash "$LAUNCHER" print-env
    [ "$status" -eq 0 ]
    [[ "$output" == *"TIME_BOT_TOKEN=missing"* ]]
    [[ "$output" == *"RUNTIME=bun"* ]]
}

@test "print-env: token from repo-root .env is reported as set but never echoed" {
    echo 'TIME_BOT_TOKEN=supersecret123' > "$SANDBOX/repo/.env"
    run bash "$LAUNCHER" print-env
    [ "$status" -eq 0 ]
    [[ "$output" == *"TIME_BOT_TOKEN=set"* ]]
    [[ "$output" != *"supersecret123"* ]]
}

@test "serve without token → exit 1, stdout empty, stderr names TIME_BOT_TOKEN" {
    run --separate-stderr bash "$LAUNCHER" serve
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"TIME_BOT_TOKEN"* ]]
}

@test "team-config.json at the repo root is discovered via HUB_OVERLAY_ROOT" {
    echo 'TIME_BOT_TOKEN=x' > "$SANDBOX/repo/.env"
    echo '{"time":{"connector":{"allowed_users":["j.doe"]}}}' > "$SANDBOX/repo/team-config.json"
    run bash "$LAUNCHER" print-env
    [ "$status" -eq 0 ]
    [[ "$output" == *"TIME_TEAM_CONFIG=$SANDBOX/repo/team-config.json"* ]]
}

@test "explicit TIME_TEAM_CONFIG override wins" {
    echo '{}' > "$SANDBOX/repo/team-config.json"
    echo '{}' > "$SANDBOX/custom.json"
    TIME_TEAM_CONFIG="$SANDBOX/custom.json" run bash "$LAUNCHER" print-env
    [[ "$output" == *"TIME_TEAM_CONFIG=$SANDBOX/custom.json"* ]]
}

@test "serve execs bun with server.ts serve and inherits TIME_BASE_URL from .env" {
    printf 'TIME_BOT_TOKEN=x\nTIME_BASE_URL=https://example.time-messenger.ru\n' > "$SANDBOX/repo/.env"
    run bash "$LAUNCHER" serve
    [ "$status" -eq 0 ]
    [[ "$output" == "FAKE-BUN server.ts serve" ]]
}

@test "check mode is passed through to the server" {
    echo 'TIME_BOT_TOKEN=x' > "$SANDBOX/repo/.env"
    run bash "$LAUNCHER" check
    [[ "$output" == "FAKE-BUN server.ts check" ]]
}

@test "falls back to node >= 22.6 with strip-types when bun is absent" {
    rm "$SANDBOX/bin/bun"
    echo 'TIME_BOT_TOKEN=x' > "$SANDBOX/repo/.env"
    run bash "$LAUNCHER" serve
    [ "$status" -eq 0 ]
    [[ "$output" == "FAKE-NODE --experimental-strip-types --no-warnings server.ts serve" ]]
}

@test "TIME_CONNECTOR_RUNTIME=node forces node even when bun exists" {
    echo 'TIME_BOT_TOKEN=x' > "$SANDBOX/repo/.env"
    TIME_CONNECTOR_RUNTIME=node run bash "$LAUNCHER" print-env
    [[ "$output" == *"RUNTIME=node"* ]]
}

@test "old node (< 22.6) and no bun → RUNTIME=missing and serve exits 1" {
    rm "$SANDBOX/bin/bun"
    printf '#!/bin/bash\nif [[ "$1" == "--version" ]]; then echo v20.11.0; exit 0; fi\n' > "$SANDBOX/bin/node"
    chmod +x "$SANDBOX/bin/node"
    echo 'TIME_BOT_TOKEN=x' > "$SANDBOX/repo/.env"
    run bash "$LAUNCHER" print-env
    [[ "$output" == *"RUNTIME=missing"* ]]
    run --separate-stderr bash "$LAUNCHER" serve
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"bun"* ]]
}

@test "unknown mode → exit 2" {
    run bash "$LAUNCHER" bogus
    [ "$status" -eq 2 ]
}
