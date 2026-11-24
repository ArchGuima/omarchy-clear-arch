#!/usr/bin/env bash
# Privileged worker for OmaCleaner Omarchy plugin (invoked via pkexec).
# Accepts only validated step identifiers as arguments.
set -uo pipefail

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
umask 022

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

mem_available_bytes() {
  local val
  val=$(awk '/^MemAvailable:/ { print $2 * 1024; exit }' /proc/meminfo 2>/dev/null || true)
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s' "$val"
  else
    printf '0'
  fi
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

if [[ "$EUID" -ne 0 ]]; then
  emit_log "Error: root privileges are required."
  exit 1
fi

# Validate every requested step against the strict allowlist before executing.
for arg in "$@"; do
  case "$arg" in
    orphans|pacman_cache|aur_pkg|journal|dns_cache|ram_swap|pacnew) ;;
    *)
      emit_log "Rejected unknown step: $arg"
      exit 2
      ;;
  esac
done

overall_rc=0

for step in "$@"; do
  case "$step" in
    orphans)
      emit_step orphans START
      emit_log "[orphans] Checking for orphan packages..."
      mapfile -t orfaos < <(pacman -Qtdq 2>/dev/null || true)
      if (( ${#orfaos[@]} > 0 )); then
        emit_log "[orphans] Removing ${#orfaos[@]} package(s): ${orfaos[*]}"
        if pacman -Rns --noconfirm -- "${orfaos[@]}" 2>&1 | pipe_log; then
          emit_step orphans DONE
        else
          emit_step orphans ERROR "pacman -Rns failed"
          overall_rc=1
        fi
      else
        emit_log "[orphans] No orphan packages found."
        emit_step orphans DONE
      fi
      ;;

    pacman_cache)
      emit_step pacman_cache START
      if command -v paccache >/dev/null 2>&1; then
        emit_log "[pacman_cache] Running paccache -rk2 and -ruk0..."
        if { paccache -rk2 && paccache -ruk0; } 2>&1 | pipe_log; then
          emit_step pacman_cache DONE
        else
          emit_step pacman_cache ERROR "paccache failed"
          overall_rc=1
        fi
      else
        emit_log "[pacman_cache] paccache not found; using pacman -Sc..."
        if pacman -Sc --noconfirm 2>&1 | pipe_log; then
          emit_step pacman_cache DONE
        else
          emit_step pacman_cache ERROR "pacman -Sc failed"
          overall_rc=1
        fi
      fi
      ;;

    aur_pkg)
      # Empties /var/cache/pacman/pkg/*; the user-level yay/paru cache cleanup
      # runs in the unprivileged runner right after.
      emit_step aur_cache START
      emit_log "[aur_cache] Clearing /var/cache/pacman/pkg/*..."
      if rm -rf -- /var/cache/pacman/pkg/*; then
        emit_log "[aur_cache] Emptied /var/cache/pacman/pkg/."
      else
        emit_step aur_cache ERROR "Failed to clear /var/cache/pacman/pkg"
        overall_rc=1
      fi
      ;;

    journal)
      emit_step journal START
      emit_log "[journal] Vacuuming systemd journal (100M / 7d)..."
      if { journalctl --vacuum-size=100M && journalctl --vacuum-time=7d; } 2>&1 | pipe_log; then
        emit_step journal DONE
      else
        emit_step journal ERROR "journalctl vacuum failed"
        overall_rc=1
      fi
      ;;

    dns_cache)
      emit_step dns_cache START
      if systemctl is-active --quiet systemd-resolved; then
        emit_log "[dns_cache] Flushing systemd-resolved cache..."
        if resolvectl flush-caches 2>&1 | pipe_log; then
          emit_step dns_cache DONE
        else
          emit_step dns_cache ERROR "resolvectl failed"
          overall_rc=1
        fi
      elif systemctl is-active --quiet dnsmasq; then
        emit_log "[dns_cache] Restarting dnsmasq..."
        if systemctl restart dnsmasq 2>&1 | pipe_log; then
          emit_step dns_cache DONE
        else
          emit_step dns_cache ERROR "dnsmasq restart failed"
          overall_rc=1
        fi
      elif command -v nscd >/dev/null 2>&1 && systemctl is-active --quiet nscd; then
        emit_log "[dns_cache] Invalidating nscd hosts cache..."
        if nscd -i hosts 2>&1 | pipe_log; then
          emit_step dns_cache DONE
        else
          emit_step dns_cache ERROR "nscd failed"
          overall_rc=1
        fi
      else
        emit_log "[dns_cache] No active local DNS cache service detected."
        emit_step dns_cache DONE
      fi
      ;;

    ram_swap)
      emit_step ram_swap START
      emit_log "[ram_swap] Syncing disks and dropping RAM caches..."
      sync
      step_ok=1
      if ! printf '3\n' > /proc/sys/vm/drop_caches; then
        emit_log "[ram_swap] Failed to write /proc/sys/vm/drop_caches."
        step_ok=0
      fi

      swaps=$(swapon --show=USED,NAME --bytes --noheadings --raw 2>/dev/null || true)
      if [[ -n "$swaps" ]]; then
        emit_log "[ram_swap] Recycling active SWAP devices..."
        while IFS= read -r entry; do
          [[ -z "$entry" ]] && continue
          used_bytes="${entry%% *}"
          dev="${entry#* }"
          [[ -z "$dev" ]] && continue
          if [[ "$used_bytes" =~ ^[0-9]+$ ]] && (( used_bytes > 0 )); then
            avail_bytes=$(mem_available_bytes)
            if (( used_bytes + 134217728 >= avail_bytes )); then
              emit_log "[ram_swap] Skipping $dev (insufficient available RAM to safely unload swap)."
              continue
            fi
          fi
          case "$dev" in
            /dev/zram*)
              unit="dev-$(basename -- "$dev").swap"
              if systemctl cat "$unit" >/dev/null 2>&1; then
                emit_log "[ram_swap] Restarting $unit..."
                systemctl restart "$unit" 2>&1 | pipe_log || step_ok=0
              else
                emit_log "[ram_swap] Skipping $dev (unmanaged zram)."
              fi
              ;;
            *)
              emit_log "[ram_swap] Cycling $dev..."
              if ! { swapoff -- "$dev" && swapon -- "$dev"; } 2>&1 | pipe_log; then
                step_ok=0
              fi
              ;;
          esac
        done <<< "$swaps"
        emit_log "[ram_swap] SWAP recycle finished."
      else
        emit_log "[ram_swap] No active SWAP devices."
      fi

      if (( step_ok == 1 )); then
        emit_step ram_swap DONE
      else
        emit_step ram_swap ERROR "RAM/SWAP cleanup error"
        overall_rc=1
      fi
      ;;

    pacnew)
      emit_step pacnew START
      emit_log "[pacnew] Scanning /etc for .pacnew/.pacsave files..."
      mapfile -t pacnews < <(find /etc -regextype posix-extended -regex '.+\.pac(new|save)' 2>/dev/null || true)
      if (( ${#pacnews[@]} > 0 )); then
        emit_log "[pacnew] Found ${#pacnews[@]} file(s) to review:"
        for f in "${pacnews[@]}"; do
          emit_log "  -> $f"
        done
        emit_log "[pacnew] Tip: run 'pacdiff' to review safely."
        emit_step pacnew WARN "${#pacnews[@]}"
      else
        emit_log "[pacnew] No pending .pacnew/.pacsave files."
        emit_step pacnew DONE
      fi
      ;;
  esac
done

exit "$overall_rc"
