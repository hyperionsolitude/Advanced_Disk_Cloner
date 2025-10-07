#!/bin/bash

# Advanced Disk Cloner - macOS Edition
#
# Purpose:
#   macOS-native disk cloner/archiver/restorer using diskutil, dd, and gpt.
#   Per-partition raw archive/restore with GPT preservation and optional compact layout.
#
# Key Features:
#   - Interactive disk selection via diskutil
#   - Clone disk → disk with dd and GPT recovery
#   - Archive disk → per-partition raw images packed in tar with GPT metadata
#   - Restore from archive → recreates GPT with original indices/types, optional compact
#   - Partial restore → restore selected partitions only (no GPT change)
#
# Usage:
#   sudo ./adc_macos.sh [-v|--verbose]
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

# Performance tuning defaults (auto-detected; no runtime params required)
THREADS=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
HAS_PIGZ=no; command -v pigz >/dev/null 2>&1 && HAS_PIGZ=yes || true
HAS_ZSTD=no; command -v zstd >/dev/null 2>&1 && HAS_ZSTD=yes || true

# Detect Apple Silicon for optimizations
IS_APPLE_SILICON=no
CHIP_NAME=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
if [[ "$CHIP_NAME" =~ "Apple" ]]; then
  IS_APPLE_SILICON=yes
  # Apple Silicon optimizations: use performance cores for compression
  PERF_CORES=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "$THREADS")
  # Use performance cores for compression, reserve efficiency cores for I/O
  COMP_THREADS=$((PERF_CORES > 0 ? PERF_CORES : THREADS / 2))
  [ "$COMP_THREADS" -lt 2 ] && COMP_THREADS=2
  diag "[M-series detected] Using $COMP_THREADS threads for compression (performance cores)"
  # Larger buffer sizes for Apple Silicon unified memory architecture
  DD_BS="32m"
else
  COMP_THREADS=$THREADS
  DD_BS="16m"
fi

# Compression strategy: prefer zstd (better for Apple Silicon), fallback to pigz, then gzip
if [ "$HAS_ZSTD" = "yes" ]; then
  COMP_CMD="zstd -T${COMP_THREADS} -3"
  DECOMP_CMD="zstd -T${COMP_THREADS} -d"
  COMP_EXT="zst"
  diag "[Compression] Using zstd with $COMP_THREADS threads"
elif [ "$HAS_PIGZ" = "yes" ]; then
  COMP_CMD="pigz -3 -p ${COMP_THREADS}"
  DECOMP_CMD="pigz -d -p ${COMP_THREADS}"
  COMP_EXT="gz"
  diag "[Compression] Using pigz with $COMP_THREADS threads"
else
  COMP_CMD="gzip -3"
  DECOMP_CMD="gzip -d"
  COMP_EXT="gz"
fi

echo "=== Advanced Disk Cloner (macOS Edition) ==="
echo "Checking prerequisites..."

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
run_root() { if is_root; then "$@"; else sudo "$@"; fi }

# Auto-install prerequisites via Homebrew (best effort)
has_brew() { command -v brew >/dev/null 2>&1; }

install_brew_pkg() {
  local pkg="$1"
  if has_brew; then
    echo "Installing $pkg via Homebrew..."
    brew install "$pkg" 2>&1 | grep -v "Warning:" || true
  else
    echo "WARN: Homebrew not found. Please install manually: brew install $pkg" >&2
    echo "      Or install Homebrew from: https://brew.sh" >&2
  fi
}

ensure_tool() {
  local tool="$1"
  local brew_pkg="${2:-$tool}"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing optional tool: $tool"
    if has_brew; then
      read -rp "Install $brew_pkg via Homebrew? (y/N): " INSTALL
      if [[ "$INSTALL" =~ ^[Yy]$ ]]; then
        install_brew_pkg "$brew_pkg"
      fi
    else
      echo "  Skipping (Homebrew not available)"
    fi
  fi
}

# Check for optional performance tools
ensure_tool "pigz" "pigz"
ensure_tool "zstd" "zstd"
ensure_tool "pv" "pv"

# Re-detect compression tools after potential install
HAS_PIGZ=no; command -v pigz >/dev/null 2>&1 && HAS_PIGZ=yes || true
HAS_ZSTD=no; command -v zstd >/dev/null 2>&1 && HAS_ZSTD=yes || true

# Rebuild compression strategy after potential installs
if [ "$HAS_ZSTD" = "yes" ]; then
  COMP_CMD="zstd -T${COMP_THREADS} -3"
  DECOMP_CMD="zstd -T${COMP_THREADS} -d"
  COMP_EXT="zst"
  diag "[Compression] Using zstd with $COMP_THREADS threads"
elif [ "$HAS_PIGZ" = "yes" ]; then
  COMP_CMD="pigz -3 -p ${COMP_THREADS}"
  DECOMP_CMD="pigz -d -p ${COMP_THREADS}"
  COMP_EXT="gz"
  diag "[Compression] Using pigz with $COMP_THREADS threads"
else
  COMP_CMD="gzip -3"
  DECOMP_CMD="gzip -d"
  COMP_EXT="gz"
fi

echo "Darwin support active: per-partition raw archive/restore with GPT preservation."
if [ "$IS_APPLE_SILICON" = "yes" ]; then
  MEM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024/1024)}')
  echo "Hardware: $CHIP_NAME ($THREADS cores, ${MEM_GB}GB RAM)"
  echo "Optimizations: ${DD_BS} buffer, ${COMP_THREADS}-thread compression, ${COMP_CMD%% *} compressor"
fi

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

# List candidate whole disks using diskutil. Prefer entries from the '0:' line (whole-disk row).
mapfile -t DISKS < <(diskutil list | awk '/^ *0:/{print $NF}' | sort -u | sed 's#^#/dev/#')
if [ ${#DISKS[@]} -eq 0 ]; then
  # Fallback: any /dev/diskN headers
  mapfile -t DISKS < <(diskutil list | awk '/^\/dev\/disk[0-9]+/ {print $1}')
fi
if [ ${#DISKS[@]} -eq 0 ]; then
  echo "[macOS] No disks found via diskutil."; exit 1
fi

# Pretty-print with size/model
echo "=== Available Disks (macOS) ==="
for i in "${!DISKS[@]}"; do
  D="${DISKS[$i]}"
  SZ_H=$(diskutil info "$D" 2>/dev/null | awk -F':' '/^ *Disk Size:/ {gsub(/^ *| *$/,"",$2); sub(/ \(.*/,"",$2); print $2; exit}')
  [ -n "$SZ_H" ] || SZ_H="?"
  MD=$(diskutil info "$D" 2>/dev/null | awk -F':' '/^ *Device Location:/ {gsub(/^ *| *$/,"",$2); print $2; exit}')
  echo "[$((i+1))] $D  size=$SZ_H  location=${MD:-?}"
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

if ! [[ "$SRC_IDX" =~ ^[0-9]+$ ]]; then echo "ERROR: source selection must be a number"; exit 1; fi
if [[ "$OP" =~ ^[Cc]$ ]] && ! [[ "$DST_IDX" =~ ^[0-9]+$ ]]; then echo "ERROR: target selection must be a number"; exit 1; fi

SRC_IDX=$((SRC_IDX-1))
if [ "$DST_IDX" -ge 0 ]; then DST_IDX=$((DST_IDX-1)); fi
if [ "$SRC_IDX" -lt 0 ] || [ "$SRC_IDX" -ge ${#DISKS[@]} ]; then echo "ERROR: source selection out of range"; exit 1; fi
if [[ "$OP" =~ ^[Cc]$ ]]; then
  if [ "$DST_IDX" -lt 0 ] || [ "$DST_IDX" -ge ${#DISKS[@]} ]; then echo "ERROR: target selection out of range"; exit 1; fi
fi

SRC="${DISKS[$SRC_IDX]}"
if [[ "$OP" =~ ^[Cc]$ ]]; then DST="${DISKS[$DST_IDX]}"; else DST=""; fi
if [[ "$OP" =~ ^[Cc]$ ]] && [ "$SRC" = "$DST" ]; then echo "ERROR: SOURCE and TARGET must be different"; exit 1; fi

# Helper: extract bytes from diskutil info's parentheses on Disk Size line
mac_bytes() {
  local dev="$1"
  diskutil info "$dev" 2>/dev/null | awk -F'[()]' '/^ *Disk Size:/ {gsub(/ Bytes/,"",$2); gsub(/,/,"",$2); if($2~^[0-9]+$) {print $2; exit}} END{if(NR==0) print 0}'
}

SRC_BYTES=$(mac_bytes "$SRC")
if [[ ! "$SRC_BYTES" =~ ^[0-9]+$ ]] || [ "$SRC_BYTES" -eq 0 ]; then echo "ERROR: Could not determine source size"; exit 1; fi
if [[ "$OP" =~ ^[Cc]$ ]]; then
  DST_BYTES=$(mac_bytes "$DST")
  if [[ ! "$DST_BYTES" =~ ^[0-9]+$ ]] || [ "$DST_BYTES" -eq 0 ]; then echo "ERROR: Could not determine target size"; exit 1; fi
  if [ "$SRC_BYTES" -gt "$DST_BYTES" ]; then echo "ERROR: Target is smaller than source; cannot proceed."; exit 1; fi
fi

# Archive path prompt if needed
if [[ "$OP" =~ ^[Aa]$ ]]; then
  SRC_BASENAME=$(basename "$SRC")
  DEF_ARCH_PATH="./${SRC_BASENAME}.tar.gz"
  read -e -p "Enter archive file name or path [default ${SRC_BASENAME}.tar.gz]: " -i "$DEF_ARCH_PATH" ARCH
  ARCH=${ARCH:-$DEF_ARCH_PATH}
elif [[ "$OP" =~ ^[Rr]$ ]]; then
  read -e -p "Enter archive image file to restore (e.g., ./disk0.tar.gz): " ARCH
  [ -f "$ARCH" ] || { echo "Archive not found: $ARCH"; exit 1; }
fi

# Safety: detect if SOURCE is the current system disk (boot volume)
BOOT_DISK=$(diskutil info / 2>/dev/null | awk -F: '/Part of Whole:/ {gsub(/^ *| *$/,"",$2); print "/dev/"$2; exit}')
LIVE_ON_SOURCE=0
if [ -n "$BOOT_DISK" ] && [ "$SRC" = "$BOOT_DISK" ]; then
  LIVE_ON_SOURCE=1
fi

# Confirm destructive ops
echo "SOURCE: $SRC"
if [ "$LIVE_ON_SOURCE" -eq 1 ]; then
  echo ""
  echo "⚠️  WARNING: You are operating on the BOOT DISK (contains running macOS)"
  echo "    - Archiving a live system may produce inconsistent snapshots"
  echo "    - Files being written during archive may be partially captured"
  echo "    - System files may be in use and locked"
  echo ""
  echo "💡 RECOMMENDED: Boot from another disk or macOS Recovery to archive this disk"
  echo "    - Hold Cmd+R during boot for Recovery Mode"
  echo "    - Boot from external USB with macOS installer"
  echo "    - Use Target Disk Mode from another Mac"
  echo ""
  read -rp "Proceed with READ-ONLY archiving of live system anyway? (y/N): " PROCEED_LIVE
  [[ "$PROCEED_LIVE" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }
fi

if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "TARGET: $DST (WILL BE ERASED)"
  read -rp "Type YES to confirm clone: " CONFIRM; [ "$CONFIRM" = "YES" ] || { echo "Cancelled"; exit 1; }
elif [[ "$OP" =~ ^[Rr]$ ]]; then
  echo "TARGET: select next"
  echo "=== Available Disks (restore target) ==="
  for i in "${!DISKS[@]}"; do
    D="${DISKS[$i]}"; SZ_H=$(diskutil info "$D" 2>/dev/null | awk -F':' '/^ *Disk Size:/ {gsub(/^ *| *$/,"",$2); sub(/ \(.*/,"",$2); print $2; exit}'); [ -n "$SZ_H" ] || SZ_H="?"; echo "[$((i+1))] $D  size=$SZ_H"
  done
  read -rp "Select TARGET number for restore: " DST_IDX
  DST_IDX=$((DST_IDX-1))
  if [ "$DST_IDX" -lt 0 ] || [ "$DST_IDX" -ge ${#DISKS[@]} ]; then echo "ERROR: target selection out of range"; exit 1; fi
  DST="${DISKS[$DST_IDX]}"
  echo "TARGET: $DST (WILL BE ERASED)"; read -rp "Type YES to confirm restore: " CONFIRM; [ "$CONFIRM" = "YES" ] || { echo "Cancelled"; exit 1; }
fi

# Unmount target if applicable
if [[ "$OP" =~ ^[CcRr]$ ]]; then
  echo "=== Unmounting target if mounted ==="
  run_root diskutil unmountDisk force "$DST" >/dev/null 2>&1 || true
fi

# Choose raw devices for better throughput (rdiskN)
raw_dev() { echo "$1" | sed 's#/dev/disk#/dev/rdisk#'; }

start_op_timer
if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "=== Start clone: $SRC → $DST ==="
  IF=$(raw_dev "$SRC"); OF=$(raw_dev "$DST")
  if command -v pv >/dev/null 2>&1; then
    run_root sh -c "dd if=\"$IF\" bs=$DD_BS conv=noerror,sync | pv -s $SRC_BYTES | dd of=\"$OF\" bs=$DD_BS conv=fsync"
  else
    run_root dd if="$IF" of="$OF" bs="$DD_BS" conv=noerror,sync,fsync
  fi
  sync
  run_root diskutil repairDisk "$DST" >/dev/null 2>&1 || true
  if command -v gpt >/dev/null 2>&1; then run_root gpt recover "$DST" >/dev/null 2>&1 || true; fi
  echo "=== Done ==="; show_op_time; echo "Cloned $SRC to $DST."; exit 0
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  echo "=== Start archive (per-partition): $SRC → $ARCH ==="
  # Workspace near archive
  ARCH_DIRNAME=$(dirname "$ARCH"); mkdir -p "$ARCH_DIRNAME"
  if [ -n "${ADC_TMPDIR:-}" ]; then TMPDIR="$ADC_TMPDIR"; mkdir -p "$TMPDIR"; else TMPDIR=$(mktemp -d "${ARCH_DIRNAME%/}/.adc_tmp.XXXXXX"); fi
  cleanup_tmp() { [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"; }
  trap 'cleanup_tmp' EXIT INT TERM HUP
  diag "[ARCH] Using temp workspace: $TMPDIR"
  MANIFEST="$TMPDIR/manifest.tsv"; : > "$MANIFEST"
  # Save GPT and diskutil diagnostics
  (diskutil list "$SRC" || true) > "$TMPDIR/diskutil_list.txt"
  (gpt -r show "$SRC" || true) > "$TMPDIR/gpt_show.txt"
  # Build map of start/size by index via gpt -r show (columns: start size index ...)
  # store as: idx start size
  (awk 'NF>=3 && $3 ~ /^[0-9]+$/ {print $3"\t"$1"\t"$2}' "$TMPDIR/gpt_show.txt" | sort -n) > "$TMPDIR/gpt_map.tsv"
  # Enumerate partitions for SRC
  mapfile -t PARTS < <(diskutil list "$SRC" | awk '$NF ~ /^disk[0-9]+s[0-9]+$/ {print $NF}' )
  total=${#PARTS[@]}; num=0
  for ident in "${PARTS[@]}"; do
    num=$((num+1))
    PDEV="/dev/r${ident}"  # raw device for speed
    # Determine index number from ident suffix (sN)
    IDX=$(echo "$ident" | sed -E 's/^.*s([0-9]+)$/\1/')
    # Query Type GUID and Partition UUID
    TYPE_GUID=$(diskutil info "/dev/${ident}" 2>/dev/null | awk -F: '/^ *Type \(GUID\):/ {gsub(/^ *| *$/,"",$2); print $2; exit}')
    PART_UUID=$(diskutil info "/dev/${ident}" 2>/dev/null | awk -F: '/^ *Partition UUID:/ {gsub(/^ *| *$/,"",$2); print $2; exit}')
    START=$(awk -v i="$IDX" '$1==i{print $2; exit}' "$TMPDIR/gpt_map.tsv")
    SIZE=$(awk -v i="$IDX" '$1==i{print $3; exit}' "$TMPDIR/gpt_map.tsv")
      progress_msg "[$num/$total] Archiving ${ident}..."
      OUTBASE="$TMPDIR/part-${ident}"
      OUTFILE="${OUTBASE}.raw.${COMP_EXT}"
      if command -v pv >/dev/null 2>&1; then
        run_root sh -c "dd if=\"$PDEV\" bs=$DD_BS status=none | pv | $COMP_CMD > \"${OUTFILE}\""
      else
        run_root sh -c "dd if=\"$PDEV\" bs=$DD_BS status=progress | $COMP_CMD > \"${OUTFILE}\""
      fi
      sz=$(stat -f %z "${OUTFILE}" 2>/dev/null || echo 0)
    echo -e "${ident}\t${IDX}\t${TYPE_GUID:-UNKNOWN}\t${PART_UUID:-}\t${START:-}\t${SIZE:-}\tdd\t${sz}" >> "$MANIFEST"
  done
  # Package to tar with optimized compression
  progress_msg "Packaging archive..."
  TARFILE="$ARCH"
  if [ "$HAS_ZSTD" = "yes" ]; then
    (cd "$TMPDIR" && tar -I "zstd -T${COMP_THREADS} -3" -cf "$TARFILE" manifest.tsv gpt_show.txt diskutil_list.txt *.raw.*)
  elif [ "$HAS_PIGZ" = "yes" ]; then
    (cd "$TMPDIR" && tar -I "pigz -3 -p ${COMP_THREADS}" -cf "$TARFILE" manifest.tsv gpt_show.txt diskutil_list.txt *.raw.*)
  else
    (cd "$TMPDIR" && tar -czf "$TARFILE" manifest.tsv gpt_show.txt diskutil_list.txt *.raw.*)
  fi
  echo "=== Done ==="; show_op_time; echo "Archived $SRC to $ARCH successfully."; exit 0
else
  echo "=== Start restore (per-partition): $ARCH → $DST ==="
  # Extract archive with optimized decompression
  ARCH_DIRNAME=$(dirname "$ARCH"); if [ -n "${ADC_TMPDIR:-}" ]; then TMPDIR="$ADC_TMPDIR"; mkdir -p "$TMPDIR"; else TMPDIR=$(mktemp -d "${ARCH_DIRNAME%/}/.adc_tmp.XXXXXX"); fi
  diag "[RESTORE] Using temp workspace: $TMPDIR"; export TMPDIR
  if [ "$HAS_ZSTD" = "yes" ]; then
    tar -I "zstd -T${COMP_THREADS} -d" -xf "$ARCH" -C "$TMPDIR"
  elif [ "$HAS_PIGZ" = "yes" ]; then
    tar -I "pigz -d -p ${COMP_THREADS}" -xf "$ARCH" -C "$TMPDIR"
  else
    tar -xzf "$ARCH" -C "$TMPDIR"
  fi
  [ -f "$TMPDIR/manifest.tsv" ] || { echo "ERROR: manifest.tsv missing in archive"; exit 1; }
  # Ask for partial restore
  PR=$(read_yes_no "Partial restore: restore only selected partitions? (y/N): ")
  PARTIAL=no; declare -A SEL
  if [[ "$PR" =~ ^[Yy]$ ]]; then
    PARTIAL=yes
    echo "Available partitions in archive (idx ident):"
    awk '{print $2"\t"$1}' "$TMPDIR/manifest.tsv"
    read -rp "Enter partition numbers to restore (comma-separated, ranges ok e.g. 1,3-5): " __SEL
    IFS=',' read -r -a __ARR <<< "$__SEL"
    for tok in "${__ARR[@]}"; do
      t=$(echo "$tok" | sed 's/^ *//;s/ *$//')
      if [[ "$t" =~ ^[0-9]+-[0-9]+$ ]]; then a=$(echo "$t"|cut -d- -f1); b=$(echo "$t"|cut -d- -f2); if [ "$a" -le "$b" ]; then for ((j=a;j<=b;j++)); do SEL[$j]=1; done; fi; elif [[ "$t" =~ ^[0-9]+$ ]]; then SEL[$t]=1; fi
    done
    [ ${#SEL[@]} -gt 0 ] || { echo "No valid selections; cancelling."; exit 1; }
    echo "You chose partial restore. Partition table will NOT be modified."
  fi
  # Recreate GPT if not partial
  if [ "$PARTIAL" = "no" ]; then
    run_root diskutil unmountDisk force "$DST" >/dev/null 2>&1 || true
    run_root gpt destroy -f "$DST" >/dev/null 2>&1 || true
    run_root gpt create -f "$DST"
    # Preserve original starts/sizes by default; optional compact
    CM=$(read_yes_no "Compact restore: pack partitions contiguously (preserve numbers)? (y/N): ")
    COMPACT=no; [[ "$CM" =~ ^[Yy]$ ]] && COMPACT=yes
    # Build arrays from manifest: ident idx type_guid part_uuid start size
    mapfile -t LINES < "$TMPDIR/manifest.tsv"
    # Determine first usable LBA on target (approx 40); fall back to 40
    FIRST_LBA=40
    # Recreate entries
    NEXT_LBA=$FIRST_LBA
    for ln in "${LINES[@]}"; do
      ident=$(echo "$ln" | awk '{print $1}')
      idx=$(echo "$ln" | awk '{print $2}')
      typeg=$(echo "$ln" | awk '{print $3}')
      puid=$(echo "$ln" | awk '{print $4}')
      start=$(echo "$ln" | awk '{print $5}')
      size=$(echo "$ln" | awk '{print $6}')
      if [ "$COMPACT" = "yes" ]; then b=$NEXT_LBA; s=$size; else b=$start; s=$size; fi
      # Some archives may lack type GUID; fallback to Apple_APFS if missing
      tg="$typeg"; [ -n "$tg" ] || tg="7C3457EF-0000-11AA-AA11-00306543ECAC" # Apple_APFS
      run_root gpt add -i "$idx" -t "$tg" -b "$b" -s "$s" "$DST" >/dev/null 2>&1 || true
      if [ -n "$puid" ]; then run_root gpt add -i "$idx" -u "$puid" "$DST" >/dev/null 2>&1 || true; fi
      if [ "$COMPACT" = "yes" ]; then NEXT_LBA=$((b + s)); fi
    done
    run_root diskutil repairDisk "$DST" >/dev/null 2>&1 || true
  fi
  # Restore partition images with optimized decompression
  while IFS=$'\t' read -r ident idx typeg puid start size tool sz; do
    if [ "$PARTIAL" = "yes" ]; then [ -n "${SEL[$idx]:-}" ] || { diag "[RESTORE] Skip $ident (not selected)"; continue; }; fi
    TDEV="/dev/r$(basename "$DST")s${idx}"
    BASE="$TMPDIR/part-${ident}"
    # Try both compression formats
    IMGFILE=""
    if [ -f "${BASE}.raw.zst" ]; then IMGFILE="${BASE}.raw.zst"; EXT="zst"
    elif [ -f "${BASE}.raw.gz" ]; then IMGFILE="${BASE}.raw.gz"; EXT="gz"
    fi
    
    if [ -n "$IMGFILE" ]; then
      if [ "$EXT" = "zst" ] && command -v zstd >/dev/null 2>&1; then
        if command -v pv >/dev/null 2>&1; then
          run_root sh -c "zstd -dc -T${COMP_THREADS} \"${IMGFILE}\" | pv | dd of=\"$TDEV\" bs=$DD_BS conv=fsync status=none"
        else
          run_root sh -c "zstd -dc -T${COMP_THREADS} \"${IMGFILE}\" | dd of=\"$TDEV\" bs=$DD_BS status=progress conv=fsync"
        fi
      elif command -v pigz >/dev/null 2>&1; then
        if command -v pv >/dev/null 2>&1; then
          run_root sh -c "pigz -dc -p ${COMP_THREADS} \"${IMGFILE}\" | pv | dd of=\"$TDEV\" bs=$DD_BS conv=fsync status=none"
        else
          run_root sh -c "pigz -dc -p ${COMP_THREADS} \"${IMGFILE}\" | dd of=\"$TDEV\" bs=$DD_BS status=progress conv=fsync"
        fi
      else
        if command -v pv >/dev/null 2>&1; then
          run_root sh -c "gzip -dc \"${IMGFILE}\" | pv | dd of=\"$TDEV\" bs=$DD_BS conv=fsync status=none"
        else
          run_root sh -c "gzip -dc \"${IMGFILE}\" | dd of=\"$TDEV\" bs=$DD_BS status=progress conv=fsync"
        fi
      fi
    else
      echo "WARN: missing image for ${ident}"
    fi
    sync
  done < "$TMPDIR/manifest.tsv"
  run_root diskutil repairDisk "$DST" >/dev/null 2>&1 || true
  echo "=== Done ==="; show_op_time; echo "Restored $ARCH to $DST successfully."; exit 0
fi
