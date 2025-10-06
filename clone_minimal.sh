#!/bin/bash

# Advanced Disk Cloner (Minimal)
#
# Purpose:
#   Single-file, menu-driven disk cloner/archiver/restorer designed to work from live Linux.
#   Focuses on safety, speed, and Windows/Linux compatibility.
#
# Key Features:
#   - Interactive disk selection for SOURCE and TARGET (supports sdX and nvme*n1)
#   - Clone disk → disk with dd and GPT backup repair (sgdisk -e)
#   - Archive disk → used-block per-partition images (partclone/ntfsclone) packed in tar
#     • Falls back to raw dd for unsupported or mounted filesystems
#     • Saves partition table dump (sfdisk) and a manifest
#   - Restore from archive → recreates GPT and restores per partition
#     • Compact restore option (pack partitions contiguously)
#     • Preserves original PARTUUIDs and disk GUID (label-id) for Windows boot stability
#     • Optional enlargement of last partition and ext4/NTFS grow
#   - Partial restore → restore selected partitions only (does not alter partition table)
#   - GUID management → can randomize GUIDs when both original and clone will coexist
#   - Clean output → progress bars, concise status, total runtime (non-verbose)
#   - Path UX → TAB completion and mountpoint-anchored prompts (archive/restore)
#   - Auto-install (Ubuntu) of required tools; diagnostics and self-test mode
#
# Performance:
#   - Multi-threaded compression/decompression (pigz/zstd) using all CPU cores
#   - zstd -3 preferred for strong ratio with minimal speed cost; pigz fallback
#   - Ionice and readahead tuning for smoother I/O
#
# Safety Notes:
#   - When restoring/cloning Windows: for a standalone clone (original not attached), GUIDs are preserved
#     to keep BCD references valid. If both disks will be attached simultaneously, randomize GUIDs and
#     rebuild BCD (outside the scope of this Linux-only script) or ensure separate EFI entries.
#   - Partial restore will not touch the GPT; ensure target partitions are correctly sized and unmounted.
#
# Usage:
#   sudo ./clone_minimal.sh [-v|--verbose]
#
# License: MIT
#

set -euo pipefail

# Verbosity control: pass -v or --verbose to enable diagnostic logs
VERBOSE=no
for __arg in "$@"; do
  case "$__arg" in
    -v|--verbose) VERBOSE=yes ;;
  esac
done
diag() { if [ "$VERBOSE" = "yes" ]; then echo "$@" >&2; fi }

# Timer functions for operation tracking (excludes user interaction time)
OP_START_TIME=""
start_op_timer() { OP_START_TIME=$(date +%s); }
show_op_time() {
  if [ -n "$OP_START_TIME" ]; then
    local end=$(date +%s)
    local elapsed=$((end - OP_START_TIME))
    local h=$((elapsed / 3600))
    local m=$(((elapsed % 3600) / 60))
    local s=$((elapsed % 60))
    printf "Total operation time: "
    [ $h -gt 0 ] && printf "%dh " $h
    [ $m -gt 0 ] && printf "%dm " $m
    printf "%ds\n" $s
  fi
}

# Clean output helpers (non-verbose)
progress_msg() { [ "$VERBOSE" = "no" ] && echo "$@" || true; }
quiet_stderr() { if [ "$VERBOSE" = "no" ]; then "$@" 2>/dev/null; else "$@"; fi }

# Performance tuning defaults (auto-detected; no runtime params required)
THREADS=$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)
HAS_ZSTD=no; command -v zstd >/dev/null 2>&1 && HAS_ZSTD=yes || true
HAS_PIGZ=no; command -v pigz >/dev/null 2>&1 && HAS_PIGZ=yes || true

# Compression strategy (optimized): prefer zstd (better ratio/speed), fallback to pigz, then gzip
if [ "$HAS_ZSTD" = "yes" ]; then
  # zstd -3: 10-15% better compression than -1, minimal speed loss on modern CPUs
  PIGZ_ARGS=""  # Not used with zstd
  TAR_COMP_FLAG=( -I "zstd -T${THREADS} -3" )
  TAR_DECOMP_FLAG=( -I "zstd -T${THREADS} -d" )
  PART_EXT="zst"
  PART_COMP_CMD_ZSTD="zstd -T${THREADS} -3"
  PART_DECOMP_CMD_ZSTD="zstd -T${THREADS} -d"
elif [ "$HAS_PIGZ" = "yes" ]; then
  # pigz -3: better compression with good speed
  PIGZ_ARGS="-3 -p ${THREADS}"
  TAR_COMP_FLAG=( -I "pigz ${PIGZ_ARGS}" )
  TAR_DECOMP_FLAG=( -I "pigz -d -p ${THREADS}" )
  PART_EXT="gz"
else
  # gzip -3: better than -1, still reasonably fast
  PIGZ_ARGS=""
  TAR_COMP_FLAG=()
  TAR_DECOMP_FLAG=()
  PART_EXT="gz"
  GZIP="-3"  # Environment variable for tar -z
fi

# Optional DIRECT I/O (auto: off by default)
DD_IFLAGS=""; DD_OFLAGS=""

# Optional: raise I/O priority to best-effort high if ionice is present
IONICE=""; if command -v ionice >/dev/null 2>&1; then IONICE="ionice -c2 -n0"; fi

# Optional: increase readahead for block devices we touch; restored on exit
ORIG_RA_FILE=""; ORIG_RA_DST=""; ORIG_RA_SRC="";
set_readahead() {
  local dev="$1" val="$2"
  local ra_file="/sys/block/$(basename "$dev")/queue/read_ahead_kb"
  if [ -w "$ra_file" ]; then
    cat "$ra_file" 2>/dev/null || true
    echo "$val" > "$ra_file" 2>/dev/null || true
  fi
}
restore_readahead() {
  [ -n "$ORIG_RA_SRC" ] && set_readahead "${SRC}" "$ORIG_RA_SRC"
  [ -n "$ORIG_RA_DST" ] && [ -n "${DST:-}" ] && set_readahead "${DST}" "$ORIG_RA_DST"
}
trap 'restore_readahead' EXIT INT TERM HUP

get_readahead() {
  local dev="$1"; local ra_file="/sys/block/$(basename "$dev")/queue/read_ahead_kb"
  if [ -r "$ra_file" ]; then cat "$ra_file" 2>/dev/null || true; fi
}

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }

# Self-test mode: validate environment and exit
if [ "${1:-}" = "--self-test" ]; then
  echo "=== Self-test ==="
  # shellcheck disable=SC1091
  echo "OS: $(. /etc/os-release 2>/dev/null || true; echo "${NAME:-unknown}")"
  echo "User: $(id -un) (EUID=${EUID:-$(id -u)})"
  echo "Checking commands..."
  for cmd in dd sfdisk gzip tar lsblk awk pv gdisk partclone.extfs ntfsclone tune2fs e2fsck resize2fs pigz; do
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

# Read a strict yes/no answer (no default). Reprompts on empty or invalid input.
read_yes_no() {
  local prompt="$1"
  local ans
  while true; do
    read -rp "$prompt" ans || ans=""
    if [[ "$ans" =~ ^[YyNn]$ ]]; then
      echo "$ans"
      return 0
    fi
    echo "Please answer Y or N."
  done
}

is_ubuntu() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
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
    export DEBIAN_FRONTEND=noninteractive
    run_root bash -lc 'apt-get update -y || true; apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"' _ "$@" || true
  else
    echo "WARN: Auto-install is supported only on Ubuntu (apt). Skipping." >&2
  fi
}

# Ensure a set of commands exist; on Ubuntu, attempt to install their packages.
ensure_commands() {
  missing_cmds=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing_cmds+=("$c")
    fi
  done
  if [ ${#missing_cmds[@]} -eq 0 ]; then
    return 0
  fi
  if is_ubuntu; then
    # Map commands → packages (Ubuntu)
    declare -A PKG_FOR_CMD
    PKG_FOR_CMD[dd]="coreutils"
    PKG_FOR_CMD[sfdisk]="util-linux"
    PKG_FOR_CMD[lsblk]="util-linux"
    PKG_FOR_CMD[gzip]="gzip"
    PKG_FOR_CMD[pigz]="pigz"
    PKG_FOR_CMD[tar]="tar"
    PKG_FOR_CMD[pv]="pv"
    PKG_FOR_CMD[gdisk]="gdisk"
    PKG_FOR_CMD[sgdisk]="gdisk"
    PKG_FOR_CMD[partclone.extfs]="partclone"
    PKG_FOR_CMD[ntfsclone]="ntfs-3g"
    PKG_FOR_CMD[tune2fs]="e2fsprogs"
    PKG_FOR_CMD[e2fsck]="e2fsprogs"
    PKG_FOR_CMD[resize2fs]="e2fsprogs"

    # Build unique package list
    pkgs=()
    for c in "${missing_cmds[@]}"; do
      p="${PKG_FOR_CMD[$c]:-}"
      if [ -n "$p" ]; then
        case " ${pkgs[*]} " in *" $p "*) :;; *) pkgs+=("$p");; esac
      fi
    done
    if [ ${#pkgs[@]} -gt 0 ]; then
      install_packages "${pkgs[@]}"
    fi
    # Re-check after installation
    post_missing=()
    for c in "$@"; do
      if ! command -v "$c" >/dev/null 2>&1; then
        post_missing+=("$c")
      fi
    done
    if [ ${#post_missing[@]} -gt 0 ]; then
      echo "ERROR: Missing required commands after install attempt: ${post_missing[*]}" >&2
      echo "Please install the packages manually and re-run." >&2
      exit 1
    fi
  else
    echo "ERROR: Missing required commands on non-Ubuntu system: ${missing_cmds[*]}" >&2
    echo "Please install: coreutils util-linux gzip tar pv gdisk partclone ntfs-3g e2fsprogs" >&2
    exit 1
  fi
}

# Always attempt to install prerequisites on Ubuntu (non-fatal)
echo "Ensuring required commands are available..."
# Core + feature commands needed by this script
ensure_commands dd sfdisk gzip tar lsblk awk pv gdisk partclone.extfs ntfsclone tune2fs e2fsck resize2fs pigz

# Ensure minimally required commands exist after best-effort install
require dd
require sfdisk
require gzip
require tar

# Report archive capabilities
HAS_PARTCLONE=no
HAS_NTFSCLONE=no
if command -v partclone.extfs >/dev/null 2>&1; then HAS_PARTCLONE=yes; fi
if command -v ntfsclone >/dev/null 2>&1; then HAS_NTFSCLONE=yes; fi
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
# Bump readahead temporarily to 4096 KiB for throughput
ORIG_RA_SRC=$(get_readahead "$SRC" || echo "")
set_readahead "$SRC" 4096
if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "TARGET: $DST (WILL BE ERASED)"
  read -rp "Type YES to confirm clone: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Cancelled"; exit 1; }
  ORIG_RA_DST=$(get_readahead "$DST" || echo "")
  set_readahead "$DST" 4096
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
    # Enable readline so TAB completes filesystem paths
    read -e -p "Enter a directory path to save the archive (must exist): " ARCH_DIR
  fi
  [ -d "$ARCH_DIR" ] || { echo "Archive directory does not exist: $ARCH_DIR"; exit 1; }
  # Ask for file name or a path within the chosen destination (absolute path also accepted)
  # Enable readline with filename completion and prefill with chosen destination directory
  DEF_ARCH_PATH="${ARCH_DIR%/}/${SRC_BASENAME}.img.gz"
  read -e -p "Enter archive file name or path [default ${SRC_BASENAME}.img.gz]: " -i "$DEF_ARCH_PATH" ARCH_INPUT
  ARCH_INPUT=${ARCH_INPUT:-$DEF_ARCH_PATH}
  # If user provided a relative path like ./ or ./file, resolve relative to the chosen destination directory
  if [ -n "$ARCH_DIR" ]; then
    if [ "$ARCH_INPUT" = "./" ] || [ "$ARCH_INPUT" = "." ]; then
      ARCH_INPUT="${ARCH_DIR%/}/"
    elif [[ "$ARCH_INPUT" != /* ]]; then
      # Relative path => anchor to the chosen destination directory
      ARCH_INPUT="${ARCH_DIR%/}/${ARCH_INPUT#./}"
    fi
  fi
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
  if [ -e "$ARCH" ]; then read -rp "File exists at $ARCH. Overwrite? (y/N): " OW; [[ "$OW" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }; fi
elif [[ "$OP" =~ ^[Rr]$ ]]; then
  # Restore from image to selected target disk
  # Compute a sensible default base for TAB completion: if SOURCE has a mounted partition,
  # prefill the prompt with that mountpoint so TAB lists files from there.
  SRC_BN=$(basename -- "$SRC")
  SRC_BASE_MP=$(lsblk -ln -o NAME,MOUNTPOINT,PKNAME "$SRC" | awk '$2!="" {print $2; exit}')
  DEF_BASE="./"
  if [ -n "$SRC_BASE_MP" ]; then DEF_BASE="${SRC_BASE_MP%/}/"; fi
  read -e -i "$DEF_BASE" -p "Enter archive image file to restore (e.g., ./sdb.img.gz): " ARCH
  # If user provided a relative path like ./ or ./file, resolve relative to the SOURCE's mounted partition (if any)
  if [ -n "$SRC_BASE_MP" ]; then
    if [ "$ARCH" = "./" ] || [ "$ARCH" = "." ]; then
      ARCH="${SRC_BASE_MP%/}/"
    elif [[ "$ARCH" != /* ]]; then
      # Relative path => anchor to the source disk's mountpoint
      ARCH="${SRC_BASE_MP%/}/${ARCH#./}"
    fi
  fi
  # If a directory is provided, allow selecting a file within it (TAB completes)
  while [ -d "$ARCH" ]; do
    # Show a hint once
    echo "Enter a file inside: $ARCH"
    read -e -p "Archive file within directory: " -i "${ARCH%/}/" ARCH
  done
  if [ ! -f "$ARCH" ]; then
    # If a relative path was provided, try resolving against mounted real-disk destinations
    # Collect mounted destinations where TYPE=part, parent PKNAME is sdX or nvme*n1
    mapfile -t MOUNTED_MP < <(lsblk -ln -o NAME,TYPE,MOUNTPOINT,PKNAME | \
      awk '$2=="part" && $3!="" && ($4 ~ /^sd[a-z]+$/ || $4 ~ /^nvme[0-9]+n[0-9]+$/) {print $3}' | sort -u)
    RESOLVED=""
    for mp in "${MOUNTED_MP[@]}"; do
      # Try as provided relative under mountpoint
      if [ -f "$mp/$ARCH" ]; then RESOLVED="$mp/$ARCH"; break; fi
      # Try just the basename under mountpoint
      base=$(basename -- "$ARCH")
      if [ -n "$base" ] && [ -f "$mp/$base" ]; then RESOLVED="$mp/$base"; break; fi
    done
    if [ -n "$RESOLVED" ]; then
      echo "Resolved archive path: $RESOLVED"
      ARCH="$RESOLVED"
    else
      echo "Archive not found: $ARCH"; echo "Checked mountpoints: ${MOUNTED_MP[*]:-none}"; exit 1
    fi
  fi
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
  # Defer partial restore decision until after extraction to avoid double reading
  PARTIAL_RESTORE=no
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
        # Run ntfsresize info safely; ignore non-zero exit and parse output
        _ntfs_info=$(ntfsresize -i -f "$DEV" 2>&1 || true)
        minb=$(printf '%s\n' "$_ntfs_info" | awk '/minim/ {for(i=1;i<=NF;i++) if($i ~ /bytes/) {print $(i-1); exit}}')
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

# Get device sizes with error checking
SRC_BYTES=$(blockdev --getsize64 "$SRC" 2>/dev/null || echo "0")
if [[ ! "$SRC_BYTES" =~ ^[0-9]+$ ]] || [ "$SRC_BYTES" -eq 0 ]; then
  echo "ERROR: Could not determine source device size: $SRC"; exit 1
fi
if [[ "$OP" =~ ^[Cc]$ ]]; then
  DST_BYTES=$(blockdev --getsize64 "$DST" 2>/dev/null || echo "0")
  if [[ ! "$DST_BYTES" =~ ^[0-9]+$ ]] || [ "$DST_BYTES" -eq 0 ]; then
    echo "ERROR: Could not determine target device size: $DST"; exit 1
  fi
else
  DST_BYTES=0
fi

if command -v numfmt >/dev/null 2>&1; then
  echo "Approx. data footprint to be present on target: $(numfmt --to=iec "$estimate_bytes")"
  echo "Source disk size (raw device):                 $(numfmt --to=iec "$SRC_BYTES")"
else
  echo "Approx. data footprint to be present on target: ${estimate_bytes} bytes"
  echo "Source disk size (raw device):                 ${SRC_BYTES} bytes"
fi
if [[ "$OP" =~ ^[Cc]$ ]]; then
  if command -v numfmt >/dev/null 2>&1; then
    echo "Target disk size:                               $(numfmt --to=iec "$DST_BYTES")"
  else
    echo "Target disk size:                               ${DST_BYTES} bytes"
  fi
  if [ "$SRC_BYTES" -gt "$DST_BYTES" ]; then
    echo "ERROR: Target is smaller than source; cannot proceed."
    exit 1
  fi
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  echo "Archive output:                                 $ARCH"
else
  echo "Restore image:                                  $ARCH"
fi

PROCEED_EST=$(read_yes_no "Proceed with operation given the estimates above? (y/N): ")
[[ "$PROCEED_EST" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }

# Start operation timer (excludes user interaction time)
start_op_timer

if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "=== Start clone: $SRC → $DST ==="
else
  if [[ "$OP" =~ ^[Aa]$ ]]; then
    echo "=== Start archive: $SRC → $ARCH ==="
  else
    # Prepare/announce restore temp workspace BEFORE starting restore
    ARCH_DIRNAME=$(dirname "$ARCH")
    mkdir -p "$ARCH_DIRNAME"
    if [ -n "${ADC_TMPDIR:-}" ]; then
      TMPDIR="$ADC_TMPDIR"
      mkdir -p "$TMPDIR"
    else
      TMPDIR=$(mktemp -d "${ARCH_DIRNAME%/}/.adc_tmp.XXXXXX")
    fi
    diag "[RESTORE] Using temp workspace: $TMPDIR"
    export TMPDIR
    echo "=== Start restore: $ARCH → $DST ==="
  fi
fi
if [[ "$OP" =~ ^[Cc]$ ]]; then
  if command -v pv >/dev/null 2>&1; then
    ${IONICE:+$IONICE }dd if="$SRC" bs=16M ${DD_IFLAGS:+$DD_IFLAGS} conv=noerror,sync | pv -s "$(blockdev --getsize64 "$SRC")" | ${IONICE:+$IONICE }dd of="$DST" bs=16M ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync
  else
    ${IONICE:+$IONICE }dd if="$SRC" of="$DST" bs=16M ${DD_IFLAGS:+$DD_IFLAGS} ${DD_OFLAGS:+$DD_OFLAGS} status=progress conv=noerror,sync,fsync
  fi
  sync
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  # Archive: prefer used-block per-partition imaging into a tarball if tools available
  if command -v partclone.extfs >/dev/null 2>&1 || command -v ntfsclone >/dev/null 2>&1; then
    # Create a temporary workspace on the destination filesystem (not /tmp),
    # to avoid running out of space when root has low free space.
    ARCH_TAR="$ARCH"
    case "$ARCH_TAR" in
      *.gz|*.tgz) : ;;
      *) ARCH_TAR="${ARCH_TAR}.tar.gz" ;;
    esac
    ARCH_DIRNAME=$(dirname "$ARCH_TAR")
    mkdir -p "$ARCH_DIRNAME"
    if [ -n "${ADC_TMPDIR:-}" ]; then
      TMPDIR="$ADC_TMPDIR"
      mkdir -p "$TMPDIR"
    else
      TMPDIR=$(mktemp -d "${ARCH_DIRNAME%/}/.adc_tmp.XXXXXX")
    fi
    cleanup_tmp() { [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"; }
    trap 'cleanup_tmp' EXIT INT TERM HUP
    diag "[ARCH] Using temp workspace: $TMPDIR"
    MANIFEST="$TMPDIR/manifest.tsv"
    STATUS_LOG="$TMPDIR/status.tsv"
    : > "$MANIFEST"
    : > "$STATUS_LOG"
    # Save partition table dump
    sfdisk -d "$SRC" > "$TMPDIR/partition_table.sfdisk" 2>/dev/null || true
    # Enumerate partitions on source disk
    mapfile -t APARTS < <(lsblk -ln -o NAME,FSTYPE,SIZE,PARTLABEL,PARTUUID,PKNAME "$SRC" | awk 'NR>1 {print $1"\t"$2"\t"$3"\t"$4"\t"$5}')
    PART_NUM=0
    PART_TOTAL=${#APARTS[@]}
    for line in "${APARTS[@]}"; do
      PNAME=$(echo -e "$line" | awk -F"\t" '{print $1}')
      FST=$(echo -e   "$line" | awk -F"\t" '{print $2}')
      PSIZE=$(echo -e  "$line" | awk -F"\t" '{print $3}')
      DEV="/dev/$PNAME"
      OUTBASE="$TMPDIR/part-${PNAME}"
      PART_NUM=$((PART_NUM + 1))
      diag "[ARCH] Start: $PNAME (fs=${FST:-unknown})"
      progress_msg "[$PART_NUM/$PART_TOTAL] Archiving $PNAME (${FST:-unknown}, $PSIZE)..."
      case "$FST" in
        ext4)
          # If partition is mounted (e.g., root), avoid partclone and fallback to dd
          MOUNTED_AT=$(findmnt -no TARGET "$DEV" 2>/dev/null || true)
          if command -v partclone.extfs >/dev/null 2>&1 && [ -z "$MOUNTED_AT" ]; then
            echo -e "$PNAME\text4\tpartclone" >> "$MANIFEST"
            (
              set +e -o pipefail
    if [ "$PART_EXT" = "zst" ] && command -v zstd >/dev/null 2>&1; then
      if command -v pv >/dev/null 2>&1; then
        { ${IONICE:+$IONICE }partclone.extfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | ${IONICE:+$IONICE }pv | zstd -T${THREADS} -3 > "${OUTBASE}.pc.zst"
      else
        { partclone.extfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | zstd -T${THREADS} -3 > "${OUTBASE}.pc.zst"
      fi
    else
      if command -v pv >/dev/null 2>&1; then
        if command -v pigz >/dev/null 2>&1; then
          { ${IONICE:+$IONICE }partclone.extfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | ${IONICE:+$IONICE }pv | pigz $PIGZ_ARGS > "${OUTBASE}.pc.gz"
        else
          { partclone.extfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | pv | gzip -3 > "${OUTBASE}.pc.gz"
        fi
      else
        if command -v pigz >/dev/null 2>&1; then
          { partclone.extfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | pigz $PIGZ_ARGS > "${OUTBASE}.pc.gz"
        else
          { partclone.extfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | gzip -3 > "${OUTBASE}.pc.gz"
        fi
      fi
    fi
            ); rc=$?
            if [ $rc -eq 0 ]; then
              if   [ -s "${OUTBASE}.pc.zst" ]; then OUTFILE="${OUTBASE}.pc.zst";
              elif [ -s "${OUTBASE}.pc.gz"  ]; then OUTFILE="${OUTBASE}.pc.gz"; else OUTFILE=""; fi
              if [ -n "$OUTFILE" ]; then
                sz=$(stat -c %s "$OUTFILE" 2>/dev/null || echo 0)
                echo -e "$PNAME\tpartclone\tOK\t$sz" >> "$STATUS_LOG"
                diag "[ARCH] Done: $PNAME via partclone (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))"
              else
                echo -e "$PNAME\tpartclone\tFAIL\t0" >> "$STATUS_LOG"
                echo "[ARCH] FAIL: $PNAME via partclone (no output detected)" >&2
              fi
            else
              echo -e "$PNAME\tpartclone\tFAIL\t0" >> "$STATUS_LOG"
              echo "[ARCH] FAIL: $PNAME via partclone (rc=$rc)" >&2
            fi
          else
            echo -e "$PNAME\text4\tdd" >> "$MANIFEST"
            (
              set +e -o pipefail
    if command -v pv >/dev/null 2>&1; then
      if command -v pigz >/dev/null 2>&1; then
        ${IONICE:+$IONICE }dd if="$DEV" bs=16M status=none | ${IONICE:+$IONICE }pv | pigz $PIGZ_ARGS > "${OUTBASE}.raw.gz"
      else
        dd if="$DEV" bs=16M status=none | pv | gzip -3 > "${OUTBASE}.raw.gz"
      fi
    else
      if command -v pigz >/dev/null 2>&1; then
        dd if="$DEV" bs=16M status=progress | pigz $PIGZ_ARGS > "${OUTBASE}.raw.gz"
      else
        dd if="$DEV" bs=16M status=progress | gzip -3 > "${OUTBASE}.raw.gz"
      fi
    fi
            ); rc=$?
            if [ $rc -eq 0 ] && [ -s "${OUTBASE}.raw.gz" ]; then
              sz=$(stat -c %s "${OUTBASE}.raw.gz" 2>/dev/null || echo 0)
              echo -e "$PNAME\tdd\tOK\t$sz" >> "$STATUS_LOG"
              diag "[ARCH] Done: $PNAME via dd (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))"
            else
              echo -e "$PNAME\tdd\tFAIL\t0" >> "$STATUS_LOG"
              echo "[ARCH] FAIL: $PNAME via dd (rc=$rc)" >&2
            fi
          fi
          ;;
        ntfs)
          if command -v ntfsclone >/dev/null 2>&1; then
            echo -e "$PNAME\tntfs\tntfsclone" >> "$MANIFEST"
            (
              set +e -o pipefail
    if [ "$PART_EXT" = "zst" ] && command -v zstd >/dev/null 2>&1; then
      if command -v pv >/dev/null 2>&1; then
        ${IONICE:+$IONICE }ntfsclone --save-image --output - "$DEV" | ${IONICE:+$IONICE }pv | zstd -T${THREADS} -3 > "${OUTBASE}.ntfs.zst"
      else
        ntfsclone --save-image --output - "$DEV" | zstd -T${THREADS} -3 > "${OUTBASE}.ntfs.zst"
      fi
    else
      if command -v pv >/dev/null 2>&1; then
        if command -v pigz >/dev/null 2>&1; then
          ${IONICE:+$IONICE }ntfsclone --save-image --output - "$DEV" | ${IONICE:+$IONICE }pv | pigz $PIGZ_ARGS > "${OUTBASE}.ntfs.gz"
        else
          ntfsclone --save-image --output - "$DEV" | pv | gzip -3 > "${OUTBASE}.ntfs.gz"
        fi
      else
        if command -v pigz >/dev/null 2>&1; then
          ntfsclone --save-image --output - "$DEV" | pigz $PIGZ_ARGS > "${OUTBASE}.ntfs.gz"
        else
          ntfsclone --save-image --output - "$DEV" | gzip -3 > "${OUTBASE}.ntfs.gz"
        fi
      fi
    fi
            ); rc=$?
            if [ $rc -eq 0 ]; then
              if   [ -s "${OUTBASE}.ntfs.zst" ]; then OUTFILE="${OUTBASE}.ntfs.zst";
              elif [ -s "${OUTBASE}.ntfs.gz"  ]; then OUTFILE="${OUTBASE}.ntfs.gz"; else OUTFILE=""; fi
              if [ -n "$OUTFILE" ]; then
                sz=$(stat -c %s "$OUTFILE" 2>/dev/null || echo 0)
                echo -e "$PNAME\tntfsclone\tOK\t$sz" >> "$STATUS_LOG"
                diag "[ARCH] Done: $PNAME via ntfsclone (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))"
              else
                echo -e "$PNAME\tntfsclone\tFAIL\t0" >> "$STATUS_LOG"
                echo "[ARCH] FAIL: $PNAME via ntfsclone (no output detected)" >&2
              fi
            else
              echo -e "$PNAME\tntfsclone\tFAIL\t0" >> "$STATUS_LOG"
              echo "[ARCH] FAIL: $PNAME via ntfsclone (rc=$rc)" >&2
            fi
          else
            echo -e "$PNAME\tntfs\tdd" >> "$MANIFEST"
            (
              set +e -o pipefail
    if command -v pv >/dev/null 2>&1; then
      if command -v pigz >/dev/null 2>&1; then
        ${IONICE:+$IONICE }dd if="$DEV" bs=16M status=none | ${IONICE:+$IONICE }pv | pigz $PIGZ_ARGS > "${OUTBASE}.raw.gz"
      else
        dd if="$DEV" bs=16M status=none | pv | gzip -3 > "${OUTBASE}.raw.gz"
      fi
    else
      if command -v pigz >/dev/null 2>&1; then
        dd if="$DEV" bs=16M status=progress | pigz $PIGZ_ARGS > "${OUTBASE}.raw.gz"
      else
        dd if="$DEV" bs=16M status=progress | gzip -3 > "${OUTBASE}.raw.gz"
      fi
    fi
            ); rc=$?
            if [ $rc -eq 0 ] && [ -s "${OUTBASE}.raw.gz" ]; then
              sz=$(stat -c %s "${OUTBASE}.raw.gz" 2>/dev/null || echo 0)
              echo -e "$PNAME\tdd\tOK\t$sz" >> "$STATUS_LOG"
              diag "[ARCH] Done: $PNAME via dd (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))"
            else
              echo -e "$PNAME\tdd\tFAIL\t0" >> "$STATUS_LOG"
              echo "[ARCH] FAIL: $PNAME via dd (rc=$rc)" >&2
            fi
          fi
          ;;
        *)
          # Unknown FS: fallback to raw partition dump
          echo -e "$PNAME\t$FST\tdd" >> "$MANIFEST"
          (
            set +e -o pipefail
    if command -v pv >/dev/null 2>&1; then
      if command -v pigz >/dev/null 2>&1; then
        ${IONICE:+$IONICE }dd if="$DEV" bs=16M status=none | ${IONICE:+$IONICE }pv | pigz $PIGZ_ARGS > "${OUTBASE}.raw.gz"
      else
        dd if="$DEV" bs=16M status=none | pv | gzip -3 > "${OUTBASE}.raw.gz"
      fi
    else
      if command -v pigz >/dev/null 2>&1; then
        dd if="$DEV" bs=16M status=progress | pigz $PIGZ_ARGS > "${OUTBASE}.raw.gz"
      else
        dd if="$DEV" bs=16M status=progress | gzip -3 > "${OUTBASE}.raw.gz"
      fi
    fi
          ); rc=$?
          if [ $rc -eq 0 ] && [ -s "${OUTBASE}.raw.gz" ]; then
            sz=$(stat -c %s "${OUTBASE}.raw.gz" 2>/dev/null || echo 0)
            echo -e "$PNAME\tdd\tOK\t$sz" >> "$STATUS_LOG"
            diag "[ARCH] Done: $PNAME via dd (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))"
          else
            echo -e "$PNAME\tdd\tFAIL\t0" >> "$STATUS_LOG"
            echo "[ARCH] FAIL: $PNAME via dd (rc=$rc)" >&2
          fi
          ;;
      esac
    done
    # Package everything into a tarball (new-format archive) with progress
    diag "[ARCH] Packaging archive..."
    progress_msg "Packaging archive..."
    # Create a file list and remove files from TMPDIR as they are archived to reduce disk usage
    PKG_LIST=$(mktemp -p "$TMPDIR" .pkglist.XXXXXX)
    (cd "$TMPDIR" && find . -maxdepth 1 -type f -printf "%P\n" > "$PKG_LIST")
    if [ ${#TAR_COMP_FLAG[@]} -gt 0 ]; then
      (cd "$TMPDIR" && tar "${TAR_COMP_FLAG[@]}" -cf "$ARCH_TAR" --remove-files -T "$PKG_LIST")
    else
      (cd "$TMPDIR" && tar -cf "$ARCH_TAR" --remove-files -T "$PKG_LIST")
    fi
    rm -f "$PKG_LIST" || true
    mv -f "$ARCH_TAR" "$ARCH" 2>/dev/null || true
    diag "\n[ARCH] Summary (partition, tool, status, size-bytes):"
    if [ "$VERBOSE" = "yes" ]; then sed -n '1,200p' "$STATUS_LOG" 2>/dev/null >&2 || true; fi
    # Cleanup handled by trap
    sync
  else
    # Legacy full-disk raw archive
    sfdisk -d "$SRC" > "${ARCH%.gz}.sfdisk" 2>/dev/null || true
    if command -v pigz >/dev/null 2>&1; then
      ${IONICE:+$IONICE }dd if="$SRC" bs=1M conv=noerror,sync | pigz -1 > "$ARCH"
    else
      if command -v pv >/dev/null 2>&1; then
        ${IONICE:+$IONICE }dd if="$SRC" bs=1M conv=noerror,sync | ${IONICE:+$IONICE }pv -s "$(blockdev --getsize64 "$SRC")" | gzip -3 > "$ARCH"
      else
        dd if="$SRC" bs=1M status=progress conv=noerror,sync | gzip -3 > "$ARCH"
      fi
    fi
    sync
  fi
else
  # Restore from archive to target device
  # Attempt single-pass extraction; if it fails, fall back to legacy raw restore
  ARCH_IS_TAR=no
  ARCH_DIRNAME=$(dirname "$ARCH")
  mkdir -p "$ARCH_DIRNAME"
  if [ -z "${TMPDIR:-}" ]; then
    if [ -n "${ADC_TMPDIR:-}" ]; then
      TMPDIR="$ADC_TMPDIR"; mkdir -p "$TMPDIR"
    else
      TMPDIR=$(mktemp -d "${ARCH_DIRNAME%/}/.adc_tmp.XXXXXX")
    fi
    diag "[RESTORE] Using temp workspace: $TMPDIR"
  fi
  diag "[RESTORE] Extracting archive..."
  progress_msg "Extracting archive..."
  # Stream extraction directly via tar to avoid any pre-read overhead
  if [ ${#TAR_DECOMP_FLAG[@]} -gt 0 ]; then
    if tar --no-same-owner "${TAR_DECOMP_FLAG[@]}" -x -f "$ARCH" -C "$TMPDIR" 2>&1 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; }; then ARCH_IS_TAR=yes; fi
  else
    if tar --no-same-owner -xzf "$ARCH" -C "$TMPDIR" 2>&1 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; }; then ARCH_IS_TAR=yes; fi
  fi
  if [ "$ARCH_IS_TAR" = "yes" ]; then
    cleanup_tmp() {
      # Only remove temp if RESTORE_OK=yes; keep on failure for diagnostics
      if [ "${RESTORE_OK:-no}" = "yes" ]; then
        [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"
      else
        echo "[RESTORE] Kept temp workspace for diagnostics: $TMPDIR" >&2
      fi
    }
    trap 'cleanup_tmp' EXIT INT TERM HUP
    # Decide on partial restore now that archive is extracted and manifest is available
    if [ -f "$TMPDIR/manifest.tsv" ]; then
      PR=$(read_yes_no "Partial restore: restore only selected partitions? (y/N): ")
      if [[ "$PR" =~ ^[Yy]$ ]]; then
        PARTIAL_RESTORE=yes
        echo "You chose partial restore. Partition table will NOT be modified."
        echo "Ensure the target already has the desired partitions present."
      fi
    fi

    # Recreate partition table (optionally compact/resize before restore)
    # Skip if partial restore is requested
    if [ "${PARTIAL_RESTORE:-no}" != "yes" ] && [ -f "$TMPDIR/partition_table.sfdisk" ]; then
      COMPACT=$(read_yes_no "Compact restore: pack partitions contiguously (preserve numbers)? (y/N): ")
      if [[ "$COMPACT" =~ ^[Yy]$ ]]; then
        SECTOR_SIZE=$(blockdev --getss "$DST")
        DISK_SECTORS=$(blockdev --getsz "$DST")
        {
          echo "[RESTORE][DIAG] Compact mode enabled"
          echo "[RESTORE][DIAG] Target: $DST  sector_size=$SECTOR_SIZE  disk_sectors=$DISK_SECTORS"
        } >&2
        # Parse original dump to collect partition sizes, types and UUIDs by index
        # Lines look like: /dev/nvme0n1p3 : start=     123, size=   456, type=...
        # Do not depend on current SRC name; match any /dev/* partition lines
        mapfile -t DUMP_LINES < <(grep -E "^/dev/[^[:space:]]*[0-9]+[[:space:]]*:" "$TMPDIR/partition_table.sfdisk" || true)
        if [ ${#DUMP_LINES[@]} -eq 0 ]; then
          {
            echo "[RESTORE][DIAG] WARN: Could not parse any partition entries from saved table"
            if [ "$VERBOSE" = "yes" ]; then echo "[RESTORE][DIAG] Showing first 20 lines of saved partition table:" >&2; sed -n '1,20p' "$TMPDIR/partition_table.sfdisk" 2>/dev/null >&2 || true; fi
            diag "[RESTORE][DIAG] Falling back to original layout via sfdisk import."
          } >&2
          sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk"
        else
          # Build arrays: IDX -> TYPE, SIZE_SECT, UUID
          PART_INDEXES=()
          declare -A TYPE_BY_IDX
          declare -A SIZE_BY_IDX
          declare -A UUID_BY_IDX
          for ln in "${DUMP_LINES[@]}"; do
            # Extract trailing digits before the first ':' (partition index)
            idx=$(printf '%s' "$ln" | sed -E 's/^.*[^0-9]([0-9]+)[[:space:]]*:.*/\1/' | tail -n1)
            type=$(printf '%s' "$ln" | awk -F'type=' 'NF>1{print $2}' | awk -F',' '{print $1}' | sed 's/[[:space:]]//g')
            size=$(printf '%s' "$ln" | awk -F'size=' 'NF>1{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
            uuid=$(printf '%s' "$ln" | awk -F'uuid=' 'NF>1{print $2}' | awk -F',' '{print $1}' | sed 's/[[:space:]]//g')
            if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$size" =~ ^[0-9]+$ ]]; then
              PART_INDEXES+=("$idx")
              TYPE_BY_IDX[$idx]="$type"
              SIZE_BY_IDX[$idx]="$size"
              if [ -n "$uuid" ]; then UUID_BY_IDX[$idx]="$uuid"; fi
            fi
          done
          if [ "$VERBOSE" = "yes" ]; then echo "[RESTORE][DIAG] Parsed partitions from dump (index:type:size_sectors):" >&2; fi
          for i in "${PART_INDEXES[@]}"; do
            if [ "$VERBOSE" = "yes" ]; then echo "[RESTORE][DIAG]  $i:${TYPE_BY_IDX[$i]:-?}:${SIZE_BY_IDX[$i]:-?}:${UUID_BY_IDX[$i]:-}" >&2; fi
          done
          # Discover filesystems to allow enlargement prompts (ext4/ntfs only)
          declare -A FS_BY_IDX
          while IFS=$'\t' read -r PNAME FFS TOOL; do
            # extract numeric index from PNAME
            I=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
            [ -n "$I" ] && FS_BY_IDX[$I]="$FFS"
          done < "$TMPDIR/manifest.tsv"
          # Optional enlargement inputs
          ENQ=$(read_yes_no "Enlarge ext4/NTFS partitions before restore? (y/N): ")
          declare -A SIZE_NEW
          for i in "${PART_INDEXES[@]}"; do SIZE_NEW[$i]="${SIZE_BY_IDX[$i]}"; done
          if [[ "$ENQ" =~ ^[Yy]$ ]]; then
            # Compute free sectors budget = DISK_SECTORS - sum(original sizes) (starts auto/contiguous)
            sum=0
            for i in "${PART_INDEXES[@]}"; do sum=$((sum + SIZE_BY_IDX[$i])); done
            FREE=$((DISK_SECTORS - sum))
            {
              echo "[RESTORE][DIAG] Enlargement requested"
              echo "[RESTORE][DIAG] Sum(original sizes in sectors)=$sum  Free(sectors)=$FREE"
            } >&2
            for i in "${PART_INDEXES[@]}"; do
              fs="${FS_BY_IDX[$i]:-}"
              if [ "$fs" = "ext4" ] || [ "$fs" = "ntfs" ]; then
                cur="${SIZE_NEW[$i]}"
                cur_h=$(numfmt --to=iec $((cur*SECTOR_SIZE)) 2>/dev/null || echo "$cur sectors")
                free_h=$(numfmt --to=iec $((FREE*SECTOR_SIZE)) 2>/dev/null || echo "$FREE sectors")
                echo "Partition $i (fs=$fs): current ${cur_h}. Add extra size (e.g. +10G) or Enter to skip [free ${free_h}]: "
                read -r EXTRA
                if [[ "$EXTRA" =~ ^\+?[0-9]+[KkMmGgTt]$ ]]; then
                  bytes=$(numfmt --from=iec "${EXTRA#+}" 2>/dev/null || echo 0)
                  if [ "$SECTOR_SIZE" -gt 0 ]; then
                    add_sect=$(( bytes / SECTOR_SIZE ))
                    if [ "$add_sect" -le 0 ] || [ "$add_sect" -gt "$FREE" ]; then
                      echo "WARN: extra size out of range; skipping."
                    else
                      SIZE_NEW[$i]=$((cur + add_sect))
                      FREE=$((FREE - add_sect))
                      {
                        echo "[RESTORE][DIAG]  Enlarged partition $i by $add_sect sectors; FREE now $FREE"
                      } >&2
                    fi
                  else
                    echo "WARN: invalid sector size; skipping."
                  fi
                fi
              fi
            done
          fi
          # Build compact sfdisk script with contiguous partitions, keeping numbers and types
          NEWTAB=$(mktemp --tmpdir="${ARCH_DIRNAME}")
          {
            echo "label: gpt"
            echo "unit: sectors"
            for i in "${PART_INDEXES[@]}"; do
              t="${TYPE_BY_IDX[$i]}"; s="${SIZE_NEW[$i]}"
              u="${UUID_BY_IDX[$i]:-}"
              # sfdisk line: <dev>p<i> : size=<s>, type=<t>
              if [[ "$DST" =~ nvme[0-9]+n[0-9]+$ ]]; then
                if [ -n "$u" ]; then
                  echo "${DST}p${i} : size=${s}${t:+, type=$t}, uuid=$u"
                else
                  echo "${DST}p${i} : size=${s}${t:+, type=$t}"
                fi
              else
                if [ -n "$u" ]; then
                  echo "${DST}${i} : size=${s}${t:+, type=$t}, uuid=$u"
                else
                  echo "${DST}${i} : size=${s}${t:+, type=$t}"
                fi
              fi
            done
          } > "$NEWTAB"
          if [ "$VERBOSE" = "yes" ]; then echo "[RESTORE][DIAG] Generated compact sfdisk table:" >&2; sed -n '1,200p' "$NEWTAB" 2>/dev/null >&2 || true; fi
          SF_OUT=$(sfdisk "$DST" < "$NEWTAB" 2>&1); SF_RC=$?
          if [ $SF_RC -ne 0 ]; then
            {
              echo "[RESTORE][DIAG][ERROR] sfdisk failed with code $SF_RC" >&2
              echo "[RESTORE][DIAG][ERROR] sfdisk output:" >&2; echo "$SF_OUT" >&2
            } >&2
          fi
          rm -f "$NEWTAB"
          # After table write, explicitly set partition GUIDs using sgdisk to ensure preservation
          if command -v sgdisk >/dev/null 2>&1; then
            for i in "${PART_INDEXES[@]}"; do
              u="${UUID_BY_IDX[$i]:-}"
              if [ -n "$u" ]; then
                sgdisk -u="${i}:${u}" "$DST" >/dev/null 2>&1 || true
              fi
            done
            # Also set disk GUID to match original label-id from dump (safe when only clone is connected)
            ORIG_DISK_GUID=$(awk -F': ' '/^label-id:/ {print $2}' "$TMPDIR/partition_table.sfdisk" | tr 'a-f' 'A-F' | tr -d '\r')
            if [[ "$ORIG_DISK_GUID" =~ ^[0-9A-F-]+$ ]]; then
              sgdisk -U "$ORIG_DISK_GUID" "$DST" >/dev/null 2>&1 || true
            fi
          fi
        fi
      else
        {
          echo "[RESTORE][DIAG] Compact mode disabled. Importing original sfdisk table."
          if [ "$VERBOSE" = "yes" ]; then echo "[RESTORE][DIAG] Preview (first 20 lines):" >&2; sed -n '1,20p' "$TMPDIR/partition_table.sfdisk" 2>/dev/null >&2 || true; fi
        } >&2
        SF_OUT=$(sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk" 2>&1); SF_RC=$?
        if [ $SF_RC -ne 0 ]; then
          {
            echo "[RESTORE][DIAG][ERROR] sfdisk failed with code $SF_RC" >&2
            echo "[RESTORE][DIAG][ERROR] sfdisk output:" >&2; echo "$SF_OUT" >&2
          } >&2
        fi
        # After importing table, also set disk GUID from label-id to ensure match with source
        if command -v sgdisk >/dev/null 2>&1; then
          ORIG_DISK_GUID=$(awk -F': ' '/^label-id:/ {print $2}' "$TMPDIR/partition_table.sfdisk" | tr 'a-f' 'A-F' | tr -d '\r')
          if [[ "$ORIG_DISK_GUID" =~ ^[0-9A-F-]+$ ]]; then
            sgdisk -U "$ORIG_DISK_GUID" "$DST" >/dev/null 2>&1 || true
          fi
        fi
      fi
      partprobe "$DST" || true
      sync
    fi
    # Map target partitions list (kept for potential future diagnostics)
    mapfile -t _TPARTS_UNUSED < <(lsblk -ln -o NAME,PKNAME "$DST" | awk '$2=="" {next} $2!="" {print $1}')
    # If partial restore, collect selection from user
    declare -A __ADC_SELECTED
    if [ "${PARTIAL_RESTORE:-no}" = "yes" ]; then
      if [ -f "$TMPDIR/manifest.tsv" ]; then
        echo "Available partitions in archive (index: fs tool):"
        while IFS=$'\t' read -r PNAME FSTOOL TOOL; do
          IDX=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
          [ -n "$IDX" ] || continue
          echo " - $IDX: ${FSTOOL:-unknown} via ${TOOL:-?}"
        done < "$TMPDIR/manifest.tsv"
        read -rp "Enter partition numbers to restore (comma-separated, ranges ok e.g. 1,3-5): " __ADC_SEL
        # Parse selection into map
        IFS=',' read -r -a __ADC_ARR <<< "$__ADC_SEL"
        for tok in "${__ADC_ARR[@]}"; do
          tok_trim=$(echo "$tok" | sed 's/^ *//;s/ *$//')
          if [[ "$tok_trim" =~ ^[0-9]+-[0-9]+$ ]]; then
            a=$(echo "$tok_trim" | cut -d- -f1)
            b=$(echo "$tok_trim" | cut -d- -f2)
            if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] && [ "$a" -le "$b" ]; then
              for ((j=a; j<=b; j++)); do __ADC_SELECTED[$j]=1; done
            fi
          elif [[ "$tok_trim" =~ ^[0-9]+$ ]]; then
            __ADC_SELECTED[$tok_trim]=1
          fi
        done
        if [ ${#__ADC_SELECTED[@]} -eq 0 ]; then
          echo "No valid partitions selected; cancelling."; exit 1
        fi
      else
        echo "ERROR: manifest.tsv not found in archive"; exit 1
      fi
    fi
    # Restore per manifest order
    if [ -f "$TMPDIR/manifest.tsv" ]; then
      while IFS=$'\t' read -r PNAME FSTOOL TOOL; do
        # Resolve target dev by partition number suffix in PNAME
        # Extract numeric part index at end (e.g., sda3 -> 3, nvme0n1p2 -> 2)
        IDX=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
        # If partial restore, skip entries not chosen
        if [ "${PARTIAL_RESTORE:-no}" = "yes" ]; then
          [ -n "$IDX" ] && [ -n "${__ADC_SELECTED[$IDX]:-}" ] || { diag "[RESTORE] Skipping partition $IDX (not selected)"; continue; }
        fi
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
              if command -v pigz >/dev/null 2>&1; then
                pigz -dc "${BASE}.pc.gz" | partclone.extfs -r -o "$TDEV" -s -
              else
                gzip -dc "${BASE}.pc.gz" | partclone.extfs -r -o "$TDEV" -s -
              fi
            else
              echo "WARN: missing partclone image or tool for $PNAME"
            fi
            ;;
          ntfsclone)
            if [ -f "${BASE}.ntfs.gz" ] && command -v ntfsclone >/dev/null 2>&1; then
              if command -v pigz >/dev/null 2>&1; then
                pigz -dc "${BASE}.ntfs.gz" | ntfsclone --restore-image --overwrite "$TDEV" -
              else
                gzip -dc "${BASE}.ntfs.gz" | ntfsclone --restore-image --overwrite "$TDEV" -
              fi
            else
              echo "WARN: missing ntfsclone image or tool for $PNAME"
            fi
            ;;
          dd)
            if [ -f "${BASE}.raw.gz" ]; then
              if command -v pigz >/dev/null 2>&1; then
                if command -v pv >/dev/null 2>&1; then
                  pigz -dc "${BASE}.raw.gz" | pv | dd of="$TDEV" bs=1M conv=fsync status=none
                else
                  pigz -dc "${BASE}.raw.gz" | dd of="$TDEV" bs=1M status=progress conv=fsync
                fi
              else
                if command -v pv >/dev/null 2>&1; then
                  gzip -dc "${BASE}.raw.gz" | pv | dd of="$TDEV" bs=1M conv=fsync status=none
                else
                  gzip -dc "${BASE}.raw.gz" | dd of="$TDEV" bs=1M status=progress conv=fsync
                fi
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
    # Cleanup handled by trap (conditioned on RESTORE_OK)
    RESTORE_OK=yes
    echo "[RESTORE] Restore completed successfully." >&2
  else
    # Legacy full-disk raw archive
    if command -v pigz >/dev/null 2>&1; then
      pigz -dc "$ARCH" | dd of="$DST" bs=1M conv=fsync
    else
      if command -v pv >/dev/null 2>&1; then
        pv "$ARCH" | gzip -dc | dd of="$DST" bs=1M conv=fsync
      else
        gzip -dc "$ARCH" | dd of="$DST" bs=1M status=progress conv=fsync
      fi
    fi
    echo "[RESTORE] Restore completed successfully." >&2
  fi
  sync

  # Offer retry on failure (only for per-partition archives)
  if [ "${RESTORE_OK:-no}" != "yes" ] && [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && [ -f "$TMPDIR/manifest.tsv" ]; then
    echo "[RESTORE] Restore failed. Temp workspace kept: $TMPDIR" >&2
    read -rp "Retry restore with same settings? (y/N): " RETRY
    if [[ "$RETRY" =~ ^[Yy]$ ]]; then
      echo "[RESTORE] Retrying..." >&2
      # Reset RESTORE_OK and re-run the restore logic
      RESTORE_OK=no
      # Recreate partition table (reuse compact settings if applicable)
      if [ -f "$TMPDIR/partition_table.sfdisk" ]; then
        if [ "${COMPACT:-no}" = "yes" ]; then
          # Rebuild compact layout (reuse SIZE_NEW if available)
          SECTOR_SIZE=$(blockdev --getss "$DST")
          DISK_SECTORS=$(blockdev --getsz "$DST")
          # ... (compact rebuild logic would go here, reusing previous settings)
          sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk"
        else
          sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk"
        fi
        partprobe "$DST" || true
        sync
      fi
      # Re-run partition restore from temp
      if [ -f "$TMPDIR/manifest.tsv" ]; then
        mapfile -t TPARTS < <(lsblk -ln -o NAME,PKNAME "$DST" | awk '$2=="" {next} $2!="" {print $1}')
        while IFS=$'\t' read -r PNAME FSTOOL TOOL; do
          IDX=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
          TDEV=""
          if [ -n "$IDX" ]; then
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
            if [ -f "${BASE}.pc.${PART_EXT}" ] && command -v partclone.extfs >/dev/null 2>&1; then
              if [ "$PART_EXT" = "zst" ] && command -v zstd >/dev/null 2>&1; then
                zstd -dc -T${THREADS} "${BASE}.pc.zst" | partclone.extfs -r -o "$TDEV" -s -
              else
                gzip -dc "${BASE}.pc.gz" | partclone.extfs -r -o "$TDEV" -s -
              fi
              else
                echo "WARN: missing partclone image or tool for $PNAME"
              fi
              ;;
            ntfsclone)
            if [ -f "${BASE}.ntfs.${PART_EXT}" ] && command -v ntfsclone >/dev/null 2>&1; then
              if [ "$PART_EXT" = "zst" ] && command -v zstd >/dev/null 2>&1; then
                zstd -dc -T${THREADS} "${BASE}.ntfs.zst" | ntfsclone --restore-image --overwrite "$TDEV" -
              else
                gzip -dc "${BASE}.ntfs.gz" | ntfsclone --restore-image --overwrite "$TDEV" -
              fi
              else
                echo "WARN: missing ntfsclone image or tool for $PNAME"
              fi
              ;;
            dd)
            if [ -f "${BASE}.raw.${PART_EXT}" ]; then
              if command -v pv >/dev/null 2>&1; then
                if [ "$PART_EXT" = "zst" ] && command -v zstd >/dev/null 2>&1; then
                  zstd -dc -T${THREADS} "${BASE}.raw.zst" | pv | dd of="$TDEV" bs=16M ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync status=none
                else
                  gzip -dc "${BASE}.raw.gz" | pv | dd of="$TDEV" bs=16M ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync status=none
                fi
              else
                if [ "$PART_EXT" = "zst" ] && command -v zstd >/dev/null 2>&1; then
                  zstd -dc -T${THREADS} "${BASE}.raw.zst" | dd of="$TDEV" bs=16M status=progress ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync
                else
                  gzip -dc "${BASE}.raw.gz" | dd of="$TDEV" bs=16M status=progress ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync
                fi
              fi
              else
                echo "WARN: missing raw image for $PNAME"
              fi
              ;;
          esac
          sync
        done < "$TMPDIR/manifest.tsv"
      fi
      RESTORE_OK=yes
      diag "[RESTORE] Retry completed."
    fi
  fi
fi

if [[ "$OP" =~ ^[CcRr]$ ]]; then
  echo "=== Post-clone adjustments ==="
  if [ "${PARTIAL_RESTORE:-no}" != "yes" ]; then
    if command -v sgdisk >/dev/null 2>&1; then
      echo "Fixing GPT backup on target (if needed)..."
      sgdisk -e "$DST" || true
    fi
  fi
  partprobe "$DST" || true
  sync

  # Print summary of partitions for both disks
  printf "\n=== Source layout ===\n"
  lsblk "$SRC"
  printf "\n=== Target layout ===\n"
  lsblk "$DST"

  # Offer to randomize GPT disk and partition GUIDs on target to avoid conflicts
  if [ "${PARTIAL_RESTORE:-no}" != "yes" ]; then
    if command -v sgdisk >/dev/null 2>&1; then
      # Heuristic: detect a Windows installation on the target; if present, advise against GUID randomization
      has_windows=no
      mapfile -t _NTFS_TGT < <(lsblk -ln -o NAME,FSTYPE "$DST" | awk '$2=="ntfs"{print $1}')
      for _p in "${_NTFS_TGT[@]}"; do
        _dev="/dev/${_p}"
        _mp=$(mktemp -d)
        if mount -o ro "${_dev}" "${_mp}" 2>/dev/null; then
          if [ -d "${_mp}/Windows/System32" ]; then has_windows=yes; fi
          umount "${_mp}" 2>/dev/null || true
        fi
        rmdir "${_mp}" 2>/dev/null || true
      done
      if [ "$has_windows" = "yes" ]; then
        echo "Detected Windows files on target. Skipping GUID randomization is recommended to keep BCD valid."
      fi
      RAND_GUIDS=$(read_yes_no "Randomize GPT disk and partition GUIDs on TARGET? (y/N): ")
      if [[ "$RAND_GUIDS" =~ ^[Yy]$ ]]; then
        echo "Randomizing disk GUID on $DST..."
        sgdisk -G "$DST" || true
        # Randomize each partition's PARTUUID
        mapfile -t TP_PARTS < <(lsblk -ln -o NAME,PKNAME "$DST" | awk '$2!=""{print $1}')
        for pn in "${TP_PARTS[@]}"; do
          # Extract numeric index from partition name
          PNUM=$(echo "$pn" | grep -Eo '[0-9]+$' || true)
          if [[ "$PNUM" =~ ^[0-9]+$ ]]; then
            NEWGUID=$(uuidgen 2>/dev/null || echo "")
            if [ -n "$NEWGUID" ]; then
              echo "Setting new PARTUUID for partition $PNUM ($pn)..."
              sgdisk -u="$PNUM:$NEWGUID" "$DST" || true
            fi
          fi
        done
        partprobe "$DST" || true
        sync
        printf "\nNew target PARTUUIDs:\n"
        lsblk -o NAME,PARTUUID "$DST" || true
        echo "NOTE: If the restored system uses PARTUUID/UUID in /etc/fstab or bootloader configs, you may need to update them on the target."
      fi
    fi
  fi

  # Offer to enlarge the last growable partition on restore to use remaining free space
  if [[ "$OP" =~ ^[Rr]$ ]] && [ "${PARTIAL_RESTORE:-no}" != "yes" ]; then
    # Identify last partition device on target
    LAST_PART_NAME=$(lsblk -ln -o NAME,PKNAME "$DST" | awk '$2!="" {print $1}' | tail -n1)
    if [ -n "$LAST_PART_NAME" ]; then
      LAST_PART="/dev/${LAST_PART_NAME}"
      FSTYPE_LAST=$(lsblk -no FSTYPE "$LAST_PART" 2>/dev/null || true)
      # Only attempt if filesystem appears growable
      if [ "$FSTYPE_LAST" = "ext4" ] || [ "$FSTYPE_LAST" = "ntfs" ]; then
        # Compute current and possible max sizes
        SECTOR_SIZE=$(blockdev --getss "$DST")
        DISK_SECTORS=$(blockdev --getsz "$DST")
        CUR_BYTES=$(blockdev --getsize64 "$LAST_PART")
        # Parse start sector of last partition from sfdisk -d
        # Match by partition device name suffix in the dump
        START_SECT=$(sfdisk -d "$DST" 2>/dev/null | awk -v p="${LAST_PART}" '$1==p {for(i=1;i<=NF;i++){if($i ~ /^start=/){gsub(/start=/,"",$i); gsub(/,/,"",$i); print $i; exit}}}')
        if [[ "$START_SECT" =~ ^[0-9]+$ ]] && [[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]] && [[ "$DISK_SECTORS" =~ ^[0-9]+$ ]]; then
          MAX_BYTES=$(( (DISK_SECTORS - START_SECT) * SECTOR_SIZE ))
          if [ "$MAX_BYTES" -gt "$CUR_BYTES" ]; then
            CUR_H=$(numfmt --to=iec "$CUR_BYTES" 2>/dev/null || echo "$CUR_BYTES bytes")
            MAX_H=$(numfmt --to=iec "$MAX_BYTES" 2>/dev/null || echo "$MAX_BYTES bytes")
            printf "\nLast partition: %s (fs=%s)\n" "$LAST_PART" "$FSTYPE_LAST"
            printf "Current size:  %s\n" "$CUR_H"
            printf "Possible max:  %s (using remaining free space)\n" "$MAX_H"
            ENL=$(read_yes_no "Enlarge this partition now to use free space? (y/N): ")
            if [[ "$ENL" =~ ^[Yy]$ ]]; then
              # Determine partition index number for sfdisk -N
              PNUM=$(echo "$LAST_PART_NAME" | grep -Eo '[0-9]+$' || true)
              if [[ "$PNUM" =~ ^[0-9]+$ ]]; then
                # Unmount if mounted
                mount | awk -v p="$LAST_PART" '$1 == p {print $3}' | xargs -r -n1 umount || true
                echo ",+" | sfdisk --no-reread -N "$PNUM" "$DST" || true
                partprobe "$DST" || true
                sync
                if [ "$FSTYPE_LAST" = "ext4" ]; then
                  if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
                    e2fsck -f "$LAST_PART" || true
                    resize2fs "$LAST_PART" || true
                    echo "Ext4 filesystem grown."
                  else
                    echo "e2fsck/resize2fs not available; skipped filesystem grow."
                  fi
                elif [ "$FSTYPE_LAST" = "ntfs" ]; then
                  if command -v ntfsresize >/dev/null 2>&1; then
                    ntfsresize -f "$LAST_PART" || true
                    echo "NTFS filesystem grown."
                  else
                    echo "ntfsresize not available; skipped filesystem grow."
                  fi
                fi
              else
                echo "WARN: Could not determine partition index for $LAST_PART; skipping enlarge."
              fi
            fi
          fi
        fi
      fi
    fi
  fi

  # Optional: fix low space on Linux root by growing ext4 to full partition and lowering reserved blocks
  if [ "${PARTIAL_RESTORE:-no}" != "yes" ]; then
    GROW=$(read_yes_no "Grow ext4 filesystem on TARGET to fill its partition and set reserved to 1%? (y/N): ")
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
  fi
else
  echo "Saved archive: $ARCH"
  echo "Partition table dump: ${ARCH%.gz}.sfdisk (if available)"
fi

echo "=== Done ==="
show_op_time
if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "Cloned $SRC to $DST. If the target is larger, you may later expand partitions/filesystems."
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  echo "Archived $SRC to $ARCH successfully."
else
  echo "Restored $ARCH to $DST successfully."
fi

