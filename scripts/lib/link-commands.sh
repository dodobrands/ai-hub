#!/usr/bin/env bash
# Раскладка симлинков slash-команд из сабтри в .claude/commands/<namespace>/.
#
# Один источник правды для relink-commands.sh, update-from-ai-hub.sh и
# install-as-subtree.sh (последний берёт файл из уже добавленного сабтри —
# работает и в режиме `curl … | bash`, где локального клона нет).
#
# API:  lc_link_commands <prefix> <namespace> [prune]
# Вызов — из КОРНЯ overlay-репо. По умолчанию файлы только создаются: ничего не
# удаляется и не перезаписывается, спорные случаи печатаются и остаются человеку.
# prune=1 — дополнительно снести битые ссылки (явный опт-ин вызывающего).
#
# Целевой шелл — bash 3.2 (штатный на macOS): без mapfile и declare -A.

# Сколько «../» нужно, чтобы из каталога $1 попасть в корень репо (cwd).
# Каталог резолвится по РЕАЛЬНОМУ пути: у части overlay-репо .claude/commands/<ns>
# — симлинк внутрь сабтри, и фиксированные три уровня вверх там дают битые ссылки.
lc_up_prefix() { # $1=существующий каталог → «../../../»
  local dir_real root_real rel up seg
  dir_real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  root_real=$(pwd -P)
  if [ "$dir_real" = "$root_real" ]; then
    rel=""
  else
    case "$dir_real" in
      "$root_real"/*) rel=${dir_real#"$root_real"/} ;;
      *) return 1 ;;  # каталог команд вне репо — относительный путь не построить
    esac
  fi
  up=""
  local IFS=/
  for seg in $rel; do up="../$up"; done
  printf '%s' "$up"
}

# Ссылка на этот же файл уже есть под другим именем? Overlay-репо переименовывают
# команды под свои названия (publish-page.md → buildin-publish.md), и линк по
# исходному basename только плодит дубль в списке слэш-команд.
lc_existing_alias() { # $1=каталог команд $2=файл команды → имя алиаса
  local dir="$1" cmd="$2" f
  for f in "$dir"/*.md; do
    [ -L "$f" ] || continue
    [ -e "$f" ] || continue
    if [ "$f" -ef "$cmd" ]; then
      printf '%s' "${f##*/}"
      return 0
    fi
  done
  return 1
}

lc_link_commands() { # $1=prefix $2=namespace $3=prune(0|1, по умолчанию 0)
  local prefix="$1" namespace="$2" prune="${3:-0}"
  local target_dir=".claude/commands/$namespace"
  mkdir -p "$target_dir"

  local up
  if ! up=$(lc_up_prefix "$target_dir"); then
    echo "   ! $target_dir резолвится вне репо — симлинки не раскладываю" >&2
    return 1
  fi

  local had_nullglob=0
  if shopt -q nullglob; then had_nullglob=1; fi
  shopt -s nullglob

  local created=0 skipped=0 aliased=0 conflicted=0 dangling=0 pruned=0
  local cmd_file base link current_target alias_name f target
  for cmd_file in "$prefix"/integrations/*/commands/*.md; do
    base=${cmd_file##*/}
    link="$target_dir/$base"

    if [ -L "$link" ]; then
      # Сверяем по inode, а не по тексту ссылки: путь может быть записан иначе
      # (другая глубина «../»), но вести на тот же файл.
      if [ "$link" -ef "$cmd_file" ]; then
        skipped=$((skipped+1))
      else
        current_target=$(readlink "$link")
        echo "   ! $base → $current_target (оставил; ведёт не на файл сабтри)"
        conflicted=$((conflicted+1))
      fi
      continue
    fi

    if [ -e "$link" ]; then
      echo "   ! $base — обычный файл (оставил)"
      conflicted=$((conflicted+1))
      continue
    fi

    if alias_name=$(lc_existing_alias "$target_dir" "$cmd_file"); then
      echo "   = $base уже подключён как $alias_name (дубль не создаю)"
      aliased=$((aliased+1))
      continue
    fi

    ( cd "$target_dir" && ln -s "${up}${cmd_file}" "$base" )
    echo "   + $base"
    created=$((created+1))
  done

  # Битые симлинки: команда была, интеграцию убрали (или переименовали) — ссылка осталась.
  # Claude Code показывает такую команду в списке, а при вызове она падает на чтении файла,
  # поэтому о них надо хотя бы сообщать. Удаляем только по явному prune.
  for f in "$target_dir"/*.md; do
    [ -L "$f" ] || continue
    [ -e "$f" ] && continue
    base=${f##*/}
    target=$(readlink "$f")
    if [ "$prune" = "1" ]; then
      rm "$f"
      echo "   - $base → $target (removed: target missing)"
      pruned=$((pruned + 1))     # не ((x++)): при x=0 он возвращает статус 1 и падает под set -e в bash ≥4
    else
      echo "   ! $base → $target (dangling: target missing; --prune to remove)"
      dangling=$((dangling + 1)) # см. выше про ((x++)) и set -e
    fi
  done

  if [ "$had_nullglob" -eq 0 ]; then shopt -u nullglob; fi

  echo ">>> Симлинки в $target_dir/: создано $created, уже на месте $skipped, алиасов $aliased, оставлено $conflicted, битых $dangling, снесено $pruned"
}
