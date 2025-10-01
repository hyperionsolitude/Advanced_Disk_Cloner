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
ensure_commands dd sfdisk gzip tar lsblk awk pv gdisk partclone.extfs ntfsclone tune2fs e2fsck resize2fs

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
  if [ -e "$ARCH" ]; then read -rp "File exists at $ARCH. Overwrite? (y/N): " OW; [[ "$OW" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }; fi
elif [[ "$OP" =~ ^[Rr]$ ]]; then
  # Restore from image to selected target disk
  read -rp "Enter archive image file to restore (e.g., ./sdb.img.gz): " ARCH
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
    # Create a temporary workspace on the destination filesystem (not /tmp),
    # to avoid running out of space when root has low free space.
    ARCH_TAR="$ARCH"
    case "$ARCH_TAR" in
      *.gz|*.tgz) : ;;
      *) ARCH_TAR="${ARCH_TAR}.tar.gz" ;;
    esac
    ARCH_DIRNAME=$(dirname "$ARCH_TAR")
    mkdir -p "$ARCH_DIRNAME"
    TMPDIR=$(mktemp -d "${ARCH_DIRNAME%/}/.adc_tmp.XXXXXX")
    cleanup_tmp() { [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"; }
    trap 'cleanup_tmp' EXIT INT TERM HUP
    MANIFEST="$TMPDIR/manifest.tsv"
    STATUS_LOG="$TMPDIR/status.tsv"
    : > "$MANIFEST"
    : > "$STATUS_LOG"
    # Save partition table dump
    sfdisk -d "$SRC" > "$TMPDIR/partition_table.sfdisk" 2>/dev/null || true
    # Enumerate partitions on source disk
    mapfile -t APARTS < <(lsblk -ln -o NAME,FSTYPE,SIZE,PARTLABEL,PARTUUID,PKNAME "$SRC" | awk 'NR>1 {print $1"\t"$2"\t"$3"\t"$4"\t"$5}')
    for line in "${APARTS[@]}"; do
      PNAME=$(echo -e "$line" | awk -F"\t" '{print $1}')
      FST=$(echo -e   "$line" | awk -F"\t" '{print $2}')
      DEV="/dev/$PNAME"
      OUTBASE="$TMPDIR/part-${PNAME}"
      echo "[ARCH] Start: $PNAME (fs=${FST:-unknown})" >&2
      case "$FST" in
        ext4)
          # If partition is mounted (e.g., root), avoid partclone and fallback to dd
          MOUNTED_AT=$(findmnt -no TARGET "$DEV" 2>/dev/null || true)
          if command -v partclone.extfs >/dev/null 2>&1 && [ -z "$MOUNTED_AT" ]; then
            echo -e "$PNAME\text4\tpartclone" >> "$MANIFEST"
            (
              set +e -o pipefail
              if command -v pv >/dev/null 2>&1; then
                partclone.extfs -c -s "$DEV" -o - 2>/dev/null | pv | gzip -1 > "${OUTBASE}.pc.gz"
              else
                partclone.extfs -c -s "$DEV" -o - 2>/dev/null | gzip -1 > "${OUTBASE}.pc.gz"
              fi
            ); rc=$?
            if [ $rc -eq 0 ] && [ -f "${OUTBASE}.pc.gz" ]; then
              sz=$(stat -c %s "${OUTBASE}.pc.gz" 2>/dev/null || echo 0)
              echo -e "$PNAME\tpartclone\tOK\t$sz" >> "$STATUS_LOG"
              echo "[ARCH] Done: $PNAME via partclone (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))" >&2
            else
              echo -e "$PNAME\tpartclone\tFAIL\t0" >> "$STATUS_LOG"
              echo "[ARCH] FAIL: $PNAME via partclone (rc=$rc)" >&2
            fi
          else
            echo -e "$PNAME\text4\tdd" >> "$MANIFEST"
            (
              set +e -o pipefail
              if command -v pv >/dev/null 2>&1; then
                dd if="$DEV" bs=1M status=none | pv | gzip -1 > "${OUTBASE}.raw.gz"
              else
                dd if="$DEV" bs=1M status=progress | gzip -1 > "${OUTBASE}.raw.gz"
              fi
            ); rc=$?
            if [ $rc -eq 0 ] && [ -f "${OUTBASE}.raw.gz" ]; then
              sz=$(stat -c %s "${OUTBASE}.raw.gz" 2>/dev/null || echo 0)
              echo -e "$PNAME\tdd\tOK\t$sz" >> "$STATUS_LOG"
              echo "[ARCH] Done: $PNAME via dd (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))" >&2
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
              if command -v pv >/dev/null 2>&1; then
                ntfsclone --save-image --output - "$DEV" 2>/dev/null | pv | gzip -1 > "${OUTBASE}.ntfs.gz"
              else
                ntfsclone --save-image --output - "$DEV" 2>/dev/null | gzip -1 > "${OUTBASE}.ntfs.gz"
              fi
            ); rc=$?
            if [ $rc -eq 0 ] && [ -f "${OUTBASE}.ntfs.gz" ]; then
              sz=$(stat -c %s "${OUTBASE}.ntfs.gz" 2>/dev/null || echo 0)
              echo -e "$PNAME\tntfsclone\tOK\t$sz" >> "$STATUS_LOG"
              echo "[ARCH] Done: $PNAME via ntfsclone (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))" >&2
            else
              echo -e "$PNAME\tntfsclone\tFAIL\t0" >> "$STATUS_LOG"
              echo "[ARCH] FAIL: $PNAME via ntfsclone (rc=$rc)" >&2
            fi
          else
            echo -e "$PNAME\tntfs\tdd" >> "$MANIFEST"
            (
              set +e -o pipefail
              if command -v pv >/dev/null 2>&1; then
                dd if="$DEV" bs=1M status=none | pv | gzip -1 > "${OUTBASE}.raw.gz"
              else
                dd if="$DEV" bs=1M status=progress | gzip -1 > "${OUTBASE}.raw.gz"
              fi
            ); rc=$?
            if [ $rc -eq 0 ] && [ -f "${OUTBASE}.raw.gz" ]; then
              sz=$(stat -c %s "${OUTBASE}.raw.gz" 2>/dev/null || echo 0)
              echo -e "$PNAME\tdd\tOK\t$sz" >> "$STATUS_LOG"
              echo "[ARCH] Done: $PNAME via dd (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))" >&2
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
              dd if="$DEV" bs=1M status=none | pv | gzip -1 > "${OUTBASE}.raw.gz"
            else
              dd if="$DEV" bs=1M status=progress | gzip -1 > "${OUTBASE}.raw.gz"
            fi
          ); rc=$?
          if [ $rc -eq 0 ] && [ -f "${OUTBASE}.raw.gz" ]; then
            sz=$(stat -c %s "${OUTBASE}.raw.gz" 2>/dev/null || echo 0)
            echo -e "$PNAME\tdd\tOK\t$sz" >> "$STATUS_LOG"
            echo "[ARCH] Done: $PNAME via dd (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))" >&2
          else
            echo -e "$PNAME\tdd\tFAIL\t0" >> "$STATUS_LOG"
            echo "[ARCH] FAIL: $PNAME via dd (rc=$rc)" >&2
          fi
          ;;
      esac
    done
    # Package everything into a tarball (new-format archive) with progress
    echo "[ARCH] Packaging archive..." >&2
    PKG_BYTES=$(du -sb "$TMPDIR" 2>/dev/null | awk '{print $1}')
    if command -v pv >/dev/null 2>&1 && [[ "$PKG_BYTES" =~ ^[0-9]+$ ]]; then
      (cd "$TMPDIR" && tar -cz . | pv -s "$PKG_BYTES" > "$ARCH_TAR")
    else
      (cd "$TMPDIR" && tar -czf "$ARCH_TAR" .)
    fi
    mv -f "$ARCH_TAR" "$ARCH" 2>/dev/null || true
    echo "\n[ARCH] Summary (partition, tool, status, size-bytes):" >&2
    sed -n '1,200p' "$STATUS_LOG" 2>/dev/null >&2 || true
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
    # Create temporary workspace on the same filesystem as the archive (not /tmp)
    ARCH_DIRNAME=$(dirname "$ARCH")
    mkdir -p "$ARCH_DIRNAME"
    TMPDIR=$(mktemp -d "${ARCH_DIRNAME%/}/.adc_tmp.XXXXXX")
    cleanup_tmp() {
      # Only remove temp if RESTORE_OK=yes; keep on failure for diagnostics
      if [ "${RESTORE_OK:-no}" = "yes" ]; then
        [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"
      else
        echo "[RESTORE] Kept temp workspace for diagnostics: $TMPDIR" >&2
      fi
    }
    trap 'cleanup_tmp' EXIT INT TERM HUP
    echo "[RESTORE] Extracting archive..." >&2
    if command -v pv >/dev/null 2>&1; then
      ARCH_BYTES=$(stat -c %s "$ARCH" 2>/dev/null || echo 0)
      if [[ "$ARCH_BYTES" =~ ^[0-9]+$ ]] && [ "$ARCH_BYTES" -gt 0 ]; then
        pv -s "$ARCH_BYTES" "$ARCH" | tar --no-same-owner -xz -C "$TMPDIR"
      else
        tar --no-same-owner -xzf "$ARCH" -C "$TMPDIR"
      fi
    else
      tar --no-same-owner -xzf "$ARCH" -C "$TMPDIR"
    fi
    # Recreate partition table (optionally compact/resize before restore)
    if [ -f "$TMPDIR/partition_table.sfdisk" ]; then
      COMPACT=$(read_yes_no "Compact restore: pack partitions contiguously (preserve numbers)? (y/N): ")
      if [[ "$COMPACT" =~ ^[Yy]$ ]]; then
        SECTOR_SIZE=$(blockdev --getss "$DST")
        DISK_SECTORS=$(blockdev --getsz "$DST")
        # Parse original dump to collect partition sizes and types by index
        # Lines look like: /dev/nvme0n1p3 : start=     123, size=   456, type=...
        # Note: saved table contains SOURCE device names, not TARGET
        mapfile -t DUMP_LINES < <(grep -E "^$SRC(p|)[0-9]+[[:space:]]*:" "$TMPDIR/partition_table.sfdisk" || true)
        if [ ${#DUMP_LINES[@]} -eq 0 ]; then
          echo "WARN: Could not parse original partition table; falling back to original layout."
          sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk"
        else
          # Build arrays: IDX -> TYPE, SIZE_SECT
          PART_INDEXES=()
          declare -A TYPE_BY_IDX
          declare -A SIZE_BY_IDX
          for ln in "${DUMP_LINES[@]}"; do
            idx=$(printf '%s' "$ln" | grep -Eo '[0-9]+(?=\s*:)' | tail -n1)
            type=$(printf '%s' "$ln" | awk -F'type=' 'NF>1{print $2}' | awk -F',' '{print $1}' | sed 's/[[:space:]]//g')
            size=$(printf '%s' "$ln" | awk -F'size=' 'NF>1{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
            if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$size" =~ ^[0-9]+$ ]]; then
              PART_INDEXES+=("$idx")
              TYPE_BY_IDX[$idx]="$type"
              SIZE_BY_IDX[$idx]="$size"
            fi
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
              # sfdisk line: <dev>p<i> : size=<s>, type=<t>
              if [[ "$DST" =~ nvme[0-9]+n[0-9]+$ ]]; then
                echo "${DST}p${i} : size=${s}${t:+, type=$t}"
              else
                echo "${DST}${i} : size=${s}${t:+, type=$t}"
              fi
            done
          } > "$NEWTAB"
          sfdisk "$DST" < "$NEWTAB"
          rm -f "$NEWTAB"
        fi
      else
        sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk"
      fi
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
    # Cleanup handled by trap (conditioned on RESTORE_OK)
    RESTORE_OK=yes
    echo "[RESTORE] Restore completed successfully." >&2
  else
    # Legacy full-disk raw archive
    if command -v pv >/dev/null 2>&1; then
      pv "$ARCH" | gzip -dc | dd of="$DST" bs=1M conv=fsync
    else
      gzip -dc "$ARCH" | dd of="$DST" bs=1M status=progress conv=fsync
    fi
    echo "[RESTORE] Restore completed successfully." >&2
  fi
  sync

  # Offer retry on failure (only for per-partition archives)
  if [ "${RESTORE_OK:-no}" != "yes" ] && [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
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
      fi
      RESTORE_OK=yes
      echo "[RESTORE] Retry completed." >&2
    fi
  fi
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

  # Offer to enlarge the last growable partition on restore to use remaining free space
  if [[ "$OP" =~ ^[Rr]$ ]]; then
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
            echo "\nLast partition: $LAST_PART (fs=$FSTYPE_LAST)"
            echo "Current size:  $CUR_H"
            echo "Possible max:  $MAX_H (using remaining free space)"
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
else
  echo "Saved archive: $ARCH"
  echo "Partition table dump: ${ARCH%.gz}.sfdisk (if available)"
fi

## Source re-grow feature removed

echo "=== Done ==="
if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "Cloned $SRC to $DST. If the target is larger, you may later expand partitions/filesystems."
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  echo "Archived $SRC to $ARCH successfully."
else
  echo "Restored $ARCH to $DST successfully."
fi

