#!/usr/bin/env bash
# Read-only scan for OmaCleaner Omarchy plugin.
# Reports cleanable cache sizes, orphan packages, and pending .pacnew/.pacsave files.
set -uo pipefail

dir_bytes() {
  local total=0
  local path
  for path in "$@"; do
    if [[ -d "$path" ]]; then
      local sz
      sz=$(du -sb -- "$path" 2>/dev/null | awk '{print $1}')
      if [[ "${sz:-}" =~ ^[0-9]+$ ]]; then
        total=$((total + sz))
      fi
    fi
  done
  printf '%s' "$total"
}

orphans_count=0
if command -v pacman >/dev/null 2>&1; then
  orphans_count=$(pacman -Qtdq 2>/dev/null | wc -l | tr -d '[:space:]')
  [[ "$orphans_count" =~ ^[0-9]+$ ]] || orphans_count=0
fi

pacman_cache_bytes=$(dir_bytes /var/cache/pacman/pkg)
aur_cache_bytes=$(dir_bytes "${XDG_CACHE_HOME:-$HOME/.cache}/yay" "${XDG_CACHE_HOME:-$HOME/.cache}/paru")
journal_bytes=$(dir_bytes /var/log/journal /run/log/journal)
user_cache_bytes=$(dir_bytes "${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails" "${XDG_DATA_HOME:-$HOME/.local/share}/Trash")

pacnew_count=$(find /etc -maxdepth 4 -regextype posix-extended -regex '.+\.pac(new|save)' 2>/dev/null | wc -l | tr -d '[:space:]')
[[ "$pacnew_count" =~ ^[0-9]+$ ]] || pacnew_count=0

printf 'orphans_count=%s\n' "$orphans_count"
printf 'pacman_cache_bytes=%s\n' "$pacman_cache_bytes"
printf 'aur_cache_bytes=%s\n' "$aur_cache_bytes"
printf 'journal_bytes=%s\n' "$journal_bytes"
printf 'user_cache_bytes=%s\n' "$user_cache_bytes"
printf 'pacnew_count=%s\n' "$pacnew_count"
