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

needs_sudo=0
for step in "${steps[@]}"; do
  [[ "$step" != "user_cache" ]] && needs_sudo=1
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
      rm -rf -- "${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails"/* "${XDG_DATA_HOME:-$HOME/.local/share}/Trash"/* 2>/dev/null || true
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
      swaps=$(swapon --show=NAME --noheadings 2>/dev/null || true)
      if [[ -n "$swaps" ]]; then
        while IFS= read -r dev; do
          [[ -z "$dev" ]] && continue
          case "$dev" in
            /dev/zram*)
              unit="dev-$(basename -- "$dev").swap"
              if systemctl cat "$unit" >/dev/null 2>&1; then
                sudo systemctl restart "$unit"
              else
                echo "Skipping $dev (unmanaged zram)."
              fi
              ;;
            *)
              sudo swapoff -- "$dev" && sudo swapon -- "$dev"
              ;;
          esac
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
