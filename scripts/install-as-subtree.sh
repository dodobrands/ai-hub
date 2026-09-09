#!/usr/bin/env bash
# Install dodobrands/ai-hub as a git subtree inside your overlay repository.
#
# Run this from the ROOT of your own git repo (e.g. your team overlay).
# After installation, the generic AI Hub lives under <prefix>/ and can be
# updated later with scripts/update-from-ai-hub.sh (or `make update-ai-hub`).
#
# Usage (one-liner, no local clone needed):
#   curl -sL https://raw.githubusercontent.com/dodobrands/ai-hub/main/scripts/install-as-subtree.sh | bash
#   curl -sL https://raw.githubusercontent.com/dodobrands/ai-hub/main/scripts/install-as-subtree.sh | bash -s integrations/sagos95-ai-hub
#
# Or, with a local clone of this repo:
#   ./scripts/install-as-subtree.sh [prefix]
#
# Env overrides:
#   AI_HUB_REMOTE     — remote name (default: ai-hub)
#   AI_HUB_URL        — remote URL (default: https://github.com/dodobrands/ai-hub.git)
#   AI_HUB_BRANCH     — branch (default: main)
#   AI_HUB_NAMESPACE  — slash-command namespace for symlinks (default: ai-hub)
#
# Default prefix: integrations/sagos95-ai-hub
set -euo pipefail

PREFIX="${1:-integrations/sagos95-ai-hub}"
REMOTE_NAME="${AI_HUB_REMOTE:-ai-hub}"
REMOTE_URL="${AI_HUB_URL:-https://github.com/dodobrands/ai-hub.git}"
BRANCH="${AI_HUB_BRANCH:-main}"
NAMESPACE="${AI_HUB_NAMESPACE:-ai-hub}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -d .git ]] || die "Not a git repo root. cd to your overlay repo first."

if [[ -e "$PREFIX" ]]; then
  die "Path '$PREFIX' already exists. Choose another prefix or remove it first."
fi

if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  die "Working tree has uncommitted changes. Commit or stash before subtree add."
fi

if git remote get-url "$REMOTE_NAME" &>/dev/null; then
  existing="$(git remote get-url "$REMOTE_NAME")"
  if [[ "$existing" != "$REMOTE_URL" ]]; then
    die "Remote '$REMOTE_NAME' already points to $existing (expected $REMOTE_URL)."
  fi
  echo ">>> Remote '$REMOTE_NAME' already configured."
else
  echo ">>> Adding remote '$REMOTE_NAME' → $REMOTE_URL"
  git remote add "$REMOTE_NAME" "$REMOTE_URL"
fi

echo ">>> Fetching $REMOTE_NAME/$BRANCH ..."
git fetch "$REMOTE_NAME" "$BRANCH"

echo ">>> git subtree add --prefix=$PREFIX $REMOTE_NAME $BRANCH --squash"
git subtree add --prefix="$PREFIX" "$REMOTE_NAME" "$BRANCH" --squash

# --- Link all commands from the subtree into .claude/commands/<namespace>/ ---
link_commands() {
  local prefix="$1"
  local namespace="$2"
  local target_dir=".claude/commands/$namespace"
  # target_dir is .claude/commands/<ns>/ → 3 levels up to repo root
  local up="../../../"

  mkdir -p "$target_dir"

  local created=0 skipped=0 conflicted=0
  shopt -s nullglob
  for cmd_file in "$prefix"/integrations/*/commands/*.md; do
    local base
    base=$(basename "$cmd_file")
    local link="$target_dir/$base"

    if [[ -L "$link" ]]; then
      # Already a symlink — check if it points where we expect; if yes, skip silently
      local current_target
      current_target=$(readlink "$link")
      if [[ "$current_target" == "${up}${cmd_file}" ]]; then
        ((skipped++))
      else
        echo "   ! $base already symlinked elsewhere (kept): $current_target"
        ((conflicted++))
      fi
      continue
    fi

    if [[ -e "$link" ]]; then
      echo "   ! $base exists as regular file — not overwriting"
      ((conflicted++))
      continue
    fi

    (cd "$target_dir" && ln -s "${up}${cmd_file}" "$base")
    echo "   + $base"
    ((created++))
  done
  shopt -u nullglob

  echo ">>> Symlinks in $target_dir/: $created created, $skipped already correct, $conflicted left in place"
}

echo ">>> Linking slash-commands into .claude/commands/$NAMESPACE/ ..."
link_commands "$PREFIX" "$NAMESPACE"

# --- Register the subtree as a plugin in .claude/settings.json ---
register_plugin() {
  local prefix="$1"
  local settings=".claude/settings.json"
  local plugin_path="./$prefix"

  if ! command -v jq &>/dev/null; then
    echo "   ! jq not found — skipping settings.json auto-registration"
    echo "     Register manually: add \"$plugin_path\" to .plugins in $settings"
    return
  fi

  mkdir -p "$(dirname "$settings")"

  if [[ ! -f "$settings" ]]; then
    echo "   + Creating $settings"
    echo "{}" > "$settings"
  fi

  if ! jq -e . "$settings" &>/dev/null; then
    echo "   ! $settings has invalid JSON — skipping auto-registration"
    echo "     Fix the file and add \"$plugin_path\" to .plugins manually"
    return
  fi

  if jq -e --arg p "$plugin_path" '.plugins // [] | index($p)' "$settings" &>/dev/null; then
    echo "   ✓ Plugin already registered in $settings"
    return
  fi

  # Add plugin_path to .plugins (create array if missing)
  local tmp
  tmp=$(mktemp)
  jq --arg p "$plugin_path" '.plugins = ((.plugins // []) + [$p])' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  echo "   + Registered \"$plugin_path\" in $settings"
}

echo ">>> Registering plugin in .claude/settings.json ..."
register_plugin "$PREFIX"

# --- Seed team-config.json from the subtree's example, if overlay doesn't have one ---
seed_team_config() {
  local prefix="$1"
  local example="$prefix/team-config.example.json"
  local target="team-config.json"

  if [[ ! -f "$example" ]]; then
    return
  fi

  if [[ -f "$target" ]]; then
    echo "   ✓ team-config.json already exists — leaving as is"
    return
  fi

  cp "$example" "$target"
  echo "   + Copied $example → $target"
  echo "     Fill in your team's board/channel IDs (edit manually, or ask your"
  echo "     AI agent to walk you through it via /$NAMESPACE:setup)."
}

echo ">>> Seeding team-config.json ..."
seed_team_config "$PREFIX"

cat <<EOF

================================================================
Installed dodobrands/ai-hub as subtree at: $PREFIX
Slash-commands linked under .claude/commands/$NAMESPACE/
Plugin registered in .claude/settings.json
team-config.json seeded from example (if it didn't exist yet)

You're ready — start Claude Code in this repo and all /$NAMESPACE:* commands
will be available.

Next step: fill team-config.json with your board/channel IDs — either edit it
manually, or run /$NAMESPACE:setup and let the AI help you fill it in.

Optional:
  * Add a Makefile target for future updates:
       update-ai-hub:
       	git subtree pull --prefix=$PREFIX $REMOTE_NAME $BRANCH --squash
       	@./$PREFIX/scripts/relink-commands.sh $PREFIX $NAMESPACE 2>/dev/null || true

Update anytime via:
  /ai-hub:update-ai-hub                         (natural language also works:
                                                 "обнови ai-hub инструменты")
  make update-ai-hub                            (if Makefile target added)
  ./$PREFIX/scripts/update-from-ai-hub.sh
================================================================
EOF
