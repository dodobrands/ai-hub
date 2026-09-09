#!/usr/bin/env bash
# Pull the latest dodobrands/ai-hub into an existing subtree prefix and
# re-create any missing symlinks for newly added slash-commands.
#
# Run from the root of your overlay repo. If scripts/install-as-subtree.sh
# was used, pass the same prefix (or rely on the default).
#
# Usage:
#   ./scripts/update-from-ai-hub.sh [prefix]
#
# Env overrides:
#   AI_HUB_REMOTE     — remote name (default: ai-hub)
#   AI_HUB_BRANCH     — branch (default: main)
#   AI_HUB_NAMESPACE  — slash-command namespace (default: ai-hub)
#
# Default prefix: integrations/sagos95-ai-hub
set -euo pipefail

PREFIX="${1:-integrations/sagos95-ai-hub}"
REMOTE_NAME="${AI_HUB_REMOTE:-ai-hub}"
BRANCH="${AI_HUB_BRANCH:-main}"
NAMESPACE="${AI_HUB_NAMESPACE:-ai-hub}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -d .git ]] || die "Not a git repo root. cd to your overlay repo first."
[[ -d "$PREFIX" ]] || die "Prefix '$PREFIX' not found. Run install-as-subtree.sh first."
git remote get-url "$REMOTE_NAME" &>/dev/null || die "Remote '$REMOTE_NAME' not configured."

if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  die "Working tree has uncommitted changes. Commit or stash before subtree pull."
fi

echo ">>> git subtree pull --prefix=$PREFIX $REMOTE_NAME $BRANCH --squash"
git subtree pull --prefix="$PREFIX" "$REMOTE_NAME" "$BRANCH" --squash

# --- Add symlinks for any NEW commands that arrived in the pull ---
link_commands() {
  local prefix="$1"
  local namespace="$2"
  local target_dir=".claude/commands/$namespace"
  local up="../../../"

  mkdir -p "$target_dir"

  local created=0 skipped=0 conflicted=0
  shopt -s nullglob
  for cmd_file in "$prefix"/integrations/*/commands/*.md; do
    local base
    base=$(basename "$cmd_file")
    local link="$target_dir/$base"

    if [[ -L "$link" ]]; then
      local current_target
      current_target=$(readlink "$link")
      if [[ "$current_target" == "${up}${cmd_file}" ]]; then
        ((skipped++))
      else
        ((conflicted++))
      fi
      continue
    fi

    if [[ -e "$link" ]]; then
      ((conflicted++))
      continue
    fi

    (cd "$target_dir" && ln -s "${up}${cmd_file}" "$base")
    echo "   + new symlink: $base"
    ((created++))
  done
  shopt -u nullglob

  if (( created > 0 )); then
    echo ">>> Symlinks: $created added"
  fi
}

link_commands "$PREFIX" "$NAMESPACE"

echo ">>> Done. Review the merge commit with: git log -1 --stat"
