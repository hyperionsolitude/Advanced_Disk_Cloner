#!/bin/bash

# Minimal disk cloner
# - Lets user choose SOURCE and TARGET devices
# - Clones disk → disk with dd + GPT backup fix (sgdisk -e)

set -euo pipefail

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }

# Self-test mode: validate environment and exit
if [ "${1:-}" = "--self-test" ]; then
  echo "=== Self-test ==="
  echo "OS: $(. /etc/os-release 2>/dev/null || true; echo "${NAME:-unknown}")"
  echo "User: $(id -un) (EUID=${EUID:-$(id -u)})"
  echo "Checking commands..."
  for cmd in dd sfdisk gzip tar lsblk awk pv gdisk partclone.extfs ntfsclone tune2fs e2fsck resize2fs; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo " - $cmd: OK"
    else
      echo " - $cmd: MISSING"
    fi
  done
  echo "Listing disks:"
  lsblk -dn -o NAME,TYPE,SIZE,MODEL || true
  echo "=== Self-test done ==="
  exit 0
fi

# --- Auto-install prerequisites (best effort) ---
echo "=== Advanced Disk Cloner ==="
echo "Checking prerequisites..."

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
run_root() { if is_root; then "$@"; else sudo "$@"; fi }

is_ubuntu() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || case ",${ID_LIKE:-}," in *,ubuntu,*|*,debian,*) return 1 ;; esac
    [ "${ID:-}" = "ubuntu" ] && return 0
  fi
  if command -v lsb_release >/dev/null 2>&1; then
    [ "$(lsb_release -is 2>/dev/null || true)" = "Ubuntu" ] && return 0
  fi
  return 1
}

install_packages() {
  if is_ubuntu; then
    if [ "$#" -gt 0 ]; then echo "Installing packages via apt: $*"; fi
    # Non-interactive, resilient apt
    export DEBIAN_FRONTEND=noninteractive
    run_root bash -c 'apt-get update -y || true; \
      apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"' bash "$@" || true
  else
    echo "WARN: Auto-install is supported only on Ubuntu (apt). Skipping." >&2
  fi
}

# Always attempt to install prerequisites on Ubuntu (non-fatal)
if is_ubuntu; then
  echo "Detected Ubuntu; ensuring required packages are installed..."
  # core + optional tools used by features in this script
  install_packages coreutils util-linux gzip tar pv gdisk partclone ntfs-3g e2fsprogs
else
  echo "WARN: Non-Ubuntu system detected. Please install prerequisites manually: coreutils util-linux gzip tar pv gdisk partclone ntfs-3g e2fsprogs" >&2
fi

# Ensure minimally required commands exist after best-effort install
require dd
require sfdisk
require gzip
require tar

# Report archive capabilities
HAS_PARTCLONE=no
HAS_NTFSCLONE=no
command -v partclone.extfs >/dev/null 2>&1 && HAS_PARTCLONE=yes || true
command -v ntfsclone >/dev/null 2>&1 && HAS_NTFSCLONE=yes || true
echo "Archive mode: used-block ext4=$HAS_PARTCLONE, ntfs=$HAS_NTFSCLONE (fallback to raw for others)"

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

if ! [[ "$SRC_IDX" =~ ^[0-9]+$ ]]; then
  echo "ERROR: source selection must be a number"; exit 1
fi
if [[ "$OP" =~ ^[Cc]$ ]] && ! [[ "$DST_IDX" =~ ^[0-9]+$ ]]; then
  echo "ERROR: target selection must be a number"; exit 1
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
  # Choose destination drive (mounted) and path for archive
  SRC_BASENAME=$(basename "$SRC")
  echo "=== Choose drive to SAVE the archive on ==="
  # Collect mounted destinations on real disks only (exclude loop devices)
  # Use entries where TYPE=part, MOUNTPOINT != empty, and parent disk PKNAME is sdX or nvme*n1
  mapfile -t MOUNTED < <(lsblk -ln -o NAME,TYPE,MOUNTPOINT,PKNAME | \
    awk '$2=="part" && $3!="" && ($4 ~ /^sd[a-z]+$/ || $4 ~ /^nvme[0-9]+n[0-9]+$/) {print $1" "$3}' | sort -k2,2 -u)
  if [ ${#MOUNTED[@]} -eq 0 ]; then
    echo "No mounted destinations found. Please mount a drive and retry."; exit 1
  fi
  for i in "${!MOUNTED[@]}"; do
    DN=$(echo "${MOUNTED[$i]}" | awk '{print $1}')
    MP=$(echo "${MOUNTED[$i]}" | awk '{print $2}')
    FREE=$(df -hP "$MP" 2>/dev/null | awk 'NR==2{print $4}')
    echo "[$((i+1))] /dev/$DN mounted at $MP  free=$FREE"
  done
  read -rp "Select destination by number (or press Enter to type a path manually): " DSTSAVE_IDX || true
  ARCH_DIR=""
  if [[ "$DSTSAVE_IDX" =~ ^[0-9]+$ ]]; then
    DSTSAVE_IDX=$((DSTSAVE_IDX-1))
    if [ "$DSTSAVE_IDX" -lt 0 ] || [ "$DSTSAVE_IDX" -ge ${#MOUNTED[@]} ]; then echo "ERROR: selection out of range"; exit 1; fi
    ARCH_DIR=$(echo "${MOUNTED[$DSTSAVE_IDX]}" | awk '{print $2}')
  else
    read -rp "Enter a directory path to save the archive (must exist): " ARCH_DIR
  fi
  [ -d "$ARCH_DIR" ] || { echo "Archive directory does not exist: $ARCH_DIR"; exit 1; }
  # Ask for file name or a path within the chosen destination (absolute path also accepted)
  read -rp "Enter archive file name or path [default ${SRC_BASENAME}.img.gz]: " ARCH_INPUT
  ARCH_INPUT=${ARCH_INPUT:-${SRC_BASENAME}.img.gz}
  # Determine full path: absolute provided → use as-is; otherwise place under chosen directory
  if [[ "$ARCH_INPUT" = /* ]]; then
    ARCH="$ARCH_INPUT"
  else
    # Treat leading ./ as relative to chosen destination directory
    ARCH="$ARCH_DIR/${ARCH_INPUT#./}"
  fi
  
  # If user provided a directory (ends with / or exists as a directory), use default filename inside it
  if [[ "$ARCH_INPUT" == */ ]] || [ -d "$ARCH" ]; then
    ARCH_DIRNAME="${ARCH%/}"
    ARCH_BASE="${SRC_BASENAME}.img.gz"
    ARCH="$ARCH_DIRNAME/$ARCH_BASE"
  else
    # Auto-append extension when missing on the basename
    ARCH_DIRNAME=$(dirname "$ARCH")
    ARCH_BASE=$(basename "$ARCH")
    if [[ -n "$ARCH_BASE" ]]; then
      if [[ "$ARCH_BASE" != *.gz ]]; then
        if [[ "$ARCH_BASE" == *.img ]]; then
          ARCH_BASE="${ARCH_BASE}.gz"
        else
          # If no dot in basename, append full .img.gz; otherwise leave as provided
          if [[ "$ARCH_BASE" != *.* ]]; then
            ARCH_BASE="${ARCH_BASE}.img.gz"
          fi
        fi
      fi
    fi
    ARCH="$ARCH_DIRNAME/$ARCH_BASE"
  fi
  
  # Ensure destination directory exists
  mkdir -p "$ARCH_DIRNAME"
  # Auto-append extension when missing on the basename
  ARCH_DIRNAME=$(dirname "$ARCH")
  ARCH_BASE=$(basename "$ARCH")
  if [[ -n "$ARCH_BASE" ]]; then
    if [[ "$ARCH_BASE" != *.gz ]]; then
      if [[ "$ARCH_BASE" == *.img ]]; then
        ARCH_BASE="${ARCH_BASE}.gz"
      else
        # If no dot in basename, append full .img.gz; otherwise leave as provided
        if [[ "$ARCH_BASE" != *.* ]]; then
          ARCH_BASE="${ARCH_BASE}.img.gz"
        fi
      fi
    fi
  fi
  ARCH="$ARCH_DIRNAME/$ARCH_BASE"
  if [ -e "$ARCH" ]; then read -rp "File exists at $ARCH. Overwrite? (y/N): " OW; [[ "$OW" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }; fi
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

## Shrinking feature removed

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
        T2=$(tune2fs -l "$DEV" 2>/dev/null || true)
        BS=$(printf '%s\n' "$T2" | awk -F: '/Block size:/ {gsub(/ /,""); print $2}')
        BC=$(printf '%s\n' "$T2" | awk -F: '/Block count:/ {gsub(/ /,""); print $2}')
        FB=$(printf '%s\n' "$T2" | awk -F: '/Free blocks:/ {gsub(/ /,""); print $2}')
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
  # Archive: prefer used-block per-partition imaging into a tarball if tools available
  if command -v partclone.extfs >/dev/null 2>&1 || command -v ntfsclone >/dev/null 2>&1; then
    TMPDIR=$(mktemp -d)
    cleanup_tmp() { [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"; }
    trap 'cleanup_tmp' EXIT INT TERM HUP
    MANIFEST="$TMPDIR/manifest.tsv"
    : > "$MANIFEST"
    # Save partition table dump
    sfdisk -d "$SRC" > "$TMPDIR/partition_table.sfdisk" 2>/dev/null || true
    # Enumerate partitions on source disk
    mapfile -t APARTS < <(lsblk -ln -o NAME,FSTYPE,SIZE,PARTLABEL,PARTUUID,PKNAME "$SRC" | awk 'NR>1 {print $1"\t"$2"\t"$3"\t"$4"\t"$5}')
    for line in "${APARTS[@]}"; do
      PNAME=$(echo -e "$line" | awk -F"\t" '{print $1}')
      FST=$(echo -e   "$line" | awk -F"\t" '{print $2}')
      DEV="/dev/$PNAME"
      OUTBASE="$TMPDIR/part-${PNAME}"
      case "$FST" in
        ext4)
          if command -v partclone.extfs >/dev/null 2>&1; then
            echo -e "$PNAME\text4\tpartclone" >> "$MANIFEST"
            if command -v pv >/dev/null 2>&1; then
              partclone.extfs -c -s "$DEV" -o - 2>/dev/null | pv | gzip -1 > "${OUTBASE}.pc.gz"
            else
              partclone.extfs -c -s "$DEV" -o - 2>/dev/null | gzip -1 > "${OUTBASE}.pc.gz"
            fi
          else
            echo -e "$PNAME\text4\tdd" >> "$MANIFEST"
            if command -v pv >/dev/null 2>&1; then
              dd if="$DEV" bs=1M status=none | pv | gzip -1 > "${OUTBASE}.raw.gz"
            else
              dd if="$DEV" bs=1M status=progress | gzip -1 > "${OUTBASE}.raw.gz"
            fi
          fi
          ;;
        ntfs)
          if command -v ntfsclone >/dev/null 2>&1; then
            echo -e "$PNAME\tntfs\tntfsclone" >> "$MANIFEST"
            if command -v pv >/dev/null 2>&1; then
              ntfsclone --save-image --output - "$DEV" 2>/dev/null | pv | gzip -1 > "${OUTBASE}.ntfs.gz"
            else
              ntfsclone --save-image --output - "$DEV" 2>/dev/null | gzip -1 > "${OUTBASE}.ntfs.gz"
            fi
          else
            echo -e "$PNAME\tntfs\tdd" >> "$MANIFEST"
            if command -v pv >/dev/null 2>&1; then
              dd if="$DEV" bs=1M status=none | pv | gzip -1 > "${OUTBASE}.raw.gz"
            else
              dd if="$DEV" bs=1M status=progress | gzip -1 > "${OUTBASE}.raw.gz"
            fi
          fi
          ;;
        *)
          # Unknown FS: fallback to raw partition dump
          echo -e "$PNAME\t$FST\tdd" >> "$MANIFEST"
          if command -v pv >/dev/null 2>&1; then
            dd if="$DEV" bs=1M status=none | pv | gzip -1 > "${OUTBASE}.raw.gz"
          else
            dd if="$DEV" bs=1M status=progress | gzip -1 > "${OUTBASE}.raw.gz"
          fi
          ;;
      esac
    done
    # Package everything into a tarball (new-format archive)
    ARCH_TAR="$ARCH"
    case "$ARCH_TAR" in
      *.gz|*.tgz) : ;;
      *) ARCH_TAR="${ARCH_TAR}.tar.gz" ;;
    esac
    (cd "$TMPDIR" && tar -czf "$ARCH_TAR" .)
    mv -f "$ARCH_TAR" "$ARCH" 2>/dev/null || true
    # Cleanup handled by trap
    sync
  else
    # Legacy full-disk raw archive
    sfdisk -d "$SRC" > "${ARCH%.gz}.sfdisk" 2>/dev/null || true
    if command -v pv >/dev/null 2>&1; then
      dd if="$SRC" bs=1M conv=noerror,sync | pv -s "$(blockdev --getsize64 "$SRC")" | gzip -1 > "$ARCH"
    else
      dd if="$SRC" bs=1M status=progress conv=noerror,sync | gzip -1 > "$ARCH"
    fi
    sync
  fi
else
  # Restore from archive to target device
  if tar -tzf "$ARCH" >/dev/null 2>&1; then
    # New-format per-partition archive
    TMPDIR=$(mktemp -d)
    cleanup_tmp() { [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"; }
    trap 'cleanup_tmp' EXIT INT TERM HUP
    tar -xzf "$ARCH" -C "$TMPDIR"
    # Recreate partition table
    if [ -f "$TMPDIR/partition_table.sfdisk" ]; then
      sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk"
      partprobe "$DST" || true
      sync
    fi
    # Map target partitions list
    mapfile -t TPARTS < <(lsblk -ln -o NAME,PKNAME "$DST" | awk '$2=="" {next} $2!="" {print $1}')
    # Restore per manifest order
    if [ -f "$TMPDIR/manifest.tsv" ]; then
      while IFS=$'\t' read -r PNAME FSTOOL TOOL; do
        # Resolve target dev by partition number suffix in PNAME
        # Extract numeric part index at end (e.g., sda3 -> 3, nvme0n1p2 -> 2)
        IDX=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
        TDEV=""
        if [ -n "$IDX" ]; then
          # Find ${DST}${suffix} pattern
          if [[ "$DST" =~ nvme[0-9]+n[0-9]+$ ]]; then
            CAND="${DST}p${IDX}"
          else
            CAND="${DST}${IDX}"
          fi
          if [ -b "$CAND" ]; then TDEV="$CAND"; fi
        fi
        [ -n "$TDEV" ] || { echo "WARN: could not map partition $PNAME to target; skipping"; continue; }
        BASE="$TMPDIR/part-${PNAME}"
        case "$TOOL" in
          partclone)
            if [ -f "${BASE}.pc.gz" ] && command -v partclone.extfs >/dev/null 2>&1; then
              gzip -dc "${BASE}.pc.gz" | partclone.extfs -r -o "$TDEV" -s -
            else
              echo "WARN: missing partclone image or tool for $PNAME"
            fi
            ;;
          ntfsclone)
            if [ -f "${BASE}.ntfs.gz" ] && command -v ntfsclone >/dev/null 2>&1; then
              gzip -dc "${BASE}.ntfs.gz" | ntfsclone --restore-image --overwrite "$TDEV" -
            else
              echo "WARN: missing ntfsclone image or tool for $PNAME"
            fi
            ;;
          dd)
            if [ -f "${BASE}.raw.gz" ]; then
              if command -v pv >/dev/null 2>&1; then
                gzip -dc "${BASE}.raw.gz" | pv | dd of="$TDEV" bs=1M conv=fsync status=none
              else
                gzip -dc "${BASE}.raw.gz" | dd of="$TDEV" bs=1M status=progress conv=fsync
              fi
            else
              echo "WARN: missing raw image for $PNAME"
            fi
            ;;
        esac
        sync
      done < "$TMPDIR/manifest.tsv"
    else
      echo "ERROR: manifest.tsv not found in archive"
    fi
    # Cleanup handled by trap
  else
    # Legacy full-disk raw archive
    if command -v pv >/dev/null 2>&1; then
      pv "$ARCH" | gzip -dc | dd of="$DST" bs=1M conv=fsync
    else
      gzip -dc "$ARCH" | dd of="$DST" bs=1M status=progress conv=fsync
    fi
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

## Source re-grow feature removed

echo "=== Done ==="
echo "Cloned $SRC to $DST. If the target is larger, you may later expand partitions/filesystems."

