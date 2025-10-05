#!/bin/bash

set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

DISK=${1:-}
OUT=${2:-}

if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
  echo "Usage: sudo $0 /dev/sdX [/path/to/log.txt]" >&2
  exit 1
fi

ts=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-/tmp/win_clone_diag_${ts}.log}

exec > >(tee -a "$OUT") 2>&1

echo "=== Windows Clone Boot Diagnostics ==="
echo "Time: $(date -Is)"
echo "Kernel: $(uname -a)"
echo "Disk: $DISK"

echo
echo "--- lsblk (full) ---"
lsblk -e7 -o NAME,TYPE,SIZE,FSTYPE,LABEL,PARTLABEL,PARTUUID,UUID,MOUNTPOINT,PKNAME "$DISK" || true

echo
echo "--- blkid (all) ---"
/sbin/blkid || true

echo
echo "--- sfdisk -d ---"
sfdisk -d "$DISK" || true

echo
echo "--- gdisk -l ---"
gdisk -l "$DISK" || true

echo
echo "--- efibootmgr -v ---"
efibootmgr -v || true

echo
echo "--- Mounted filesystems ---"
mount || true

echo
echo "--- Identify EFI System Partition on target ---"
ESP_PART=$(lsblk -ln -o NAME,FSTYPE,PKNAME "$DISK" | awk '$2=="vfat" && $3!="" {print $1; exit}')
if [ -n "$ESP_PART" ]; then
  ESP_DEV="/dev/${ESP_PART}"
  echo "ESP: $ESP_DEV"
  TMPMP=$(mktemp -d /tmp/esp.XXXXXX)
  if mount -o ro "$ESP_DEV" "$TMPMP" 2>/dev/null; then
    echo "Mounted $ESP_DEV at $TMPMP (ro)"
    echo
    echo "--- ESP tree (top-level) ---"
    find "$TMPMP" -maxdepth 3 -type f -printf '%p\n' | sed "s|$TMPMP||" | sort || true
    echo
    echo "--- ESP: Microsoft Boot directory details ---"
    [ -d "$TMPMP/EFI/Microsoft/Boot" ] && ls -lah "$TMPMP/EFI/Microsoft/Boot" || true
    if [ -f "$TMPMP/EFI/Microsoft/Boot/BCD" ]; then
      echo
      echo "--- BCD file info ---"
      BCD="$TMPMP/EFI/Microsoft/Boot/BCD"
      ls -l "$BCD" || true
      sha256sum "$BCD" || true
      echo "Hexdump (first 256 bytes):"
      hexdump -C -n 256 "$BCD" || true
    else
      echo "BCD not found under EFI/Microsoft/Boot" >&2
    fi
    umount "$TMPMP" || true
  else
    echo "Failed to mount ESP $ESP_DEV" >&2
  fi
  rmdir "$TMPMP" 2>/dev/null || true
else
  echo "Could not detect an ESP on $DISK"
fi

echo
echo "--- Identify Windows NTFS volume on target ---"
WIN_PART=$(lsblk -ln -o NAME,FSTYPE,PKNAME,SIZE "$DISK" | awk '$2=="ntfs" && $3!="" {print $1; exit}')
if [ -n "$WIN_PART" ]; then
  WIN_DEV="/dev/${WIN_PART}"
  echo "Windows NTFS: $WIN_DEV"
  TMPM=$(mktemp -d /tmp/win.XXXXXX)
  if mount -o ro,show_sys_files "$WIN_DEV" "$TMPM" 2>/dev/null; then
    echo "Mounted $WIN_DEV at $TMPM (ro)"
    echo "Presence checks:"
    for p in Windows/System32 winload.efi Boot/BCD; do
      if [ -e "$TMPM/$p" ]; then echo "  OK: $p"; else echo "  MISSING: $p"; fi
    done
    umount "$TMPM" || true
  else
    echo "Failed to mount Windows partition $WIN_DEV" >&2
  fi
  rmdir "$TMPM" 2>/dev/null || true
else
  echo "Could not detect an NTFS Windows partition on $DISK"
fi

echo
echo "--- dmesg (EFI, disk) recent ---"
dmesg | tail -n 300 | grep -Ei 'efi|gpt|nvme|sd[a-z]|sata|boot' || true

echo
echo "Log saved to: $OUT"

