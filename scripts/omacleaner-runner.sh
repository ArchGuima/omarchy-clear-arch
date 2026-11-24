#!/usr/bin/env bash
# Coordinates selected OmaCleaner cleanup steps.
# Uses a single pkexec elevation for root tasks, and runs user tasks unprivileged.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_HELPER="$SCRIPT_DIR/omacleaner-root.sh"

emit_log() {
  printf '@@LOG:%s\n' "$*"
}

pipe_log() {
  local l
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ -n "$l" ]]; then
      emit_log "$l"
    fi
  done
}

resolve_xdg_dir() {
  local env_val="${1:-}"
  local fallback_rel="$2"
  if [[ -n "$env_val" && "$env_val" == /* ]]; then
    printf '%s' "${env_val%/}"
  elif [[ -n "${HOME:-}" && "$HOME" == /* ]]; then
    printf '%s' "${HOME%/}/$fallback_rel"
  fi
}

clear_user_dir() {
  local dir="$1"
  [[ -n "$dir" && "$dir" == /* && "$dir" != "/" ]] || return 0
  if [[ -L "$dir" ]]; then
    emit_log "[user_cache] Skipping symlinked directory: $dir"
    return 0
  fi
  if [[ -d "$dir" ]]; then
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || return 1
  fi
  return 0
}

emit_step() {
  local step="$1"
  local status="$2"
  local detail="${3:-}"
  if [[ -n "$detail" ]]; then
    printf '@@STEP:%s:%s:%s\n' "$step" "$status" "$detail"
  else
    printf '@@STEP:%s:%s\n' "$step" "$status"
  fi
}

emit_progress() {
  printf '@@PROGRESS:%s\n' "$1"
}

if (( $# == 0 )); then
  emit_log "No cleanup steps selected."
  emit_progress 100
  exit 0
fi

declare -a valid_steps=()
declare -a root_steps=()
run_aur_user=0
run_user_cache=0

for arg in "$@"; do
  case "$arg" in
    orphans|pacman_cache|journal|dns_cache|ram_swap|pacnew)
      valid_steps+=("$arg")
      root_steps+=("$arg")
      ;;
    aur_cache)
      valid_steps+=("$arg")
      root_steps+=("aur_pkg")
      run_aur_user=1
      ;;
    user_cache)
      valid_steps+=("$arg")
      run_user_cache=1
      ;;
    *)
      emit_log "Ignoring unknown step: $arg"
      ;;
  esac
done

total=${#valid_steps[@]}
if (( total == 0 )); then
  emit_log "No valid cleanup steps selected."
  emit_progress 100
  exit 0
fi

completed=0
overall_rc=0

bump_progress() {
  completed=$((completed + 1))
  local pct=$(( (completed * 100) / total ))
  (( pct > 100 )) && pct=100
  emit_progress "$pct"
}

# 1. Execute all privileged steps in a single pkexec prompt first so a cancelled
#    authentication aborts cleanly before making partial changes.
aur_pkg_failed=0
if (( ${#root_steps[@]} > 0 )); then
  emit_log "Requesting administrator authorization..."
  root_helper_started=0
  pkexec_rc=0
  exec {pkexec_fd}< <(pkexec /usr/bin/bash "$ROOT_HELPER" "${root_steps[@]}" 2>&1)
  pkexec_pid=$!
  while IFS= read -r line <&"$pkexec_fd" || [[ -n "$line" ]]; do
    if [[ "$line" == @@STEP:*:START ]]; then
      root_helper_started=1
    fi
    if [[ "$line" == @@STEP:aur_cache:ERROR:* ]]; then
      aur_pkg_failed=1
      continue
    fi
    printf '%s\n' "$line"
    case "$line" in
      @@STEP:*:DONE|@@STEP:*:WARN:*|@@STEP:*:ERROR:*)
        bump_progress
        ;;
    esac
  done
  exec {pkexec_fd}<&-
  wait "$pkexec_pid" || pkexec_rc=$?

  if (( pkexec_rc == 126 || pkexec_rc == 127 )); then
    printf '@@AUTH_CANCELLED\n'
    emit_log "Administrator authentication was cancelled."
    exit 126
  elif (( pkexec_rc != 0 && root_helper_started == 0 )); then
    emit_log "Administrator authorization failed before privileged cleanup started (exit $pkexec_rc)."
    exit "$pkexec_rc"
  elif (( pkexec_rc != 0 )); then
    overall_rc=1
  fi
fi

# 2. Clean user-level AUR build cache (yay/paru refuse to run as root).
if (( run_aur_user == 1 )); then
  aur_ok=1
  if command -v yay >/dev/null 2>&1; then
    emit_log "[aur_cache] Cleaning yay AUR cache..."
    yay -Sc --aur --noconfirm 2>&1 | pipe_log || aur_ok=0
  elif command -v paru >/dev/null 2>&1; then
    emit_log "[aur_cache] Cleaning paru AUR cache..."
    paru -Sc --aur --noconfirm 2>&1 | pipe_log || aur_ok=0
  else
    emit_log "[aur_cache] No supported AUR helper (yay/paru) installed."
  fi

  if (( aur_ok == 1 && aur_pkg_failed == 0 )); then
    emit_step aur_cache DONE
  else
    emit_step aur_cache ERROR "AUR/pkg cache cleanup failed"
    overall_rc=1
  fi
  bump_progress
fi

# 3. Clean user thumbnails and Trash.
if (( run_user_cache == 1 )); then
  emit_step user_cache START
  emit_log "[user_cache] Clearing thumbnails and user Trash..."
  cache_base=$(resolve_xdg_dir "${XDG_CACHE_HOME:-}" ".cache")
  data_base=$(resolve_xdg_dir "${XDG_DATA_HOME:-}" ".local/share")
  user_cache_ok=1
  if [[ -n "$cache_base" ]]; then
    clear_user_dir "$cache_base/thumbnails" || user_cache_ok=0
  fi
  if [[ -n "$data_base" ]]; then
    clear_user_dir "$data_base/Trash" || user_cache_ok=0
  fi
  if (( user_cache_ok == 1 )); then
    emit_log "[user_cache] Thumbnails and Trash cleared."
    emit_step user_cache DONE
  else
    emit_log "[user_cache] Failed to clear some items in thumbnails or Trash."
    emit_step user_cache ERROR "Failed to clear thumbnails or Trash"
    overall_rc=1
  fi
  bump_progress
fi

emit_progress 100
exit "$overall_rc"
