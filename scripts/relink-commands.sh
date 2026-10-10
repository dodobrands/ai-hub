#!/usr/bin/env bash
# Create missing symlinks for slash-commands from a subtree prefix.
#
# Safe to run repeatedly — existing correct symlinks are left alone,
# conflicting files/symlinks are reported but NOT overwritten.
#
# Битые симлинки (интеграцию убрали, ссылка осталась) сообщаются всегда;
# удаляются только с флагом --prune.
#
# Usage:
#   ./relink-commands.sh [prefix] [namespace] [--prune]
#
# Defaults:
#   prefix    = integrations/sagos95-ai-hub
#   namespace = ai-hub
set -euo pipefail

PRUNE=0
POS1=""
POS2=""
for arg in "$@"; do
  case "$arg" in
    --prune) PRUNE=1 ;;
    *)       if [[ -z "$POS1" ]]; then POS1="$arg"; elif [[ -z "$POS2" ]]; then POS2="$arg"; fi ;;
  esac
done

PREFIX="${POS1:-integrations/sagos95-ai-hub}"
NAMESPACE="${POS2:-ai-hub}"

[[ -d "$PREFIX" ]] || { echo "ERROR: Prefix '$PREFIX' not found." >&2; exit 1; }

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/link-commands.sh"
[[ -f "$LIB" ]] || { echo "ERROR: lib not found: $LIB" >&2; exit 1; }
# shellcheck source=lib/link-commands.sh
. "$LIB"

lc_link_commands "$PREFIX" "$NAMESPACE" "$PRUNE"
