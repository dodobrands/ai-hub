#!/bin/bash
# Gate: unit tests of the Time connector (integrations/time/connector) — pure TS modules under
# `bun test` or `node --test` (strip-types, node >= 22.6). Network-free; no npm install needed
# because src/* import nothing outside the standard library (the bun-only e2e test skips itself
# when connector/node_modules is absent).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/integrations/time/connector"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

node_ok() {
    command -v node >/dev/null 2>&1 || return 1
    local v major minor
    v=$(node --version | sed 's/^v//'); major=${v%%.*}; minor=${v#*.}; minor=${minor%%.*}
    [[ "$major" -gt 22 ]] || { [[ "$major" -eq 22 ]] && [[ "$minor" -ge 6 ]]; }
}

cd "$DIR" || { echo "connector dir missing: $DIR"; exit 1; }
if command -v bun >/dev/null 2>&1; then
    echo "time-connector unit tests: bun $(bun --version)"
    bun test test/*.test.ts; rc=$?
elif node_ok; then
    echo "time-connector unit tests: node $(node --version)"
    node --experimental-strip-types --no-warnings --test test/*.test.ts; rc=$?
else
    echo "SKIP: neither bun nor node >= 22.6 available"
    echo "| time-connector unit | ⏭ skipped (no runtime) |" >> "$SUMMARY"
    exit 0
fi
if [[ $rc -eq 0 ]]; then
    echo "| time-connector unit | ✅ pass |" >> "$SUMMARY"
else
    echo "| time-connector unit | ❌ fail |" >> "$SUMMARY"
fi
exit $rc
