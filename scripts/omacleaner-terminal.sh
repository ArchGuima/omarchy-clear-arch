#!/usr/bin/env bash
# Interactive terminal mode for OmaCleaner Omarchy plugin.
set -euo pipefail

declare -a steps=()
if (( $# == 0 )); then
  steps=(orphans pacman_cache aur_cache journal user_cache dns_cache ram_swap pacnew)
else
  for arg in "$@"; do
    case "$arg" in
      orphans|pacman_cache|aur_cache|journal|user_cache|dns_cache|ram_swap|pacnew)
        steps+=("$arg")
        ;;
    esac
  done
fi

if (( ${#steps[@]} == 0 )); then
  echo "No cleanup steps selected."
  exit 0
fi

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
    echo "Skipping symlinked directory: $dir"
    return 0
  fi
  if [[ -d "$dir" ]]; then
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
  fi
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

needs_sudo=0
for step in "${steps[@]}"; do
  if [[ "$step" != "user_cache" ]]; then
    needs_sudo=1
  fi
done

if (( needs_sudo == 1 )); then
  echo "=== Verifying administrator privileges ==="
  sudo -v
fi

total=${#steps[@]}
idx=0

for step in "${steps[@]}"; do
  idx=$((idx + 1))
  echo ""
  case "$step" in
    orphans)
      echo "=== [$idx/$total] Removing orphan packages ==="
      mapfile -t orfaos < <(pacman -Qtdq 2>/dev/null || true)
      if (( ${#orfaos[@]} > 0 )); then
        printf '%s\n' "${orfaos[@]}"
        sudo pacman -Rns --noconfirm -- "${orfaos[@]}"
      else
        echo "No orphan packages found."
      fi
      ;;
    pacman_cache)
      echo "=== [$idx/$total] Cleaning Pacman cache ==="
      if command -v paccache >/dev/null 2>&1; then
        sudo paccache -rk2
        sudo paccache -ruk0
      else
        echo "'pacman-contrib' not installed. Using 'pacman -Sc'..."
        sudo pacman -Sc --noconfirm
      fi
      ;;
    aur_cache)
      echo "=== [$idx/$total] Cleaning AUR cache (yay / paru) & /var/cache/pacman/pkg ==="
      if command -v yay >/dev/null 2>&1; then
        yay -Sc --aur --noconfirm
      elif command -v paru >/dev/null 2>&1; then
        paru -Sc --aur --noconfirm
      else
        echo "No supported AUR helper found."
      fi
      sudo rm -rf -- /var/cache/pacman/pkg/*
      ;;
    journal)
      echo "=== [$idx/$total] Vacuuming systemd journal ==="
      sudo journalctl --vacuum-size=100M
      sudo journalctl --vacuum-time=7d
      ;;
    user_cache)
      echo "=== [$idx/$total] Clearing thumbnails and Trash ==="
      cache_base=$(resolve_xdg_dir "${XDG_CACHE_HOME:-}" ".cache")
      data_base=$(resolve_xdg_dir "${XDG_DATA_HOME:-}" ".local/share")
      if [[ -n "$cache_base" ]]; then
        clear_user_dir "$cache_base/thumbnails"
      fi
      if [[ -n "$data_base" ]]; then
        clear_user_dir "$data_base/Trash"
      fi
      echo "Thumbnails and Trash cleared."
      ;;
    dns_cache)
      echo "=== [$idx/$total] Flushing DNS cache ==="
      if systemctl is-active --quiet systemd-resolved; then
        sudo resolvectl flush-caches
      elif systemctl is-active --quiet dnsmasq; then
        sudo systemctl restart dnsmasq
      elif command -v nscd >/dev/null 2>&1 && systemctl is-active --quiet nscd; then
        sudo nscd -i hosts
      else
        echo "No active local DNS cache service detected."
      fi
      ;;
    ram_swap)
      echo "=== [$idx/$total] Dropping RAM caches and recycling SWAP ==="
      sync
      echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
      swaps=$(swapon --show=USED,NAME --bytes --noheadings --raw 2>/dev/null || true)
      if [[ -n "$swaps" ]]; then
        while IFS= read -r entry; do
          [[ -z "$entry" ]] && continue
          used_bytes="${entry%% *}"
          dev="${entry#* }"
          [[ -z "$dev" ]] && continue
          if [[ "$used_bytes" =~ ^[0-9]+$ ]] && (( used_bytes > 0 )); then
            avail_bytes=$(mem_available_bytes)
            if (( used_bytes + 134217728 >= avail_bytes )); then
              echo "Skipping $dev (insufficient available RAM to safely unload swap)."
              continue
            fi
          fi
          prio=$(swapon --show=PRIO --noheadings --raw "$dev" 2>/dev/null || true)
          if [[ "$prio" =~ ^-?[0-9]+$ ]]; then
            sudo swapoff -- "$dev" && sudo swapon -p "$prio" -- "$dev"
          else
            sudo swapoff -- "$dev" && sudo swapon -- "$dev"
          fi
        done <<< "$swaps"
        echo "SWAP recycled successfully."
      else
        echo "No active SWAP devices."
      fi
      ;;
    pacnew)
      echo "=== [$idx/$total] Checking .pacnew / .pacsave files ==="
      mapfile -t pacnews < <(sudo find /etc -regextype posix-extended -regex '.+\.pac(new|save)' 2>/dev/null || true)
      if (( ${#pacnews[@]} > 0 )); then
        echo "Warning: .pacnew/.pacsave files need review:"
        printf '  -> %s\n' "${pacnews[@]}"
        echo "Tip: Run 'pacdiff' to manage them safely."
      else
        echo "No pending .pacnew/.pacsave files."
      fi
      ;;
  esac
done

echo ""
echo "✔ Deep system cleanup completed!"
