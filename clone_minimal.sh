#!/bin/bash

# Minimal disk cloner with optional ext4 shrink
# - Lets user choose SOURCE and TARGET devices
# - Optional: shrink SOURCE ext4 root partition to minimum (non-destructive)
# - Clones disk → disk with dd + GPT backup fix (sgdisk -e)

set -euo pipefail

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
require dd
require sfdisk

# Build numbered list of root disks: /dev/sd[a-z] and /dev/nvme*n1
mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && ($1 ~ /^sd[a-z]+$/ || $1 ~ /^nvme[0-9]+n[0-9]+$/) {print $1}' | sort)

if [ ${#DISKS[@]} -eq 0 ]; then
  echo "No /dev/sdX disks found."; exit 1
fi

echo "=== Available Disks (root disks only) ==="
for i in "${!DISKS[@]}"; do
  NAME="${DISKS[$i]}"
  SIZE=$(lsblk -dn -o SIZE "/dev/$NAME")
  MODEL=$(lsblk -dn -o MODEL "/dev/$NAME" | sed 's/^ *$/(unknown)/')
  PT=$(lsblk -dn -o PTUUID "/dev/$NAME" >/dev/null 2>&1 && lsblk -dn -o PTTYPE "/dev/$NAME" || echo "?")
  echo "[$((i+1))] /dev/$NAME  size=$SIZE  model=$MODEL  pttype=${PT:-?}"
done
echo ""

read -rp "Select SOURCE number: " SRC_IDX
read -rp "Operation: [C]lone to device, [A]rchive image, or [R]estore from image? (C/A/R): " OP
OP=${OP:-C}
if [[ ! "$OP" =~ ^[CcAaRr]$ ]]; then echo "Invalid choice"; exit 1; fi

DST_IDX=-1
if [[ "$OP" =~ ^[Cc]$ ]]; then
  read -rp "Select TARGET number: " DST_IDX
fi

if ! [[ "$SRC_IDX" =~ ^[0-9]+$ ]] || ! [[ "$DST_IDX" =~ ^[0-9]+$ ]]; then
  echo "ERROR: selections must be numbers"; exit 1
fi

SRC_IDX=$((SRC_IDX-1))
if [ "$DST_IDX" -ge 0 ]; then DST_IDX=$((DST_IDX-1)); fi

if [ "$SRC_IDX" -lt 0 ] || [ "$SRC_IDX" -ge ${#DISKS[@]} ]; then
  echo "ERROR: source selection out of range"; exit 1
fi
if [[ "$OP" =~ ^[Cc]$ ]]; then
  if [ "$DST_IDX" -lt 0 ] || [ "$DST_IDX" -ge ${#DISKS[@]} ]; then
    echo "ERROR: target selection out of range"; exit 1
  fi
fi

SRC="/dev/${DISKS[$SRC_IDX]}"
if [[ "$OP" =~ ^[Cc]$ ]]; then
  DST="/dev/${DISKS[$DST_IDX]}"
else
  DST=""
fi

if [[ "$OP" =~ ^[Cc]$ ]] && [ "$SRC" = "$DST" ]; then
  echo "ERROR: SOURCE and TARGET must be different"; exit 1
fi

# Safety: detect if SOURCE is the current system disk (contains /)
SYS_ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
SYS_DISK=""
if [ -n "$SYS_ROOT_SRC" ]; then
  # Map root device to its parent disk name (e.g., sda, nvme0n1)
  PK=$(lsblk -no PKNAME "$SYS_ROOT_SRC" 2>/dev/null || true)
  if [ -n "$PK" ]; then SYS_DISK="/dev/$PK"; else SYS_DISK="$SYS_ROOT_SRC"; fi
fi
LIVE_ON_SOURCE=0
if [ -n "$SYS_DISK" ]; then
  # Normalize to disk path for nvme and sdX
  SRC_DISK="$SRC"
  # If a partition was selected as SRC (rare), map to its disk
  [ -b "$SRC" ] && SRC_PK=$(lsblk -no PKNAME "$SRC" 2>/dev/null || true)
  if [ -n "$SRC_PK" ]; then SRC_DISK="/dev/$SRC_PK"; fi
  if [ "$SRC_DISK" = "$SYS_DISK" ]; then
    LIVE_ON_SOURCE=1
  fi
fi

echo "SOURCE: $SRC"
if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "TARGET: $DST (WILL BE ERASED)"
  read -rp "Type YES to confirm clone: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Cancelled"; exit 1; }
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  # Default archive name to current dir with source device basename
  SRC_BASENAME=$(basename "$SRC")
  read -rp "Enter archive output file [default ./${SRC_BASENAME}.img.gz]: " ARCH
  ARCH=${ARCH:-./${SRC_BASENAME}.img.gz}
  if [ -e "$ARCH" ]; then read -rp "File exists. Overwrite? (y/N): " OW; [[ "$OW" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }; fi
elif [[ "$OP" =~ ^[Rr]$ ]]; then
  # Restore from image to selected target disk
  read -rp "Enter archive image file to restore (e.g., ./sdb.img.gz): " ARCH
  [ -f "$ARCH" ] || { echo "Archive not found: $ARCH"; exit 1; }
  echo "=== Available Disks (restore target) ==="
  for i in "${!DISKS[@]}"; do
    NAME="${DISKS[$i]}"; SIZE=$(lsblk -dn -o SIZE "/dev/$NAME"); MODEL=$(lsblk -dn -o MODEL "/dev/$NAME" | sed 's/^ *$/(unknown)/')
    echo "[$((i+1))] /dev/$NAME  size=$SIZE  model=$MODEL"
  done
  read -rp "Select TARGET number for restore: " DST_IDX
  DST_IDX=$((DST_IDX-1))
  if [ "$DST_IDX" -lt 0 ] || [ "$DST_IDX" -ge ${#DISKS[@]} ]; then echo "ERROR: target selection out of range"; exit 1; fi
  DST="/dev/${DISKS[$DST_IDX]}"
  echo "TARGET: $DST (WILL BE ERASED)"
  read -rp "Type YES to confirm restore: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Cancelled"; exit 1; }
fi

if [ "$LIVE_ON_SOURCE" -eq 1 ]; then
  echo "WARNING: You are operating on the current system disk (contains /)."
  echo "- Live cloning may produce an inconsistent image."
  echo "- Shrink/Grow operations on SOURCE will be disabled to avoid unmounting /."
  read -rp "Proceed with READ-ONLY cloning/archiving anyway? (y/N): " PROCEED_LIVE
  [[ "$PROCEED_LIVE" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }
fi

if [[ "$OP" =~ ^[CcRr]$ ]]; then
  echo "=== Unmounting target if mounted ==="
  # Unmount any mounted partitions on target
  lsblk -ln -o NAME,MOUNTPOINT "$DST" | awk '$2!="" {print "/dev/"$1}' | xargs -r -n1 umount || true
  lsblk "$DST"
fi

# Warn if source has mounted partitions (cloning a live system can cause inconsistencies)
if mount | awk -v d="$SRC" '$1 ~ d {found=1} END{exit !found}'; then
  echo "WARNING: Some partitions on $SRC are mounted. Cloning a live system may cause inconsistencies."
  read -rp "Proceed anyway? (y/N): " PROCLIVE
  [[ "$PROCLIVE" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }
fi

read -rp "Shrink all supported filesystems on SOURCE to minimum before operation? (y/N): " DO_SHRINK_ALL
if [[ "$DO_SHRINK_ALL" =~ ^[Yy]$ ]]; then
  if [ "$LIVE_ON_SOURCE" -eq 1 ]; then
    echo "Skip shrink: SOURCE contains current root filesystem; cannot safely unmount."
  else
  echo "=== Scanning partitions on $SRC for shrink ==="
  # List child partitions of the source disk only
  mapfile -t PARTS < <(lsblk -ln -o NAME,FSTYPE,MOUNTPOINT "$SRC" | awk 'NR>1 {print $1" "$2" "$3}')
  for line in "${PARTS[@]}"; do
    PNAME=$(echo "$line" | awk '{print $1}')
    FST=$(echo   "$line" | awk '{print $2}')
    MP=$(echo    "$line" | awk '{print $3}')
    DEV="/dev/$PNAME"
    case "$FST" in
      ext4)
        echo "--- ext4: $DEV ---"
        [ -n "$MP" ] && { echo "Unmounting $DEV from $MP"; umount "$DEV" || true; }
        if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
          e2fsck -f "$DEV" || true
          resize2fs -M "$DEV" || echo "WARN: resize2fs failed on $DEV"
        else
          echo "Missing e2fsck/resize2fs; skipping $DEV"
        fi
        ;;
      ntfs)
        echo "--- ntfs: $DEV ---"
        [ -n "$MP" ] && { echo "Unmounting $DEV from $MP"; umount "$DEV" || true; }
        if command -v ntfsresize >/dev/null 2>&1; then
          # Shrink NTFS to its minimum; non-destructive filesystem-only shrink
          ntfsresize -f -m "$DEV" || echo "WARN: ntfsresize failed on $DEV"
        else
          echo "Missing ntfsresize; skipping $DEV"
        fi
        ;;
      *)
        echo "--- skip: $DEV (fstype=$FST) ---"
        ;;
    esac
  done
  echo "Note: Partition boundaries are not changed in minimal script; only filesystems are minimized."
  fi
fi

echo "=== Estimating space consumption on target/archive ==="
# Compute approximate data footprint to be present on target (sum of used/min fs sizes)
estimate_bytes=0
mapfile -t PARTS2 < <(lsblk -ln -o NAME,FSTYPE,SIZE "$SRC" | awk 'NR>1 {print $1" "$2" "$3}')
for line in "${PARTS2[@]}"; do
  PNAME=$(echo "$line" | awk '{print $1}')
  FST=$(echo   "$line" | awk '{print $2}')
  PSIZE=$(echo  "$line" | awk '{print $3}')
  DEV="/dev/$PNAME"
  case "$FST" in
    ext4)
      if command -v tune2fs >/dev/null 2>&1; then
        BS=$(tune2fs -l "$DEV" 2>/dev/null | awk -F: '/Block size:/ {gsub(/ /,""); print $2}')
        BC=$(tune2fs -l "$DEV" 2>/dev/null | awk -F: '/Block count:/ {gsub(/ /,""); print $2}')
        FB=$(tune2fs -l "$DEV" 2>/dev/null | awk -F: '/Free blocks:/ {gsub(/ /,""); print $2}')
        if [ -n "$BS" ] && [ -n "$BC" ] && [ -n "$FB" ]; then
          used=$(( (BC - FB) * BS ))
          estimate_bytes=$(( estimate_bytes + used ))
          continue
        fi
      fi
      ;;
    ntfs)
      if command -v ntfsresize >/dev/null 2>&1; then
        # Parse minimal size from ntfsresize -i output (in bytes)
        minb=$(ntfsresize -i -f "$DEV" 2>&1 | awk '/minim/ {for(i=1;i<=NF;i++) if($i ~ /bytes/) {print $(i-1); exit}}')
        if [[ "$minb" =~ ^[0-9]+$ ]]; then
          estimate_bytes=$(( estimate_bytes + minb ))
          continue
        fi
      fi
      ;;
  esac
  # Fallback: add full partition size for unknown types
  # Convert PSIZE (e.g., 222.5G) to bytes via numfmt if available, else skip
  if command -v numfmt >/dev/null 2>&1; then
    b=$(numfmt --from=iec --to=none "$PSIZE" 2>/dev/null || true)
    if [[ "$b" =~ ^[0-9]+$ ]]; then
      estimate_bytes=$(( estimate_bytes + b ))
    fi
  fi
done

# Get device sizes
SRC_BYTES=$(blockdev --getsize64 "$SRC")
if [[ "$OP" =~ ^[Cc]$ ]]; then
  DST_BYTES=$(blockdev --getsize64 "$DST")
else
  DST_BYTES=0
fi

echo "Approx. data footprint to be present on target: $(numfmt --to=iec "$estimate_bytes" 2>/dev/null || echo $estimate_bytes bytes)"
echo "Source disk size (raw device):                 $(numfmt --to=iec "$SRC_BYTES" 2>/dev/null || echo $SRC_BYTES bytes)"
if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "Target disk size:                               $(numfmt --to=iec "$DST_BYTES" 2>/dev/null || echo $DST_BYTES bytes)"
  if [ "$SRC_BYTES" -gt "$DST_BYTES" ]; then
    echo "ERROR: Target is smaller than source; cannot proceed."
    exit 1
  fi
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  echo "Archive output:                                 $ARCH"
else
  echo "Restore image:                                  $ARCH"
fi

read -rp "Proceed with operation given the estimates above? (y/N): " PROCEED_EST
[[ "$PROCEED_EST" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }

if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "=== Start clone: $SRC → $DST ==="
else
  if [[ "$OP" =~ ^[Aa]$ ]]; then
    echo "=== Start archive: $SRC → $ARCH ==="
  else
    echo "=== Start restore: $ARCH → $DST ==="
  fi
fi
if [[ "$OP" =~ ^[Cc]$ ]]; then
  if command -v pv >/dev/null 2>&1; then
    dd if="$SRC" bs=1M conv=noerror,sync | pv -s "$(blockdev --getsize64 "$SRC")" | dd of="$DST" bs=1M conv=fsync
  else
    dd if="$SRC" of="$DST" bs=1M status=progress conv=noerror,sync,fsync
  fi
  sync
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  # Archive: store partition table for later restore
  sfdisk -d "$SRC" > "${ARCH%.gz}.sfdisk" 2>/dev/null || true
  if command -v pv >/dev/null 2>&1; then
    dd if="$SRC" bs=1M conv=noerror,sync | pv -s "$(blockdev --getsize64 "$SRC")" | gzip -1 > "$ARCH"
  else
    dd if="$SRC" bs=1M status=progress conv=noerror,sync | gzip -1 > "$ARCH"
  fi
  sync
else
  # Restore from archive image to target device
  if command -v pv >/dev/null 2>&1; then
    pv "$ARCH" | gzip -dc | dd of="$DST" bs=1M conv=fsync
  else
    gzip -dc "$ARCH" | dd of="$DST" bs=1M status=progress conv=fsync
  fi
  sync
fi

if [[ "$OP" =~ ^[CcRr]$ ]]; then
  echo "=== Post-clone adjustments ==="
  if command -v sgdisk >/dev/null 2>&1; then
    echo "Fixing GPT backup on target (if needed)..."
    sgdisk -e "$DST" || true
  fi
  partprobe "$DST" || true
  sync

  # Print summary of partitions for both disks
  echo "\n=== Source layout ==="
  lsblk "$SRC"
  echo "\n=== Target layout ==="
  lsblk "$DST"

  # Optional: fix low space on Linux root by growing ext4 to full partition and lowering reserved blocks
  read -rp "Grow ext4 filesystem on TARGET to fill its partition and set reserved to 1%? (y/N): " GROW
  if [[ "$GROW" =~ ^[Yy]$ ]]; then
    # Auto-detect single ext4 partition on target
    mapfile -t TGT_EXT4 < <(lsblk -ln -o NAME,FSTYPE "$DST" | awk '$2=="ext4" {print $1}')
    if [ ${#TGT_EXT4[@]} -eq 1 ]; then
      TP="/dev/${TGT_EXT4[0]}"
      echo "=== Growing $TP to fill its partition and reducing reserved blocks ==="
      mount | awk -v p="$TP" '$1 == p {print $3}' | xargs -r -n1 umount || true
      if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
        e2fsck -f "$TP" || true
        resize2fs "$TP" || true
        tune2fs -m 1 "$TP" || true
        echo "Done."
      else
        echo "e2fsck/resize2fs not available; skipping grow."
      fi
    else
      echo "Skip grow: ext4 auto-detect ambiguous or none found on target (${#TGT_EXT4[@]} candidates)."
    fi
  fi
else
  echo "Saved archive: $ARCH"
  echo "Partition table dump: ${ARCH%.gz}.sfdisk (if available)"
fi

# Optional: restore SOURCE filesystems (ext4/ntfs) back to full partition size
read -rp "Re-grow SOURCE filesystems (ext4/ntfs) to fill their partitions now? (y/N): " REGROW_SRC
if [[ "$REGROW_SRC" =~ ^[Yy]$ ]]; then
  if [ "$LIVE_ON_SOURCE" -eq 1 ]; then
    echo "Skip re-grow: SOURCE contains current root filesystem; cannot safely unmount."
  else
  echo "=== Re-growing filesystems on $SRC to full partition size ==="
  mapfile -t SPARTS < <(lsblk -ln -o NAME,FSTYPE,MOUNTPOINT "$SRC" | awk 'NR>1 {print $1" "$2" "$3}')
  for line in "${SPARTS[@]}"; do
    PNAME=$(echo "$line" | awk '{print $1}')
    FST=$(echo   "$line" | awk '{print $2}')
    MP=$(echo    "$line" | awk '{print $3}')
    DEV="/dev/$PNAME"
    case "$FST" in
      ext4)
        echo "--- ext4 grow: $DEV ---"
        [ -n "$MP" ] && { echo "Unmounting $DEV from $MP"; umount "$DEV" || true; }
        if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
          e2fsck -f "$DEV" || true
          resize2fs "$DEV" || echo "WARN: resize2fs grow failed on $DEV"
        else
          echo "Missing e2fsck/resize2fs; skipping $DEV"
        fi
        ;;
      ntfs)
        echo "--- ntfs grow: $DEV ---"
        [ -n "$MP" ] && { echo "Unmounting $DEV from $MP"; umount "$DEV" || true; }
        if command -v ntfsresize >/dev/null 2>&1; then
          # ntfsresize without size grows to maximum available in partition
          ntfsresize -f "$DEV" || echo "WARN: ntfsresize grow failed on $DEV"
        else
          echo "Missing ntfsresize; skipping $DEV"
        fi
        ;;
      *)
        echo "--- skip: $DEV (fstype=$FST) ---"
        ;;
    esac
  done
  echo "Done re-growing SOURCE filesystems."
  fi
fi

echo "=== Done ==="
echo "Cloned $SRC to $DST. If the target is larger, you may later expand partitions/filesystems."

