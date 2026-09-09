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

target_dir=".claude/commands/$NAMESPACE"
up="../../../"

mkdir -p "$target_dir"

created=0 skipped=0 conflicted=0
shopt -s nullglob
for cmd_file in "$PREFIX"/integrations/*/commands/*.md; do
  base=$(basename "$cmd_file")
  link="$target_dir/$base"

  if [[ -L "$link" ]]; then
    current_target=$(readlink "$link")
    if [[ "$current_target" == "${up}${cmd_file}" ]]; then
      ((skipped++))
    else
      echo "   ! $base → $current_target (kept; points elsewhere)"
      ((conflicted++))
    fi
    continue
  fi

  if [[ -e "$link" ]]; then
    echo "   ! $base is a regular file (kept)"
    ((conflicted++))
    continue
  fi

  (cd "$target_dir" && ln -s "${up}${cmd_file}" "$base")
  echo "   + $base"
  ((created++))
done
shopt -u nullglob

# Битые симлинки: команда была, интеграцию убрали (или переименовали) — ссылка осталась.
# Claude Code показывает такую команду в списке, а при вызове она падает на чтении файла,
# поэтому о них надо хотя бы сообщать. Удаляем только по явному --prune.
dangling=0 pruned=0
shopt -s nullglob
for link in "$target_dir"/*.md; do
  [[ -L "$link" ]] || continue
  [[ -e "$link" ]] && continue
  base=$(basename "$link")
  target=$(readlink "$link")
  if [[ "$PRUNE" == "1" ]]; then
    rm "$link"
    echo "   - $base → $target (removed: target missing)"
    pruned=$((pruned + 1))     # не ((x++)): при x=0 он возвращает статус 1 и падает под set -e в bash ≥4
  else
    echo "   ! $base → $target (dangling: target missing; --prune to remove)"
    dangling=$((dangling + 1)) # см. выше про ((x++)) и set -e
  fi
done
shopt -u nullglob

echo "Symlinks in $target_dir/: $created created, $skipped already correct, $conflicted left in place, $dangling dangling, $pruned pruned"
