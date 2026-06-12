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
#     • Optional enlargement of last partition and filesystem grow
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
#   sudo ./clone_minimal.sh [-v|--verbose] [--offline] [--offline-bundle <dir>] [--offline-archive <file>] [--bundle-deps <dir>] [--bundle-deps-archive <file>] [--self-test]
#
# License: MIT
#

set -euo pipefail

# CLI flags
VERBOSE=no
OFFLINE_MODE=no
OFFLINE_BUNDLE_DIR="${ADC_DEB_BUNDLE:-}"
OFFLINE_BUNDLE_ARCHIVE=""
BUNDLE_DEPS_DIR=""
BUNDLE_DEPS_ARCHIVE=""
BUILD_DEB_TARGET=""
SELF_TEST=no
UI_MODE="${ADC_UI:-0}"
LOG_FILE=""
ORIGINAL_ARGS=("$@")

show_help() {
  cat <<'EOF'
Advanced Disk Cloner

Usage:
  sudo ./clone_minimal.sh [options]

Options:
  -v, --verbose                      Enable verbose diagnostics
  --self-test                        Run environment self-test and exit
  --log-file <path>                  Write operation log to file (auto-generated if omitted)
  --help                             Show this help and exit
  --ui                               Force whiptail dialog mode for prompts

Offline package prep/install:
  --bundle-deps <dir>                Download required .deb packages into directory
  --bundle-deps-archive <path|dir>   Create offline package archive (.tar.gz)
                                      - If a directory is given, auto-generates archive name
  --offline                          Enable offline install mode (requires bundle source)
  --offline-bundle <dir>             Install required packages from bundle directory
  --offline-archive <file>           Install required packages from archive file
  --build-deb <path|dir>             Build installable .deb package for this app
                                      - If a directory is given, auto-generates package name

Examples:
  sudo ./clone_minimal.sh --bundle-deps-archive ./
  sudo ./clone_minimal.sh --offline-archive ./adc-offline-pkgs-YYYYMMDD-HHMMSS.tar.gz
  sudo ./clone_minimal.sh --build-deb ./
  sudo ./clone_minimal.sh -v
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    --ui) UI_MODE=1; shift ;;
    -v|--verbose) VERBOSE=yes; shift ;;
    --offline) OFFLINE_MODE=yes; shift ;;
    --offline-bundle)
      [ "$#" -ge 2 ] || { echo "ERROR: --offline-bundle requires a directory path"; exit 1; }
      OFFLINE_BUNDLE_DIR="$2"
      OFFLINE_MODE=yes
      shift 2
      ;;
    --offline-archive)
      [ "$#" -ge 2 ] || { echo "ERROR: --offline-archive requires an archive path"; exit 1; }
      OFFLINE_BUNDLE_ARCHIVE="$2"
      OFFLINE_MODE=yes
      shift 2
      ;;
    --bundle-deps)
      [ "$#" -ge 2 ] || { echo "ERROR: --bundle-deps requires a directory path"; exit 1; }
      BUNDLE_DEPS_DIR="$2"
      shift 2
      ;;
    --bundle-deps-archive)
      [ "$#" -ge 2 ] || { echo "ERROR: --bundle-deps-archive requires an archive path"; exit 1; }
      BUNDLE_DEPS_ARCHIVE="$2"
      shift 2
      ;;
    --build-deb)
      [ "$#" -ge 2 ] || { echo "ERROR: --build-deb requires a path"; exit 1; }
      BUILD_DEB_TARGET="$2"
      shift 2
      ;;
    --self-test) SELF_TEST=yes; shift ;;
    --log-file)
      [ "$#" -ge 2 ] || { echo "ERROR: --log-file requires a path"; exit 1; }
      LOG_FILE="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: sudo ./clone_minimal.sh [-v|--verbose] [--log-file <path>] [--offline] [--offline-bundle <dir>] [--offline-archive <file>] [--bundle-deps <dir>] [--bundle-deps-archive <file>] [--build-deb <path|dir>] [--self-test]"
      exit 1
      ;;
  esac
done
diag() { if [ "$VERBOSE" = "yes" ]; then echo "$@" >&2; fi; }

# ─── Operation logging ────────────────────────────────────────────────────────
LOG_FD=""
log_open() {
  local log_dir="/var/log"
  if [ ! -w "$log_dir" ] && [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; then
    log_dir="${HOME}/.adc-logs"
    mkdir -p "$log_dir" 2>/dev/null || true
  fi
  LOG_FILE="${LOG_FILE:-${log_dir}/adc-$(date +%Y%m%d-%H%M%S)-${OP:-unknown}.log}"
  LOG_FD=$(mktemp -u "${LOG_FILE}.XXXXXX")
  mv "${LOG_FD}" "${LOG_FILE%.log}.tmp" 2>/dev/null || true
  LOG_FD="$(dirname "$LOG_FILE")/$(basename "${LOG_FILE%.log}").log"
  : > "$LOG_FD" 2>/dev/null || {
    echo "WARN: Could not create log file: $LOG_FD" >&2
    return 1
  }
}

_log() {
  local msg="$1"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $msg" | tee -a "$LOG_FD" 2>/dev/null || echo "[$ts] $msg" >&2
}

log_close() {
  [ -n "$LOG_FD" ] && [ -f "$LOG_FD" ] && {
    echo "" >&2
    _log "=== Operation complete ==="
    if [ -n "$LOG_FD" ]; then
      local sz
      sz=$(stat -c %s "$LOG_FD" 2>/dev/null || echo "?")
      echo "  Log: $LOG_FD ($(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B"))"
    fi
  }
}

log_msg() { echo "$@" >&2; _log "$*"; }

ui_read() {
  local prompt="" varname="" default="" use_readline=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -p) prompt="${2:-}"; shift 2 ;;
      -i) default="${2:-}"; shift 2 ;;
      -e) use_readline=1; shift ;;
      -r) shift ;;
      # Support combined read flags used throughout script, e.g. -rp / -erp.
      -*)
        local _opt="$1"
        if [[ "$_opt" == *e* ]]; then use_readline=1; fi
        if [[ "$_opt" == *p* ]]; then
          prompt="${2:-}"
          shift 2
        else
          shift
        fi
        ;;
      --) shift; break ;;
      *) varname="$1"; shift ;;
    esac
  done
  [ -n "$varname" ] || return 1

  # Non-tty reads (e.g. here-strings) must use builtin read.
  if [ "$UI_MODE" != "1" ] || ! [ -t 0 ] || ! command -v whiptail >/dev/null 2>&1; then
    builtin read -r -p "$prompt" "$varname"
    return $?
  fi

  local input=""
  if [ -z "$prompt" ]; then
    prompt="Enter value:"
  fi

  # Adapt dialog size to current terminal to avoid clipped rendering.
  local term_h term_w box_h box_w
  term_h=$(tput lines 2>/dev/null || echo 24)
  term_w=$(tput cols 2>/dev/null || echo 80)
  box_h=$((term_h - 4))
  box_w=$((term_w - 4))
  [ "$box_h" -lt 10 ] && box_h=10
  [ "$box_w" -lt 50 ] && box_w=50
  [ "$box_h" -gt 20 ] && box_h=20
  [ "$box_w" -gt 100 ] && box_w=100

  local ui_title="Advanced Disk Cloner"
  local ui_backtitle="Safe Clone • Archive • Restore"

  # Convert classic yes/no prompts into real yes/no dialogs.
  if [[ "$prompt" =~ \([Yy]/[Nn]\)|\([Yy]/[Nn]\):|\(y/N\)|\(Y/N\)|Proceed|confirm ]]; then
    if whiptail --backtitle "$ui_backtitle" --title "$ui_title" --yesno "$prompt" "$box_h" "$box_w"; then
      input="y"
    else
      input="n"
    fi
  else
    input=$(whiptail --backtitle "$ui_backtitle" --title "$ui_title" --inputbox "$prompt" "$box_h" "$box_w" "$default" 3>&1 1>&2 2>&3) || return 1
  fi

  printf -v "$varname" '%s' "$input"
  return 0
}

# Override read only in UI mode to keep existing flow.
read() {
  if [ "$UI_MODE" = "1" ]; then
    ui_read "$@"
  else
    builtin read "$@"
  fi
}

ui_msg_box() {
  local title="$1" msg="$2"
  if [ "$UI_MODE" = "1" ] && [ -t 0 ] && command -v whiptail >/dev/null 2>&1; then
    whiptail --backtitle "Safe Clone - Archive - Restore" --title "$title" --msgbox "$msg" 12 80 || true
  fi
}

ui_warn() {
  echo "WARNING: $*" >&2
  ui_msg_box "Warning" "$*"
}

ui_error() {
  echo "ERROR: $*" >&2
  ui_msg_box "Error" "$*"
}

ui_pick_disk_index() {
  local title="$1" prompt="$2"
  if [ "$UI_MODE" != "1" ] || ! command -v whiptail >/dev/null 2>&1; then
    return 1
  fi
  local menu_args=()
  local i name size model ptt media conn
  for i in "${!DISKS[@]}"; do
    name="${DISKS[$i]}"
    size=$(lsblk -dn -o SIZE "/dev/$name" 2>/dev/null || echo "?")
    model=$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null | sed 's/^ *$/(unknown)/')
    media=$(disk_media_type "/dev/$name")
    conn=$(disk_conn_type "/dev/$name")
    ptt=$(lsblk -dn -o PTTYPE "/dev/$name" 2>/dev/null || echo "?")
    menu_args+=("$((i+1))" "/dev/$name  size=$size  media=$media  conn=$conn  model=$model  pttype=${ptt:-?}")
  done
  local choice
  choice=$(whiptail --backtitle "Safe Clone • Archive • Restore" --title "$title" --menu "$prompt" 22 110 14 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 1
  echo "$choice"
}

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
quiet_stderr() { if [ "$VERBOSE" = "no" ]; then "$@" 2>/dev/null; else "$@"; fi; }

# Convert partition size string (e.g. "222.5G") to bytes
psize_to_bytes() {
  local s="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --from=iec "$s" 2>/dev/null || echo 0
  else
    case "$s" in
      *T*|[tT]) echo $(( $(echo "$s" | tr -d 'TtGGMmkKbB ') * 1024 * 1024 * 1024 * 1024 )) ;;
      *G*|[gG]) echo $(( $(echo "$s" | tr -d 'TtGGMmkKbB ') * 1024 * 1024 * 1024 )) ;;
      *M*|[mM]) echo $(( $(echo "$s" | tr -d 'TtGGMmkKbB ') * 1024 * 1024 )) ;;
      *K*|[kK]) echo $(( $(echo "$s" | tr -d 'TtGGMmkKbB ') * 1024 )) ;;
      *)        echo "$s" 2>/dev/null || echo 0 ;;
    esac
  fi
}

# Performance tuning defaults (auto-detected; no runtime params required)
THREADS=$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)
HAS_ZSTD=no; command -v zstd >/dev/null 2>&1 && HAS_ZSTD=yes || true
HAS_PIGZ=no; command -v pigz >/dev/null 2>&1 && HAS_PIGZ=yes || true

# Compression strategy (optimized): prefer zstd (better ratio/speed), fallback to pigz, then gzip
if [ "$HAS_ZSTD" = "yes" ]; then
  # zstd -3: 10-15% better compression than -1, minimal speed loss on modern CPUs
  TAR_COMP_FLAG=( -I "zstd -T${THREADS} -3" )
  TAR_DECOMP_FLAG=( -I "zstd -T${THREADS} -d" )
  PART_EXT="zst"
elif [ "$HAS_PIGZ" = "yes" ]; then
  # pigz -3: better compression with good speed
  TAR_COMP_FLAG=( -I "pigz -3 -p ${THREADS}" )
  TAR_DECOMP_FLAG=( -I "pigz -d -p ${THREADS}" )
  PART_EXT="gz"
else
  # gzip -3: better than -1, still reasonably fast
  TAR_COMP_FLAG=()
  TAR_DECOMP_FLAG=()
  PART_EXT="gz"
fi

# I/O priority: array form to avoid word-splitting issues with string-based expansion
IONICE=()
if command -v ionice >/dev/null 2>&1; then IONICE=(ionice -c2 -n0); fi

# Optional: increase readahead for block devices we touch; restored on exit
ORIG_RA_FILE=""; ORIG_RA_DST=""; ORIG_RA_SRC="";
set_readahead() {
  local dev="$1" val="$2"
  local ra_file="/sys/block/$(basename "$dev")/queue/read_ahead_kb"
  if [ -w "$ra_file" ]; then
    echo "$val" > "$ra_file" 2>/dev/null || true
  fi
}
restore_readahead() {
  [ -n "$ORIG_RA_SRC" ] && set_readahead "${SRC}" "$ORIG_RA_SRC" || true
  [ -n "$ORIG_RA_DST" ] && [ -n "${DST:-}" ] && set_readahead "${DST}" "$ORIG_RA_DST" || true
  return 0
}
trap 'restore_readahead' EXIT INT TERM HUP

get_readahead() {
  local dev="$1"; local ra_file="/sys/block/$(basename "$dev")/queue/read_ahead_kb"
  if [ -r "$ra_file" ]; then cat "$ra_file" 2>/dev/null || true; fi
}

get_device_size_bytes() {
  local dev="$1"
  local size=""

  # Preferred method
  size=$(blockdev --getsize64 "$dev" 2>/dev/null || true)
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ]; then
    echo "$size"
    return 0
  fi

  # Fallback 1: lsblk byte size
  size=$(lsblk -bdno SIZE "$dev" 2>/dev/null || true)
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ]; then
    echo "$size"
    return 0
  fi

  # Fallback 2: sysfs sectors * 512
  local bname sectors_file sectors
  bname=$(basename "$dev")
  sectors_file="/sys/class/block/${bname}/size"
  sectors=$(cat "$sectors_file" 2>/dev/null || true)
  if [[ "$sectors" =~ ^[0-9]+$ ]] && [ "$sectors" -gt 0 ]; then
    echo $((sectors * 512))
    return 0
  fi

  echo "0"
  return 1
}

grow_btrfs_partition() {
  local dev="$1"
  command -v btrfs >/dev/null 2>&1 || { echo "btrfs tool not available; skipped filesystem grow."; return 1; }
  local tmp_mnt
  tmp_mnt=$(mktemp -d)
  # Try common mount variants for restored systems.
  if mount "$dev" "$tmp_mnt" 2>/dev/null || \
     mount -o rw "$dev" "$tmp_mnt" 2>/dev/null || \
     mount -o rw,subvolid=5 "$dev" "$tmp_mnt" 2>/dev/null; then
    btrfs filesystem resize max "$tmp_mnt" || true
    umount "$tmp_mnt" 2>/dev/null || true
    rmdir "$tmp_mnt" 2>/dev/null || true
    return 0
  fi
  rmdir "$tmp_mnt" 2>/dev/null || true
  echo "Could not mount $dev for btrfs resize; skipped filesystem grow."
  return 1
}

# ============================================================================
# Helper functions for partition archive and restore
# ============================================================================

# dd_compress: run a pipeline of "command | compress > output" with proper error handling.
#   $1 = command to run (e.g. "partclone.extfs -c -s /dev/sda1 -o -")
#   $2 = compression flag (zst|gz|none)
#   $3 = whether partition is mounted (yes|no) — used to pick dd fallback
#   $4 = device path (for dd fallback)
#   $5 = output base path (without extension)
#   $6 = filesystem type label (for diag messages)
#   $7 = manifest tool name (for logging)
dd_compress() {
  local cmd="$1" comp_flag="$2" mounted="$3" dev="$4" outbase="$5" fst_label="$6" manifest_tool="$7"
  local outfile=""
  local rc=1
  local status_entry="${manifest_tool}"
  local tmpstatus
  tmpstatus=$(mktemp)

  if [ "$comp_flag" = "zst" ]; then
    outfile="${outbase}.pc.zst"
    (
      set -euo pipefail
      if [ "$mounted" = "no" ]; then
        { $cmd 2>/dev/null | { [ "$VERBOSE" = "yes" ] && cat 2>&1 || true; } | cat >/dev/null; } 2>&1 | {
          if command -v pv >/dev/null 2>&1; then
            ${IONICE[@]+"${IONICE[@]}"} pv | ${IONICE[@]+"${IONICE[@]}"} zstd -T"${THREADS}" -3 > "$outfile"
          else
            ${IONICE[@]+"${IONICE[@]}"} zstd -T"${THREADS}" -3 > "$outfile"
          fi
        }
      else
        if command -v pv >/dev/null 2>&1; then
          ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | ${IONICE[@]+"${IONICE[@]}"} pv | ${IONICE[@]+"${IONICE[@]}"} zstd -T"${THREADS}" -3 > "$outfile"
        else
          ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | ${IONICE[@]+"${IONICE[@]}"} zstd -T"${THREADS}" -3 > "$outfile"
        fi
      fi
    ); rc=$?
  elif [ "$comp_flag" = "gz" ]; then
    if command -v pigz >/dev/null 2>&1; then
      outfile="${outbase}.pc.gz"
      (
        set -euo pipefail
        if [ "$mounted" = "no" ]; then
          { $cmd 2>/dev/null | { [ "$VERBOSE" = "yes" ] && cat 2>&1 || true; } | cat >/dev/null; } 2>&1 | {
            ${IONICE[@]+"${IONICE[@]}"} pv | ${IONICE[@]+"${IONICE[@]}"} pigz -3 -p"${THREADS}" > "$outfile" 2>/dev/null
          }
        else
          if command -v pv >/dev/null 2>&1; then
            ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | ${IONICE[@]+"${IONICE[@]}"} pv | ${IONICE[@]+"${IONICE[@]}"} pigz -3 -p"${THREADS}" > "$outfile"
          else
            ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | ${IONICE[@]+"${IONICE[@]}"} pigz -3 -p"${THREADS}" > "$outfile"
          fi
        fi
      ); rc=$?
    else
      outfile="${outbase}.pc.gz"
      (
        set -euo pipefail
        if [ "$mounted" = "no" ]; then
          { $cmd 2>/dev/null | { [ "$VERBOSE" = "yes" ] && cat 2>&1 || true; } | cat >/dev/null; } 2>&1 | {
            ${IONICE[@]+"${IONICE[@]}"} pv | gzip -3 > "$outfile" 2>/dev/null
          }
        else
          if command -v pv >/dev/null 2>&1; then
            ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | ${IONICE[@]+"${IONICE[@]}"} pv | gzip -3 > "$outfile"
          else
            ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | gzip -3 > "$outfile"
          fi
        fi
      ); rc=$?
    fi
  else
    # none: raw dd fallback
    outfile="${outbase}.raw.gz"
    (
      set -euo pipefail
      if command -v pigz >/dev/null 2>&1; then
        if command -v pv >/dev/null 2>&1; then
          ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | ${IONICE[@]+"${IONICE[@]}"} pv | ${IONICE[@]+"${IONICE[@]}"} pigz -3 -p"${THREADS}" > "$outfile"
        else
          ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | ${IONICE[@]+"${IONICE[@]}"} pigz -3 -p"${THREADS}" > "$outfile"
        fi
      else
        if command -v pv >/dev/null 2>&1; then
          ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | ${IONICE[@]+"${IONICE[@]}"} pv | gzip -3 > "$outfile"
        else
          ${IONICE[@]+"${IONICE[@]}"} dd if="$dev" bs=16M status=none | gzip -3 > "$outfile"
        fi
      fi
    ); rc=$?
  fi

  if [ $rc -eq 0 ] && [ -s "$outfile" ]; then
    local sz
    sz=$(stat -c %s "$outfile" 2>/dev/null || echo 0)
    echo -e "$PNAME\t${manifest_tool}\tOK\t${sz}" >> "$STATUS_LOG"
    diag "[ARCH] Done: $PNAME via ${manifest_tool} (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))"
  else
    echo -e "$PNAME\t${manifest_tool}\tFAIL\t0" >> "$STATUS_LOG"
    echo "[ARCH] FAIL: $PNAME via ${manifest_tool} (rc=$rc)" >&2
  fi
  rm -f "$tmpstatus"
  return $rc
}

# dd_decompress: run "decompress | dd of=target" with proper error handling.
#   $1 = compression flag (zst|gz|none)
#   $2 = image file path
#   $3 = target device
dd_decompress() {
  local comp_flag="$1" imgfile="$2" tgtdev="$3"
  local rc=0

  if [ -n "$imgfile" ] && [ -f "$imgfile" ]; then
    if [ "$comp_flag" = "zst" ] && command -v zstd >/dev/null 2>&1; then
      if command -v pv >/dev/null 2>&1; then
        ${IONICE[@]+"${IONICE[@]}"} zstd -dc -T"${THREADS}" "$imgfile" | pv | ${IONICE[@]+"${IONICE[@]}"} dd of="$tgtdev" bs=1M conv=fsync status=none || rc=$?
      else
        ${IONICE[@]+"${IONICE[@]}"} zstd -dc -T"${THREADS}" "$imgfile" | ${IONICE[@]+"${IONICE[@]}"} dd of="$tgtdev" bs=1M conv=fsync status=progress || rc=$?
      fi
    elif [ "$comp_flag" = "gz" ]; then
      if command -v pigz >/dev/null 2>&1; then
        if command -v pv >/dev/null 2>&1; then
          ${IONICE[@]+"${IONICE[@]}"} pigz -dc "$imgfile" | pv | ${IONICE[@]+"${IONICE[@]}"} dd of="$tgtdev" bs=1M conv=fsync status=none || rc=$?
        else
          ${IONICE[@]+"${IONICE[@]}"} pigz -dc "$imgfile" | ${IONICE[@]+"${IONICE[@]}"} dd of="$tgtdev" bs=1M conv=fsync status=progress || rc=$?
        fi
      elif command -v gzip >/dev/null 2>&1; then
        if command -v pv >/dev/null 2>&1; then
          ${IONICE[@]+"${IONICE[@]}"} gzip -dc "$imgfile" | pv | ${IONICE[@]+"${IONICE[@]}"} dd of="$tgtdev" bs=1M conv=fsync status=none || rc=$?
        else
          ${IONICE[@]+"${IONICE[@]}"} gzip -dc "$imgfile" | ${IONICE[@]+"${IONICE[@]}"} dd of="$tgtdev" bs=1M conv=fsync status=progress || rc=$?
        fi
      fi
    else
      # raw uncompressed
      # Validate comp_flag — empty or unrecognized means we can't safely proceed
      if [ -z "$comp_flag" ]; then
        echo "ERROR: cannot determine compression for $imgfile — comp_flag is empty" >&2
        rc=1
      else
        if command -v pv >/dev/null 2>&1; then
          ${IONICE[@]+"${IONICE[@]}"} pv "$imgfile" | ${IONICE[@]+"${IONICE[@]}"} dd of="$tgtdev" bs=1M conv=fsync status=none || rc=$?
        else
          ${IONICE[@]+"${IONICE[@]}"} dd if="$imgfile" of="$tgtdev" bs=1M conv=fsync status=progress || rc=$?
        fi
      fi
    fi
  fi
  return $rc
}

# ============================================================================
# Partition archive function — replaces the duplicated ext4/btrfs/ntfs/dd blocks
# ============================================================================
archive_partition() {
  local dev="$1" fstype="$2" outbase="$3" pnum="$4"
  PNAME="$pnum"  # For logging consistency
  local mounted_at is_mounted
  mounted_at=$(findmnt -no TARGET "$dev" 2>/dev/null || true)
  if [ -n "$mounted_at" ]; then
    is_mounted="yes"
  else
    is_mounted="no"
  fi

  case "$fstype" in
    ext4)
      if command -v partclone.extfs >/dev/null 2>&1 && [ "$is_mounted" = "no" ]; then
        echo -e "$PNAME\text4\tpartclone" >> "$MANIFEST"
        dd_compress 'partclone.extfs -c -s '"$dev"' -o -' "zst" "$is_mounted" "$dev" "$outbase" "ext4" "partclone" && return 0
        # Retry with gzip if zst failed
        dd_compress 'partclone.extfs -c -s '"$dev"' -o -' "gz" "$is_mounted" "$dev" "$outbase" "ext4" "partclone" && return 0
        # Fallback to dd
        echo -e "$PNAME\text4\tdd" >> "$MANIFEST"
        dd_compress "" "none" "$is_mounted" "$dev" "$outbase" "ext4" "dd" && return 0
      else
        echo -e "$PNAME\text4\tdd" >> "$MANIFEST"
        dd_compress "" "none" "$is_mounted" "$dev" "$outbase" "ext4" "dd" && return 0
      fi
      ;;
    btrfs)
      if command -v partclone.btrfs >/dev/null 2>&1 && [ "$is_mounted" = "no" ]; then
        echo -e "$PNAME\tbtrfs\tpartclone" >> "$MANIFEST"
        dd_compress 'partclone.btrfs -c -s '"$dev"' -o -' "zst" "$is_mounted" "$dev" "$outbase" "btrfs" "partclone" && return 0
        dd_compress 'partclone.btrfs -c -s '"$dev"' -o -' "gz" "$is_mounted" "$dev" "$outbase" "btrfs" "partclone" && return 0
        echo -e "$PNAME\tbtrfs\tdd" >> "$MANIFEST"
        dd_compress "" "none" "$is_mounted" "$dev" "$outbase" "btrfs" "dd" && return 0
      else
        echo -e "$PNAME\tbtrfs\tdd" >> "$MANIFEST"
        dd_compress "" "none" "$is_mounted" "$dev" "$outbase" "btrfs" "dd" && return 0
      fi
      ;;
    ntfs)
      if command -v ntfsclone >/dev/null 2>&1; then
        echo -e "$PNAME\tntfs\tntfsclone" >> "$MANIFEST"
        dd_compress "ntfsclone --save-image --output - $dev" "zst" "no" "$dev" "$outbase" "ntfs" "ntfsclone" && return 0
        dd_compress "ntfsclone --save-image --output - $dev" "gz" "no" "$dev" "$outbase" "ntfs" "ntfsclone" && return 0
        echo -e "$PNAME\tntfs\tdd" >> "$MANIFEST"
        dd_compress "" "none" "$is_mounted" "$dev" "$outbase" "ntfs" "dd" && return 0
      else
        echo -e "$PNAME\tntfs\tdd" >> "$MANIFEST"
        dd_compress "" "none" "$is_mounted" "$dev" "$outbase" "ntfs" "dd" && return 0
      fi
      ;;
    *)
      echo -e "$PNAME\t${fstype:-unknown}\tdd" >> "$MANIFEST"
      dd_compress "" "none" "$is_mounted" "$dev" "$outbase" "${fstype:-unknown}" "dd" && return 0
      ;;
  esac
  return 1
}

# ============================================================================
# Partition restore function — replaces the duplicated restore blocks
# ============================================================================
restore_partition() {
  local fstype="$1" tool="$2" base="$3" tgtdev="$4"
  local rc=0

  case "$tool" in
    partclone)
      if [ "$fstype" = "btrfs" ]; then
        command -v partclone.btrfs >/dev/null 2>&1 || { echo "WARN: missing partclone.btrfs tool for $tgtdev"; return 1; }
        if [ -f "${base}.pc.zst" ] && command -v zstd >/dev/null 2>&1; then
          zstd -dc -T"${THREADS}" "${base}.pc.zst" | partclone.btrfs -r -o "$tgtdev" -s - || rc=$?
        elif [ -f "${base}.pc.gz" ]; then
          if command -v pigz >/dev/null 2>&1; then
            pigz -dc "${base}.pc.gz" | partclone.btrfs -r -o "$tgtdev" -s - || rc=$?
          else
            gzip -dc "${base}.pc.gz" | partclone.btrfs -r -o "$tgtdev" -s - || rc=$?
          fi
        else
          echo "WARN: missing partclone.btrfs image for $tgtdev"; return 1
        fi
      elif command -v partclone.extfs >/dev/null 2>&1; then
        if [ -f "${base}.pc.zst" ] && command -v zstd >/dev/null 2>&1; then
          zstd -dc -T"${THREADS}" "${base}.pc.zst" | partclone.extfs -r -o "$tgtdev" -s - || rc=$?
        elif [ -f "${base}.pc.gz" ]; then
          if command -v pigz >/dev/null 2>&1; then
            pigz -dc "${base}.pc.gz" | partclone.extfs -r -o "$tgtdev" -s - || rc=$?
          else
            gzip -dc "${base}.pc.gz" | partclone.extfs -r -o "$tgtdev" -s - || rc=$?
          fi
        else
          echo "WARN: missing partclone image or tool for $tgtdev"; return 1
        fi
      else
        echo "WARN: missing partclone.extfs tool for $tgtdev"; return 1
      fi
      ;;
    ntfsclone)
      if [ -f "${base}.ntfs.zst" ] && command -v zstd >/dev/null 2>&1; then
        zstd -dc -T"${THREADS}" "${base}.ntfs.zst" | ntfsclone --restore-image --overwrite "$tgtdev" - || rc=$?
      elif [ -f "${base}.ntfs.gz" ]; then
        if command -v pigz >/dev/null 2>&1; then
          pigz -dc "${base}.ntfs.gz" | ntfsclone --restore-image --overwrite "$tgtdev" - || rc=$?
        else
          gzip -dc "${base}.ntfs.gz" | ntfsclone --restore-image --overwrite "$tgtdev" - || rc=$?
        fi
      else
        echo "WARN: missing ntfsclone image or tool for $tgtdev"; return 1
      fi
      ;;
    dd)
      # NOTE: dd_compress with comp_flag="none" always creates ${outbase}.raw.gz
      # (line ~442). comp_flag="none" means "no partclone/ntfsclone" — the output
      # is still compressed (raw dd | gzip/zstd). restore_partition must look for
      # the same .raw.{gz,zst} naming pattern.
      local imgfile=""
      if [ -f "${base}.raw.zst" ]; then
        imgfile="${base}.raw.zst"
      elif [ -f "${base}.raw.gz" ]; then
        imgfile="${base}.raw.gz"
      elif [ -f "${base}.raw" ]; then
        imgfile="${base}.raw"
      else
        echo "WARN: missing raw image for $tgtdev"; return 1
      fi
      local comp_flag="none"
      [[ "$imgfile" == *.zst ]] && comp_flag="zst"
      [[ "$imgfile" == *.gz ]] && comp_flag="gz"
      dd_decompress "$comp_flag" "$imgfile" "$tgtdev" || return 1
      ;;
    *)
      echo "WARN: unknown restore tool '$tool' for $tgtdev"; return 1
      ;;
  esac
  return $rc
}

list_mounted_real_partitions() {
  local src tgt pk pkdev found
  found=0
  while read -r src tgt; do
    [[ "$src" == /dev/* ]] || continue
    [ -b "$src" ] || continue
    pk=$(lsblk -no PKNAME "$src" 2>/dev/null || true)
    case "$pk" in
      sd[a-z]*|nvme[0-9]*n[0-9]*) ;;
      *) continue ;;
    esac
    pkdev="/dev/$pk"
    [ -b "$pkdev" ] || continue
    printf '%s\t%s\n' "$(basename "$src")" "$tgt"
    found=1
  done < <(findmnt -rn --raw -o SOURCE,TARGET 2>/dev/null || true)

  # Fallback path: if findmnt yielded nothing, use lsblk discovery.
  if [ "$found" -eq 0 ]; then
    lsblk -ln -o NAME,TYPE,MOUNTPOINT,PKNAME 2>/dev/null | \
      awk '$2=="part" && $3!="" && ($4 ~ /^sd[a-z]+$/ || $4 ~ /^nvme[0-9]+n[0-9]+$/) {print $1"\t"$3}'
  fi
}

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }

# Self-test mode: validate environment and exit
if [ "$SELF_TEST" = "yes" ]; then
  echo "=== Self-test ==="
  # shellcheck disable=SC1091
  echo "OS: $(. /etc/os-release 2>/dev/null || true; echo "${NAME:-unknown}")"
  echo "User: $(id -un) (EUID=${EUID:-$(id -u)})"
  echo "Checking commands..."
  for cmd in dd sfdisk gzip tar lsblk awk pv gdisk partclone.extfs partclone.btrfs ntfsclone tune2fs e2fsck resize2fs btrfs pigz; do
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

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  # KDE/Cachy desktop launch support: re-exec with pkexec when no tty.
  if ! [ -t 0 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v pkexec >/dev/null 2>&1; then
    exec pkexec env ADC_UI="${UI_MODE}" bash "$(readlink -f "$0")" "${ORIGINAL_ARGS[@]}"
  fi
  ui_error "This script must run as root. Please run: sudo ./clone_minimal.sh"
  exit 1
fi

# --- Auto-install prerequisites (best effort) ---
echo "=== Advanced Disk Cloner ==="
echo "Checking prerequisites..."

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
run_root() { if is_root; then "$@"; else sudo "$@"; fi; }

# If run via sudo, return created files to the invoking user.
fix_owner_if_sudo() {
  local target="$1"
  if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" "$target" 2>/dev/null || true
  fi
  return 0
}

# All Ubuntu packages needed for this script.
REQ_PACKAGES=(coreutils util-linux gzip tar pv gdisk partclone ntfs-3g e2fsprogs btrfs-progs pigz zstd)
# Extra packages for packaged app UX/runtime.
APP_DEB_PACKAGES=(whiptail sudo bash)

# Download prerequisite packages for offline usage and exit.
bundle_prerequisites() {
  local bundle_dir="$1"
  if ! is_ubuntu; then
    echo "ERROR: --bundle-deps is supported only on Ubuntu (apt)." >&2
    exit 1
  fi
  mkdir -p "$bundle_dir/partial"
  # Allow apt sandbox user (_apt) to access cache path cleanly, avoiding
  # "Download is performed unsandboxed as root" warnings.
  if id _apt >/dev/null 2>&1; then
    run_root chown _apt:root "$bundle_dir" "$bundle_dir/partial" 2>/dev/null || true
    run_root chmod 0755 "$bundle_dir" "$bundle_dir/partial" 2>/dev/null || true
  fi
  export DEBIAN_FRONTEND=noninteractive
  echo "Preparing offline package bundle in: $bundle_dir"
  run_root bash -lc 'cache_dir="$1"; shift; apt-get update -y && apt-get install -y --download-only --reinstall -o Dir::Cache::archives="$cache_dir" "$@"' _ "$bundle_dir" "${REQ_PACKAGES[@]}"
  mapfile -t bundle_debs < <(ls "$bundle_dir"/*.deb 2>/dev/null || true)
  if [ ${#bundle_debs[@]} -eq 0 ]; then
    echo "ERROR: No .deb packages were downloaded into: $bundle_dir" >&2
    echo "Try again on a machine with internet connectivity and valid Ubuntu apt sources." >&2
    exit 1
  fi
  fix_owner_if_sudo "$bundle_dir"
  echo "Bundle ready. Copy this folder to the offline machine and run:"
  echo "  sudo ./clone_minimal.sh --offline-bundle \"$bundle_dir\""
}

# Build a single archive that contains all required .deb packages.
bundle_prerequisites_archive() {
  local archive_input="$1"
  local archive_path="$archive_input"
  local archive_dir=""
  if [ -d "$archive_input" ] || [[ "$archive_input" == */ ]]; then
    archive_dir="${archive_input%/}"
    mkdir -p "$archive_dir"
    archive_path="${archive_dir}/adc-offline-pkgs-$(date +%Y%m%d-%H%M%S).tar.gz"
  else
    archive_dir=$(dirname "$archive_path")
    mkdir -p "$archive_dir"
    if [[ "$archive_path" != *.tar.gz ]]; then
      archive_path="${archive_path}.tar.gz"
    fi
  fi
  local tmp_bundle
  tmp_bundle=$(mktemp -d)
  bundle_prerequisites "$tmp_bundle"
  printf '%s\n' "${REQ_PACKAGES[@]}" > "$tmp_bundle/adc-required-packages.txt"
  tar -czf "$archive_path" -C "$tmp_bundle" .
  rm -rf "$tmp_bundle"
  fix_owner_if_sudo "$archive_path"
  echo "Offline package archive created: $archive_path"
  echo "Use it on fresh/offline system with:"
  echo "  sudo ./clone_minimal.sh --offline-archive \"$archive_path\""
}

# Build a Debian package containing this app and a friendly launcher UI.
build_deb_package() {
  local target_input="$1"
  local deb_output="$target_input"
  local out_dir=""
  local pkg_name="advanced-disk-cloner"
  local version
  version="$(date +%Y.%m.%d.%H%M)"

  if [ -d "$target_input" ] || [[ "$target_input" == */ ]]; then
    out_dir="${target_input%/}"
    mkdir -p "$out_dir"
    deb_output="${out_dir}/${pkg_name}_${version}_all.deb"
  else
    out_dir=$(dirname "$deb_output")
    mkdir -p "$out_dir"
    if [[ "$deb_output" != *.deb ]]; then
      deb_output="${deb_output}.deb"
    fi
  fi

  command -v dpkg-deb >/dev/null 2>&1 || {
    echo "ERROR: dpkg-deb is required to build a .deb package." >&2
    echo "Install with: sudo apt-get install -y dpkg-dev" >&2
    exit 1
  }

  local pkg_root
  pkg_root=$(mktemp -d)
  local dep_bundle
  dep_bundle=$(mktemp -d)
  local script_src
  script_src=$(readlink -f "$0")

  mkdir -p "$pkg_root/DEBIAN" "$pkg_root/opt/advanced-disk-cloner" "$pkg_root/opt/advanced-disk-cloner/offline-debs" "$pkg_root/usr/local/bin"

  echo "Embedding offline dependency packages into .deb (this can take a while)..."
  bundle_prerequisites "$dep_bundle"
  run_root bash -lc 'cache_dir="$1"; shift; apt-get install -y --download-only --reinstall -o Dir::Cache::archives="$cache_dir" "$@"' _ "$dep_bundle" "${APP_DEB_PACKAGES[@]}"
  mapfile -t embedded_debs < <(ls "$dep_bundle"/*.deb 2>/dev/null || true)
  if [ ${#embedded_debs[@]} -eq 0 ]; then
    echo "ERROR: Could not download dependency packages for all-in-one installer." >&2
    rm -rf "$pkg_root" "$dep_bundle"
    exit 1
  fi
  cp -f "$dep_bundle"/*.deb "$pkg_root/opt/advanced-disk-cloner/offline-debs/"
  printf '%s\n' "${REQ_PACKAGES[@]}" "${APP_DEB_PACKAGES[@]}" | awk 'NF{if(!seen[$0]++) print $0}' > "$pkg_root/opt/advanced-disk-cloner/offline-debs/required-packages.txt"

  cp -f "$script_src" "$pkg_root/opt/advanced-disk-cloner/clone_minimal.sh"
  chmod 0755 "$pkg_root/opt/advanced-disk-cloner/clone_minimal.sh"

  cat > "$pkg_root/usr/local/bin/advanced-disk-cloner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP="/opt/advanced-disk-cloner/clone_minimal.sh"
OFFLINE_DEBS="/opt/advanced-disk-cloner/offline-debs"
TITLE="Advanced Disk Cloner"
BACKTITLE="Safe Clone - Archive - Restore"
[ -x "$APP" ] || { echo "Backend script not found: $APP"; exit 1; }

# Install embedded dependencies outside dpkg postinst context.
ensure_embedded_deps() {
  [ -d "$OFFLINE_DEBS" ] || return 0
  mapfile -t _debs < <(ls "$OFFLINE_DEBS"/*.deb 2>/dev/null || true)
  [ ${#_debs[@]} -gt 0 ] || return 0
  if [ -f "$OFFLINE_DEBS/required-packages.txt" ]; then
    mapfile -t _pkgs < "$OFFLINE_DEBS/required-packages.txt"
    if [ "${#_pkgs[@]}" -gt 0 ]; then
      sudo bash -lc 'deb_dir="$1"; shift; cp -f "$deb_dir"/*.deb /var/cache/apt/archives/ && apt-get install -y --no-download "$@"' _ "$OFFLINE_DEBS" "${_pkgs[@]}" || true
    fi
  fi
}

# Ensure embedded dependencies are present before UI checks.
ensure_embedded_deps

if ! command -v whiptail >/dev/null 2>&1; then
  echo "Friendly UI requires whiptail. Falling back to CLI..."
  exec sudo "$APP"
fi

whiptail --backtitle "$BACKTITLE" --title "$TITLE" --msgbox "Welcome.\n\nUse arrow keys to navigate, Enter to select, and Tab to switch buttons." 12 72

while true; do
  CHOICE=$(whiptail --backtitle "$BACKTITLE" --title "$TITLE" --menu "Choose an action" 20 78 10 \
    "1" "Start Cloner (guided)" \
    "2" "Start Cloner (verbose diagnostics)" \
    "3" "Run self-test" \
    "4" "Create Offline Package Archive" \
    "5" "Show help" \
    "6" "Exit" \
    3>&1 1>&2 2>&3) || exit 0

  case "$CHOICE" in
    1) sudo ADC_UI=1 "$APP" --ui ;;
    2) sudo ADC_UI=1 "$APP" --ui -v ;;
    3) sudo "$APP" --self-test | whiptail --backtitle "$BACKTITLE" --title "Self-test Output" --scrolltext --textbox /dev/stdin 25 100 ;;
    4)
      OUT=$(whiptail --backtitle "$BACKTITLE" --title "$TITLE" --inputbox "Output directory for archive (e.g. /tmp or /home/user)" 10 78 "./" 3>&1 1>&2 2>&3) || continue
      whiptail --backtitle "$BACKTITLE" --title "$TITLE" --infobox "Creating offline archive...\nThis may take a while." 8 60
      sudo "$APP" --bundle-deps-archive "$OUT"
      whiptail --backtitle "$BACKTITLE" --title "$TITLE" --msgbox "Offline archive creation completed." 9 60
      ;;
    5)
      "$APP" --help | whiptail --backtitle "$BACKTITLE" --title "Help" --scrolltext --textbox /dev/stdin 30 100
      ;;
    6) exit 0 ;;
  esac
done
EOF
  chmod 0755 "$pkg_root/usr/local/bin/advanced-disk-cloner"

  cat > "$pkg_root/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "advanced-disk-cloner installed."
echo "Embedded offline dependencies will be installed automatically on first launch."

exit 0
EOF
  chmod 0755 "$pkg_root/DEBIAN/postinst"

  cat > "$pkg_root/DEBIAN/control" <<EOF
Package: ${pkg_name}
Version: ${version}
Section: utils
Priority: optional
Architecture: all
Maintainer: ${USER:-adc} <${USER:-adc}@local>
Depends: dpkg, apt
Description: Advanced Disk Cloner with all-in-one offline installer
 Menu-driven disk cloner/archiver/restorer with offline dependency
 archive generation, embedded runtime packages, and a friendly launcher UI.
EOF

  dpkg-deb --build "$pkg_root" "$deb_output" >/dev/null
  rm -rf "$pkg_root" "$dep_bundle"
  fix_owner_if_sudo "$deb_output"
  echo "Debian package created: $deb_output"
  echo "Install with: sudo dpkg -i \"$deb_output\""
  echo "Run UI with: advanced-disk-cloner"
}

# Extract archive into a temporary bundle directory.
extract_bundle_archive() {
  local archive_path="$1"
  [ -f "$archive_path" ] || { echo "ERROR: Offline archive not found: $archive_path" >&2; exit 1; }
  local tmp_bundle
  tmp_bundle=$(mktemp -d)
  tar -xf "$archive_path" -C "$tmp_bundle" || {
    echo "ERROR: Could not extract offline archive: $archive_path" >&2
    rm -rf "$tmp_bundle"
    exit 1
  }
  echo "$tmp_bundle"
}

# Install packages using a preloaded .deb bundle, no network needed.
install_from_bundle() {
  local bundle_dir="$1"; shift
  [ -d "$bundle_dir" ] || { echo "ERROR: Offline bundle directory not found: $bundle_dir" >&2; exit 1; }
  mapfile -t debs < <(ls "$bundle_dir"/*.deb 2>/dev/null || true)
  [ ${#debs[@]} -gt 0 ] || { echo "ERROR: No .deb packages found in: $bundle_dir" >&2; exit 1; }
  echo "Installing packages from offline bundle: $bundle_dir"
  run_root bash -lc 'cache_dir="$1"; shift; cp -f "$cache_dir"/*.deb /var/cache/apt/archives/ && apt-get install -y --no-download "$@"' _ "$bundle_dir" "$@" || {
    echo "ERROR: Offline install failed. Ensure bundle has all dependencies." >&2
    exit 1
  }
}

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

is_arch_like() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "arch" ] && return 0
    [ "${ID:-}" = "cachyos" ] && return 0
    case ",${ID_LIKE:-}," in *,arch,*) return 0 ;; esac
  fi
  return 1
}

install_packages() {
  if [ "$OFFLINE_MODE" = "yes" ]; then
    if [ -z "$OFFLINE_BUNDLE_DIR" ] && [ -n "$OFFLINE_BUNDLE_ARCHIVE" ]; then
      OFFLINE_BUNDLE_DIR=$(extract_bundle_archive "$OFFLINE_BUNDLE_ARCHIVE")
    fi
    if [ -z "$OFFLINE_BUNDLE_DIR" ]; then
      echo "ERROR: Offline mode requires a package source. Use --offline-bundle <dir>, --offline-archive <file>, or ADC_DEB_BUNDLE." >&2
      exit 1
    fi
    [ "$#" -gt 0 ] && install_from_bundle "$OFFLINE_BUNDLE_DIR" "$@"
    return 0
  fi
  if is_ubuntu; then
    if [ "$#" -gt 0 ]; then echo "Installing packages via apt: $*"; fi
    export DEBIAN_FRONTEND=noninteractive
    run_root bash -lc 'apt-get update -y || true; apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"' _ "$@" || true
  elif is_arch_like; then
    if [ "$#" -gt 0 ]; then echo "Installing packages via pacman: $*"; fi
    run_root pacman -Sy --noconfirm --needed "$@" || true
  else
    echo "WARN: Auto-install is supported on Ubuntu (apt) and Arch-like (pacman). Skipping." >&2
  fi
}

if [ -n "$BUNDLE_DEPS_DIR" ]; then
  bundle_prerequisites "$BUNDLE_DEPS_DIR"
  exit 0
fi

if [ -n "$BUNDLE_DEPS_ARCHIVE" ]; then
  bundle_prerequisites_archive "$BUNDLE_DEPS_ARCHIVE"
  exit 0
fi

if [ -n "$BUILD_DEB_TARGET" ]; then
  build_deb_package "$BUILD_DEB_TARGET"
  exit 0
fi

if [ "$OFFLINE_MODE" = "yes" ]; then
  echo "Offline mode enabled."
  [ -n "$OFFLINE_BUNDLE_DIR" ] && echo "Using package bundle: $OFFLINE_BUNDLE_DIR"
  [ -n "$OFFLINE_BUNDLE_ARCHIVE" ] && echo "Using package archive: $OFFLINE_BUNDLE_ARCHIVE"
fi

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
    # Map commands -> packages (Ubuntu)
    declare -A PKG_FOR_CMD=()
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
    PKG_FOR_CMD[partclone.btrfs]="partclone"
    PKG_FOR_CMD[ntfsclone]="ntfs-3g"
    PKG_FOR_CMD[tune2fs]="e2fsprogs"
    PKG_FOR_CMD[e2fsck]="e2fsprogs"
    PKG_FOR_CMD[resize2fs]="e2fsprogs"
    PKG_FOR_CMD[btrfs]="btrfs-progs"
    PKG_FOR_CMD[zstd]="zstd"

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
  elif is_arch_like; then
    # Map commands -> packages (Arch/Cachy)
    declare -A PKG_FOR_CMD=()
    PKG_FOR_CMD[dd]="coreutils"
    PKG_FOR_CMD[sfdisk]="util-linux"
    PKG_FOR_CMD[lsblk]="util-linux"
    PKG_FOR_CMD[gzip]="gzip"
    PKG_FOR_CMD[pigz]="pigz"
    PKG_FOR_CMD[tar]="tar"
    PKG_FOR_CMD[pv]="pv"
    PKG_FOR_CMD[gdisk]="gptfdisk"
    PKG_FOR_CMD[sgdisk]="gptfdisk"
    PKG_FOR_CMD[partclone.extfs]="partclone"
    PKG_FOR_CMD[partclone.btrfs]="partclone"
    PKG_FOR_CMD[ntfsclone]="ntfs-3g"
    PKG_FOR_CMD[tune2fs]="e2fsprogs"
    PKG_FOR_CMD[e2fsck]="e2fsprogs"
    PKG_FOR_CMD[resize2fs]="e2fsprogs"
    PKG_FOR_CMD[btrfs]="btrfs-progs"
    PKG_FOR_CMD[zstd]="zstd"
    PKG_FOR_CMD[awk]="gawk"

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

    post_missing=()
    for c in "$@"; do
      if ! command -v "$c" >/dev/null 2>&1; then
        post_missing+=("$c")
      fi
    done
    if [ ${#post_missing[@]} -gt 0 ]; then
      echo "ERROR: Missing required commands after pacman install attempt: ${post_missing[*]}" >&2
      echo "Please install the packages manually and re-run." >&2
      exit 1
    fi
  else
    echo "ERROR: Missing required commands on unsupported distro: ${missing_cmds[*]}" >&2
    echo "Please install manually and re-run." >&2
    exit 1
  fi
}

# Always attempt to install prerequisites on Ubuntu (non-fatal)
echo "Ensuring required commands are available..."
# Core + feature commands needed by this script
ensure_commands dd sfdisk gzip tar lsblk awk pv gdisk partclone.extfs ntfsclone tune2fs e2fsck resize2fs pigz zstd

# Ensure minimally required commands exist after best-effort install
require dd
require sfdisk
require gzip
require tar

# Report archive capabilities
HAS_PARTCLONE=no
HAS_NTFSCLONE=no
HAS_PARTCLONE_BTRFS=no
if command -v partclone.extfs >/dev/null 2>&1; then HAS_PARTCLONE=yes; fi
if command -v partclone.btrfs >/dev/null 2>&1; then HAS_PARTCLONE_BTRFS=yes; fi
if command -v ntfsclone >/dev/null 2>&1; then HAS_NTFSCLONE=yes; fi
echo "Archive mode: used-block ext4=$HAS_PARTCLONE, btrfs=$HAS_PARTCLONE_BTRFS, ntfs=$HAS_NTFSCLONE (fallback to raw for others)"
if [ "$HAS_PARTCLONE_BTRFS" = "no" ]; then
  echo "WARN: partclone.btrfs is not available. Btrfs partitions will use raw mode (slower/larger archives)." >&2
fi

# List disks using JSON parsing for robustness (handles spaces in model names).
# Reads partition-type disks only: /dev/sd[a-z] and /dev/nvme*n1
mapfile -t DISKS < <(lsblk -dn -J -o NAME,TYPE 2>/dev/null | jq -r '.blockdevices[] | select(.type=="disk") | select(.name | test("^sd[a-z]+$|^nvme[0-9]+n[0-9]+$")) | .name' | sort)

# Fallback if jq is not available
if [ ${#DISKS[@]} -eq 0 ]; then
  mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && ($1 ~ /^sd[a-z]+$/ || $1 ~ /^nvme[0-9]+n[0-9]+$/) {print $1}' | sort)
fi

if [ ${#DISKS[@]} -eq 0 ]; then
  ui_error "No supported root disks were found (/dev/sdX or /dev/nvme*n1)."
  exit 1
fi

# Detect media type: SSD or HDD (via lsblk ROTA flag)
disk_media_type() {
  local dev="$1"
  local rota
  rota=$(lsblk -dn -o ROTA "$dev" 2>/dev/null || echo "?")
  case "$rota" in
    0) echo "SSD" ;;
    1) echo "HDD" ;;
    *) echo "?" ;;
  esac
}

# Detect connection type: SATA, NVMe, USB, SAS, etc.
disk_conn_type() {
  local dev="$1"
  local tran
  tran=$(lsblk -dn -o TRAN "$dev" 2>/dev/null || echo "?")
  case "$tran" in
    sata) echo "SATA" ;;
    nvme) echo "NVMe" ;;
    usb)  echo "USB" ;;
    ssc)  echo "SCSI" ;;
    sas)  echo "SAS" ;;
    loob) echo "Loop" ;;
    *)    echo "${tran:-?}" ;;
  esac
}

# SMART health status (best-effort; requires smartmontools)
disk_smart_health() {
  local dev="$1"
  if command -v smartctl >/dev/null 2>&1; then
    local health
    health=$(smartctl -H "$dev" 2>/dev/null | awk '/SMART overall/ {print $NF}' | head -1)
    case "$health" in
      PASSED) echo "OK" ;;
      *)      echo "WARN" ;;
    esac
  else
    echo "—"
  fi
}

echo "=== Available Disks (root disks only) ==="
for i in "${!DISKS[@]}"; do
  NAME="${DISKS[$i]}"
  SIZE=$(lsblk -dn -o SIZE "/dev/$NAME" 2>/dev/null || echo "?")
  MODEL=$(lsblk -dn -o MODEL "/dev/$NAME" 2>/dev/null | sed 's/^ *$/(unknown)/')
  MEDIA=$(disk_media_type "/dev/$NAME")
  CONN=$(disk_conn_type "/dev/$NAME")
  SMART=$(disk_smart_health "/dev/$NAME")
  PT=$(lsblk -dn -o PTUUID "/dev/$NAME" >/dev/null 2>&1 && lsblk -dn -o PTTYPE "/dev/$NAME" || echo "?")
  echo "[$((i+1))] /dev/$NAME  size=$SIZE  model=$MODEL  media=$MEDIA  conn=$CONN  smart=$SMART  pttype=${PT:-?}"
  log_msg "Disk detected: /dev/$NAME  size=$SIZE  media=$MEDIA  conn=$CONN  smart=$SMART  pttype=${PT:-?}"
done
echo ""

if [ "$UI_MODE" = "1" ] && command -v whiptail >/dev/null 2>&1; then
  SRC_IDX=$(ui_pick_disk_index "Advanced Disk Cloner" "Select SOURCE disk") || { echo "Cancelled"; exit 1; }
else
  read -rp "Select SOURCE number: " SRC_IDX
fi

if [ "$UI_MODE" = "1" ] && command -v whiptail >/dev/null 2>&1; then
  OP=$(whiptail --title "Advanced Disk Cloner" --menu "Select operation" 16 70 6 \
    "C" "Clone disk to disk" \
    "A" "Archive disk to image" \
    "R" "Restore image to disk" \
    3>&1 1>&2 2>&3) || { echo "Cancelled"; exit 1; }
else
  read -rp "Operation: [C]lone to device, [A]rchive image, or [R]estore from image? (C/A/R): " OP
fi
OP=${OP:-C}
if [[ ! "$OP" =~ ^[CcAaRr]$ ]]; then echo "Invalid choice"; exit 1; fi

# Open log file now that we know the operation
log_open
log_msg "Starting operation: $OP (verbose=$VERBOSE)"

DST_IDX=-1
if [[ "$OP" =~ ^[Cc]$ ]]; then
  if [ "$UI_MODE" = "1" ] && command -v whiptail >/dev/null 2>&1; then
    DST_IDX=$(ui_pick_disk_index "Advanced Disk Cloner" "Select TARGET disk (will be erased)") || { echo "Cancelled"; exit 1; }
  else
    read -rp "Select TARGET number: " DST_IDX
  fi
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
  SRC_PK=$(lsblk -no PKNAME "$SRC" 2>/dev/null || true)
  if [ -n "$SRC_PK" ]; then SRC_DISK="/dev/$SRC_PK"; fi
  if [ "$SRC_DISK" = "$SYS_DISK" ]; then
    LIVE_ON_SOURCE=1
  fi
fi

echo "SOURCE: $SRC"
log_msg "Selected SOURCE: $SRC"
# Bump readahead temporarily to 4096 KiB for throughput
ORIG_RA_SRC=$(get_readahead "$SRC" || echo "")
set_readahead "$SRC" 4096
if [[ "$OP" =~ ^[Cc]$ ]]; then
  echo "TARGET: $DST (WILL BE ERASED)"
  log_msg "Selected TARGET: $DST"
  read -rp "Type YES to confirm clone: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Cancelled"; exit 1; }
  ORIG_RA_DST=$(get_readahead "$DST" || echo "")
  set_readahead "$DST" 4096
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  # Choose destination drive (mounted) and path for archive
  SRC_BASENAME=$(basename "$SRC")
  echo "=== Choose drive to SAVE the archive on ==="
  # Collect mounted destinations on real disks only (exclude loop/ram media)
  mapfile -t MOUNTED < <(list_mounted_real_partitions | sort -t$'\t' -k2,2 -u)
  if [ ${#MOUNTED[@]} -eq 0 ]; then
    echo "No mounted destinations found. Please mount a drive and retry."; exit 1
  fi
  for i in "${!MOUNTED[@]}"; do
    DN=$(echo -e "${MOUNTED[$i]}" | awk -F'\t' '{print $1}')
    MP=$(echo -e "${MOUNTED[$i]}" | awk -F'\t' '{print $2}')
    FREE=$(df -hP "$MP" 2>/dev/null | awk 'NR==2{print $4}')
    echo "[$((i+1))] /dev/$DN mounted at $MP  free=$FREE"
  done
  read -rp "Select destination by number (or press Enter to type a path manually): " DSTSAVE_IDX || true
  ARCH_DIR=""
  if [[ "$DSTSAVE_IDX" =~ ^[0-9]+$ ]]; then
    DSTSAVE_IDX=$((DSTSAVE_IDX-1))
    if [ "$DSTSAVE_IDX" -lt 0 ] || [ "$DSTSAVE_IDX" -ge ${#MOUNTED[@]} ]; then echo "ERROR: selection out of range"; exit 1; fi
    ARCH_DIR=$(echo -e "${MOUNTED[$DSTSAVE_IDX]}" | awk -F'\t' '{print $2}')
  else
    # Enable readline so TAB completes filesystem paths
    read -e -p "Enter a directory path to save the archive (must exist): " ARCH_DIR
  fi
  [ -d "$ARCH_DIR" ] || { echo "Archive directory does not exist: $ARCH_DIR"; exit 1; }
  # Ask for file name or a path within the chosen destination (absolute path also accepted)
  # Enable readline with filename completion and prefill with chosen destination directory
  DEF_ARCH_PATH="${ARCH_DIR%/}/${SRC_BASENAME}.img.${PART_EXT}"
  read -e -p "Enter archive file name or path [default ${SRC_BASENAME}.img.${PART_EXT}]: " -i "$DEF_ARCH_PATH" ARCH_INPUT
  ARCH_INPUT=${ARCH_INPUT:-$DEF_ARCH_PATH}
  # Resolve relative paths anchored to the chosen destination directory
  if [[ "$ARCH_INPUT" == "./" ]] || [[ "$ARCH_INPUT" == "." ]]; then
    ARCH_INPUT="${ARCH_DIR%/}/"
  elif [[ "$ARCH_INPUT" != /* ]]; then
    # Strip leading ./ for relative paths, then prepend the destination dir
    ARCH_INPUT="${ARCH_DIR%/}/${ARCH_INPUT#./}"
  fi
  # If user provided a directory (ends with / or exists as a directory), use default filename inside it
  if [[ "$ARCH_INPUT" == */ ]] || [ -d "$ARCH_INPUT" ]; then
    ARCH="${ARCH_INPUT%/}/${SRC_BASENAME}.img.${PART_EXT}"
  else
    # Ensure proper extension
    arch_dirname=$(dirname "$ARCH_INPUT")
    arch_base=$(basename "$ARCH_INPUT")
    if [[ "$arch_base" != *.${PART_EXT} ]]; then
      if [[ "$arch_base" == *.img ]]; then
        arch_base="${arch_base}.${PART_EXT}"
      elif [[ "$arch_base" != *.* ]]; then
        arch_base="${arch_base}.img.${PART_EXT}"
      fi
    fi
    ARCH="${arch_dirname}/${arch_base}"
  fi

  # Ensure destination directory exists
  mkdir -p "$(dirname "$ARCH")"
  if [ -e "$ARCH" ]; then read -rp "File exists at $ARCH. Overwrite? (y/N): " OW; [[ "$OW" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 1; }; fi
elif [[ "$OP" =~ ^[Rr]$ ]]; then
  # Restore from image to selected target disk
  # Compute a sensible default base for TAB completion: if SOURCE has a mounted partition,
  # prefill the prompt with that mountpoint so TAB lists files from there.
  SRC_BN=$(basename -- "$SRC")
  DEF_BASE="./"
  read -e -i "$DEF_BASE" -p "Enter archive image file to restore (e.g., ./sdb.img.gz): " ARCH
  # Resolve relative paths against current working directory
  if [[ "$ARCH" == "./" ]] || [[ "$ARCH" == "." ]]; then
    ARCH="${PWD%/}/"
  elif [[ "$ARCH" != /* ]]; then
    ARCH="${PWD%/}/${ARCH#./}"
  fi
  # If a directory is provided, allow selecting a file within it (TAB completes)
  while [ -d "$ARCH" ]; do
    # Show a hint once
    echo "Enter a file inside: $ARCH"
    read -e -p "Archive file within directory: " -i "${ARCH%/}/" ARCH
  done
  if [ ! -f "$ARCH" ]; then
    # If a relative path was provided, try resolving against mounted real-disk destinations
    mapfile -t MOUNTED_MP < <(list_mounted_real_partitions | awk -F'\t' '{print $2}' | sort -u)
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
  if [ "$UI_MODE" = "1" ] && command -v whiptail >/dev/null 2>&1; then
    DST_IDX=$(ui_pick_disk_index "Advanced Disk Cloner" "Select TARGET disk for restore (will be erased)") || { echo "Cancelled"; exit 1; }
  else
    read -rp "Select TARGET number for restore: " DST_IDX
  fi
  DST_IDX=$((DST_IDX-1))
  if [ "$DST_IDX" -lt 0 ] || [ "$DST_IDX" -ge ${#DISKS[@]} ]; then echo "ERROR: target selection out of range"; exit 1; fi
  DST="/dev/${DISKS[$DST_IDX]}"
  echo "TARGET: $DST (WILL BE ERASED)"
  log_msg "Selected TARGET for restore: $DST"
  read -rp "Type YES to confirm restore: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Cancelled"; exit 1; }
  # Defer partial restore decision until after extraction to avoid double reading
  PARTIAL_RESTORE=no
fi

if [ "$LIVE_ON_SOURCE" -eq 1 ]; then
  ui_warn "You are operating on the current system disk (contains /)."
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
  ui_warn "Some partitions on $SRC are mounted. Cloning a live system may cause inconsistencies."
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
SRC_BYTES=$(get_device_size_bytes "$SRC")
if [[ ! "$SRC_BYTES" =~ ^[0-9]+$ ]] || [ "$SRC_BYTES" -eq 0 ]; then
  ui_error "Could not determine source device size: $SRC (check root permissions and device availability)"
  exit 1
fi
if [[ "$OP" =~ ^[Cc]$ ]]; then
  DST_BYTES=$(get_device_size_bytes "$DST")
  if [[ ! "$DST_BYTES" =~ ^[0-9]+$ ]] || [ "$DST_BYTES" -eq 0 ]; then
    ui_error "Could not determine target device size: $DST (check root permissions and device availability)"
    exit 1
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
    ui_error "Target is smaller than source; cannot proceed."
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

# ============================================================================
# Main operations
# ============================================================================

if [[ "$OP" =~ ^[Cc]$ ]]; then
  # Clone: disk → disk with progress and proper sync on both ends
  echo "=== Start clone: $SRC → $DST ==="
  if command -v pv >/dev/null 2>&1; then
    { ${IONICE[@]+"${IONICE[@]}"} dd if="$SRC" bs=16M conv=noerror,sync status=progress 2>&1; sync; } | \
      pv -s "$(blockdev --getsize64 "$SRC")" | \
      { ${IONICE[@]+"${IONICE[@]}"} dd of="$DST" bs=16M conv=fsync; sync; }
  else
    ${IONICE[@]+"${IONICE[@]}"} dd if="$SRC" of="$DST" bs=16M status=progress conv=noerror,sync,fsync
    sync
  fi
  sync
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  # Archive: prefer used-block per-partition imaging into a tarball if tools available
  if command -v partclone.extfs >/dev/null 2>&1 || command -v partclone.btrfs >/dev/null 2>&1 || command -v ntfsclone >/dev/null 2>&1; then
    # Ensure at least one compression tool is available for the per-partition archive path
    if ! command -v zstd >/dev/null 2>&1 && ! command -v pigz >/dev/null 2>&1 && ! command -v gzip >/dev/null 2>&1; then
      ui_error "No compression tool (zstd, pigz, or gzip) available for partition archive."
      exit 1
    fi
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
    mapfile -t APARTS < <(lsblk -ln -o NAME,FSTYPE,SIZE,PARTLABEL,PARTUUID,PKNAME "$SRC" 2>/dev/null | awk 'NR>1 {print $1"\t"$2"\t"$3"\t"$4"\t"$5}')
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
      ARCH_START=$(date +%s)
      archive_partition "$DEV" "$FST" "$OUTBASE" "$PNAME" || true
      arch_elapsed=$(( $(date +%s) - ARCH_START ))
      arch_bytes=0
      if [ -f "${OUTBASE}.pc.zst" ]; then arch_bytes=$(stat -c %s "${OUTBASE}.pc.zst" 2>/dev/null || echo 0)
      elif [ -f "${OUTBASE}.pc.gz" ]; then arch_bytes=$(stat -c %s "${OUTBASE}.pc.gz" 2>/dev/null || echo 0)
      elif [ -f "${OUTBASE}.raw.zst" ]; then arch_bytes=$(stat -c %s "${OUTBASE}.raw.zst" 2>/dev/null || echo 0)
      elif [ -f "${OUTBASE}.raw.gz" ]; then arch_bytes=$(stat -c %s "${OUTBASE}.raw.gz" 2>/dev/null || echo 0)
      elif [ -f "${OUTBASE}.ntfs.zst" ]; then arch_bytes=$(stat -c %s "${OUTBASE}.ntfs.zst" 2>/dev/null || echo 0)
      elif [ -f "${OUTBASE}.ntfs.gz" ]; then arch_bytes=$(stat -c %s "${OUTBASE}.ntfs.gz" 2>/dev/null || echo 0)
      elif [ -f "${OUTBASE}.raw" ]; then arch_bytes=$(stat -c %s "${OUTBASE}.raw" 2>/dev/null || echo 0)
      fi
      pct=""
      psize_b=
      psize_b=$(psize_to_bytes "$PSIZE")
      if [ "$psize_b" -gt 0 ] 2>/dev/null; then
        pct=$(awk "BEGIN { printf \" [%.0f%%]\", ($arch_bytes / $psize_b) * 100 }")
      fi
      eta=""
      if [ "$arch_elapsed" -gt 0 ] && [ "$arch_bytes" -gt 0 ]; then
        rate=$(( arch_bytes / arch_elapsed ))
        remaining=$(( (psize_b - arch_bytes) / (rate > 0 ? rate : 1) ))
        if [ "$remaining" -gt 60 ]; then
          eta="ETA $(numfmt --to=iec $((remaining * rate))) total"
        elif [ "$remaining" -gt 0 ]; then
          eta="ETA ${remaining}s"
        fi
      fi
      arch_fmt=
      arch_fmt=$(numfmt --to=iec "$arch_bytes" 2>/dev/null || echo "${arch_bytes}B")
      progress_msg "  → $arch_fmt${pct:+" "} ${eta}"
      arch_total_elapsed=$(( $(date +%s) - ARCH_START ))
      arch_rate=$(( arch_bytes / (arch_total_elapsed > 0 ? arch_total_elapsed : 1) ))
      progress_msg "  Done: $(numfmt --to=iec "$arch_bytes") in ${arch_total_elapsed}s ($(numfmt --to=iec "$arch_rate")/s)"
    done
    # Package everything into a tarball (new-format archive) with progress
    diag "[ARCH] Packaging archive..."
    progress_msg "Packaging archive..."
    PKG_LIST=$(mktemp -p "$TMPDIR" .pkglist.XXXXXX)
    (cd "$TMPDIR" && find . -maxdepth 1 -type f -printf "%P\n" > "$PKG_LIST")
    if [ ${#TAR_COMP_FLAG[@]} -gt 0 ]; then
      (cd "$TMPDIR" && tar "${TAR_COMP_FLAG[@]}" -cf "$ARCH_TAR" --remove-files -T "$PKG_LIST")
    else
      (cd "$TMPDIR" && tar -cf "$ARCH_TAR" --remove-files -T "$PKG_LIST")
    fi
    rm -f "$PKG_LIST" || true
    mv -f "$ARCH_TAR" "$ARCH" 2>/dev/null || true

    # Archive summary with actual size and compression ratio
      actual_size= raw_size= ratio_text= saved_text=
    actual_size=$(stat -c %s "$ARCH" 2>/dev/null || echo 0)
    if [ "$estimate_bytes" -gt 0 ] 2>/dev/null; then
      raw_size=$estimate_bytes
      ratio_text=$(awk "BEGIN { printf \"%.1f\", $raw_size / ($actual_size > 0 ? $actual_size : 1) }")
      if [ "$raw_size" -gt "$actual_size" ] 2>/dev/null; then
        saved=$((raw_size - actual_size))
        saved_text="saved $(numfmt --to=iec "$saved")"
      else
        saved_text="compressed (ratio: ${ratio_text}:1)"
      fi
    else
      ratio_text="?"
      saved_text=""
    fi
    diag ""
    diag "=== Archive Summary ==="
    diag "  File:        $ARCH"
    diag "  Actual size: $(numfmt --to=iec "$actual_size")"
    diag "  Est. raw:    $(numfmt --to=iec "$estimate_bytes")"
    diag "  Compression: ${ratio_text}:1 ($saved_text)"
    diag "  Partitions:  $PART_TOTAL (${STATUS_LOG:-?} entries)"
    diag "  Tool chain:  $PART_EXT compression"
    # Show per-partition status in verbose mode
    if [ "$VERBOSE" = "yes" ] && [ -f "$STATUS_LOG" ]; then
      diag ""
      diag "  Per-partition status:"
      while IFS=$'\t' read -r pname tool status sz; do
        printf "    %-12s %-10s %5s  %s\n" "$pname" "$tool" "$status" "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")" >&2
      done < "$STATUS_LOG"
    fi
    # Cleanup handled by trap
    sync
    fix_owner_if_sudo "$ARCH"
  else
    # Legacy full-disk raw archive
    sfdisk -d "$SRC" > "${ARCH%.${PART_EXT}}.sfdisk" 2>/dev/null || true
    if [ "$HAS_ZSTD" = "yes" ]; then
      ${IONICE[@]+"${IONICE[@]}"} dd if="$SRC" bs=1M conv=noerror,sync status=progress | zstd -T"${THREADS}" -3 > "$ARCH"
    elif command -v pigz >/dev/null 2>&1; then
      ${IONICE[@]+"${IONICE[@]}"} dd if="$SRC" bs=1M conv=noerror,sync status=progress | pigz -1 > "$ARCH"
    else
      if command -v pv >/dev/null 2>&1; then
        ${IONICE[@]+"${IONICE[@]}"} dd if="$SRC" bs=1M conv=noerror,sync status=progress | ${IONICE[@]+"${IONICE[@]}"} pv -s "$(blockdev --getsize64 "$SRC")" | gzip -3 > "$ARCH"
      else
        dd if="$SRC" bs=1M status=progress conv=noerror,sync | gzip -3 > "$ARCH"
      fi
    fi
    sync
    fix_owner_if_sudo "$ARCH"
    # Legacy archive summary
    actual_size= legacy_raw_size= legacy_ratio_text= legacy_saved_text=
    actual_size=$(stat -c %s "$ARCH" 2>/dev/null || echo 0)
    legacy_raw_size=$SRC_BYTES
    if [ "$SRC_BYTES" -gt 0 ] && [ "$actual_size" -gt 0 ]; then
      legacy_ratio_text=$(awk "BEGIN { printf \"%.1f\", $legacy_raw_size / $actual_size }")
      if [ "$legacy_raw_size" -gt "$actual_size" ]; then
        saved=$((legacy_raw_size - actual_size))
        legacy_saved_text="saved $(numfmt --to=iec "$saved")"
      else
        legacy_saved_text="ratio: ${legacy_ratio_text}:1"
      fi
    else
      legacy_ratio_text="?"
      legacy_saved_text=""
    fi
    diag ""
    diag "=== Archive Summary (legacy full-disk) ==="
    diag "  File:        $ARCH"
    diag "  Actual size: $(numfmt --to=iec "$actual_size")"
    diag "  Raw size:    $(numfmt --to=iec "$legacy_raw_size")"
    diag "  Compression: ${legacy_ratio_text}:1 ($legacy_saved_text)"
  fi
else
  # Restore from archive to selected target disk
  # Prepare temp workspace BEFORE starting restore
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

  # Detect archive format
  ARCH_IS_TAR=no
  ARCH_FORMAT=""

  # Detect compression format from filename first
  if [[ "$ARCH" == *.tar.zst ]] || [[ "$ARCH" == *.zst ]]; then
    ARCH_FORMAT="zst"
  elif [[ "$ARCH" == *.tar.gz ]] || [[ "$ARCH" == *.tgz ]] || [[ "$ARCH" == *.gz ]]; then
    ARCH_FORMAT="gz"
  elif [[ "$ARCH" == *.tar ]]; then
    ARCH_FORMAT="tar"
  else
    # Auto-detect from file content using 'file' command
    FILE_TYPE=$(file -b "$ARCH" 2>/dev/null || echo "unknown")
    if [[ "$FILE_TYPE" == *"zstd"* ]]; then
      ARCH_FORMAT="zst"
    elif [[ "$FILE_TYPE" == *"gzip"* ]]; then
      ARCH_FORMAT="gz"
    elif [[ "$FILE_TYPE" == *"POSIX tar"* ]]; then
      ARCH_FORMAT="tar"
    else
      ARCH_FORMAT="unknown"
    fi
  fi

  # If it's a compressed format, verify if it's actually a tar archive
  if [[ "$ARCH_FORMAT" == "gz" ]] || [[ "$ARCH_FORMAT" == "zst" ]]; then
    if [[ "$ARCH_FORMAT" == "gz" ]]; then
      T_DECOMP_CMD=(gzip -dc)
    else
      T_DECOMP_CMD=(zstd -dc)
    fi
    # Use tar -t to see if it's a valid tarball without extracting
    if ! "${T_DECOMP_CMD[@]}" "$ARCH" 2>/dev/null | tar -t >/dev/null 2>&1; then
      diag "[RESTORE] Archive has compressed extension but is not a tarball. Treating as raw compressed image."
      ARCH_FORMAT="raw_compressed"
    fi
  fi

  diag "[RESTORE] Detected archive format: $ARCH_FORMAT"

  # Extract based on detected format
  case "$ARCH_FORMAT" in
    "zst")
      if [ "$HAS_ZSTD" = "yes" ]; then
        if zstd -dc "$ARCH" | tar --no-same-owner -xf - -C "$TMPDIR" 2>/dev/null; then
          ARCH_IS_TAR=yes
        fi
      else
        ui_error "Archive is zstd-compressed but zstd is not available."
        exit 1
      fi
      ;;
    "gz")
      if command -v pigz >/dev/null 2>&1; then
        if pigz -dc "$ARCH" | tar --no-same-owner -xf - -C "$TMPDIR" 2>/dev/null; then
          ARCH_IS_TAR=yes
        fi
      else
        if tar --no-same-owner -xzf "$ARCH" -C "$TMPDIR" 2>/dev/null; then
          ARCH_IS_TAR=yes
        fi
      fi
      ;;
    "tar")
      if tar --no-same-owner -xf "$ARCH" -C "$TMPDIR" 2>/dev/null; then
        ARCH_IS_TAR=yes
      else
        # tar extraction failed — file may be raw compressed data with a .tar suffix
        diag "[RESTORE] tar extraction failed; checking file content for raw compressed format."
        FILE_TYPE=$(file -b "$ARCH" 2>/dev/null || echo "unknown")
        if [[ "$FILE_TYPE" == *"zstd"* ]]; then
          ARCH_FORMAT="zst"
        elif [[ "$FILE_TYPE" == *"gzip"* ]]; then
          ARCH_FORMAT="gz"
        else
          ARCH_FORMAT="raw_compressed"
        fi
      fi
      ;;
    "raw_compressed")
      ARCH_IS_TAR=no
      ;;
    *)
      # Fallback: try different methods
      if [ ${#TAR_DECOMP_FLAG[@]} -gt 0 ]; then
        if tar --no-same-owner "${TAR_DECOMP_FLAG[@]}" -x -f "$ARCH" -C "$TMPDIR" 2>/dev/null; then
          ARCH_IS_TAR=yes
        fi
      else
        if tar --no-same-owner -xzf "$ARCH" -C "$TMPDIR" 2>/dev/null; then
          ARCH_IS_TAR=yes
        fi
      fi
      ;;
  esac

  # Single cleanup trap that respects RESTORE_OK
  RESTORE_OK="no"
  cleanup_tmp() {
    if [ "${RESTORE_OK:-no}" = "yes" ]; then
      [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"
    else
      echo "[RESTORE] Kept temp workspace for diagnostics: $TMPDIR" >&2
    fi
  }
  trap 'cleanup_tmp' EXIT INT TERM HUP

  if [ "$ARCH_IS_TAR" = "yes" ]; then
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
      COMPACT="no"
      COMPACT=$(read_yes_no "Compact restore: pack partitions contiguously (preserve numbers)? (y/N): ")
      if [[ "$COMPACT" =~ ^[Yy]$ ]]; then
        SECTOR_SIZE=$(blockdev --getss "$DST" 2>/dev/null || echo 512)
        DISK_SECTORS=$(blockdev --getsz "$DST" 2>/dev/null || echo 0)
        if [ "$DISK_SECTORS" -le 0 ]; then
          {
            echo "[RESTORE][DIAG] WARN: Could not determine disk size; falling back to original layout."
          } >&2
          sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk" 2>&1 || true
          COMPACT="no"
        else
          # Parse original dump to collect partition sizes, types and UUIDs by index
          mapfile -t DUMP_LINES < <(grep -E "^/dev/[^[:space:]]*[0-9]+[[:space:]]*:" "$TMPDIR/partition_table.sfdisk" || true)
          if [ ${#DUMP_LINES[@]} -eq 0 ]; then
            {
              echo "[RESTORE][DIAG] WARN: Could not parse any partition entries from saved table; falling back."
              if [ "$VERBOSE" = "yes" ]; then echo "[RESTORE][DIAG] Showing first 20 lines of saved partition table:" >&2; sed -n '1,20p' "$TMPDIR/partition_table.sfdisk" 2>/dev/null >&2 || true; fi
            } >&2
            sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk" 2>&1 || true
            COMPACT="no"
          else
            # Build arrays: IDX -> TYPE, SIZE_SECT, UUID
            PART_INDEXES=()
            # Use a temp file to avoid declare -A scope confusion
            _type_file=$(mktemp)
            _size_file=$(mktemp)
            _uuid_file=$(mktemp)
            for ln in "${DUMP_LINES[@]}"; do
              # Extract trailing digits before the first ':' (partition index)
              idx=$(printf '%s' "$ln" | sed -E 's/^.*[^0-9]([0-9]+)[[:space:]]*:.*/\1/' | tail -n1)
              type=$(printf '%s' "$ln" | awk -F'type=' 'NF>1{print $2}' | awk -F',' '{print $1}' | sed 's/[[:space:]]//g')
              size=$(printf '%s' "$ln" | awk -F'size=' 'NF>1{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
              uuid=$(printf '%s' "$ln" | awk -F'uuid=' 'NF>1{print $2}' | awk -F',' '{print $1}' | sed 's/[[:space:]]//g')
              if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$size" =~ ^[0-9]+$ ]]; then
                PART_INDEXES+=("$idx")
                echo "${idx}=${type}" >> "$_type_file"
                echo "${idx}=${size}" >> "$_size_file"
                [ -n "$uuid" ] && echo "${idx}=${uuid}" >> "$_uuid_file"
              fi
            done
            # Source the temp files into associative arrays
            declare -A TYPE_BY_IDX=() SIZE_BY_IDX=() UUID_BY_IDX=() FS_BY_IDX=()
            while IFS='=' read -r k v; do [ -n "$k" ] && TYPE_BY_IDX[$k]="$v"; done < "$_type_file"
            while IFS='=' read -r k v; do [ -n "$k" ] && SIZE_BY_IDX[$k]="$v"; done < "$_size_file"
            while IFS='=' read -r k v; do [ -n "$k" ] && UUID_BY_IDX[$k]="$v"; done < "$_uuid_file"
            rm -f "$_type_file" "$_size_file" "$_uuid_file"

            # Discover filesystems from manifest
            if [ -f "$TMPDIR/manifest.tsv" ]; then
              while IFS=$'\t' read -r PNAME FFS _TOOL; do
                I=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
                [ -n "$I" ] && FS_BY_IDX[$I]="$FFS"
              done < "$TMPDIR/manifest.tsv"
            fi

            # Optional enlargement inputs
            declare -A SIZE_NEW=()
            for i in "${PART_INDEXES[@]}"; do SIZE_NEW[$i]="${SIZE_BY_IDX[$i]}"; done
            ENQ=$(read_yes_no "Enlarge ext4/NTFS/Btrfs partitions before restore? (y/N): ")
            if [[ "$ENQ" =~ ^[Yy]$ ]]; then
              # Compute free sectors budget = DISK_SECTORS - sum(original sizes)
              sum=0
              for i in "${PART_INDEXES[@]}"; do sum=$((sum + SIZE_BY_IDX[$i])); done
              FREE=$((DISK_SECTORS - sum))
              {
                echo "[RESTORE][DIAG] Enlargement requested"
                echo "[RESTORE][DIAG] Sum(original sizes in sectors)=$sum  Free(sectors)=$FREE"
              } >&2
              for i in "${PART_INDEXES[@]}"; do
                fs="${FS_BY_IDX[$i]:-}"
                if [ "$fs" = "ext4" ] || [ "$fs" = "ntfs" ] || [ "$fs" = "btrfs" ]; then
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

            # Build compact sfdisk script with contiguous partitions
            # Use partition number (not /dev/...) for portability
            NEWTAB=$(mktemp --tmpdir="${ARCH_DIRNAME}")
            {
              echo "label: gpt"
              echo "unit: sectors"
              for i in "${PART_INDEXES[@]}"; do
                t="${TYPE_BY_IDX[$i]:-}"
                s="${SIZE_NEW[$i]:-}"
                u="${UUID_BY_IDX[$i]:-}"
                # Use partition number format: <num> : size=<s>
                if [ -n "$u" ]; then
                  echo "${i} : size=${s}${t:+, type=$t}, uuid=$u"
                else
                  echo "${i} : size=${s}${t:+, type=$t}"
                fi
              done
            } > "$NEWTAB"
            if [ "$VERBOSE" = "yes" ]; then echo "[RESTORE][DIAG] Generated compact sfdisk table:" >&2; sed -n '1,200p' "$NEWTAB" 2>/dev/null >&2 || true; fi
            SF_OUT=$(sfdisk "$DST" < "$NEWTAB" 2>&1); SF_RC=$?
            if [ $SF_RC -ne 0 ]; then
              {
                echo "[RESTORE][DIAG][ERROR] compact sfdisk failed with code $SF_RC"
                echo "[RESTORE][DIAG][ERROR] sfdisk output:"
                echo "$SF_OUT"
                echo "[RESTORE][DIAG] Falling back to original partition table."
              } >&2
              sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk" 2>&1 || true
              COMPACT="no"
              # Table already written (original fallback) — skip non-compact block below.
              TABLE_WRITTEN=1
            else
              # Save the effective (compacted) partition table back so retry reuses it.
              cp -f "$NEWTAB" "$TMPDIR/partition_table.sfdisk"
              TABLE_WRITTEN=1
            fi
            rm -f "$NEWTAB"
            # After successful table write, explicitly set partition GUIDs using sgdisk
            if [ $SF_RC -eq 0 ] && command -v sgdisk >/dev/null 2>&1; then
              for i in "${PART_INDEXES[@]}"; do
                u="${UUID_BY_IDX[$i]:-}"
                if [ -n "$u" ]; then
                  sgdisk -u="${i}:${u}" "$DST" >/dev/null 2>&1 || true
                fi
              done
              # Also set disk GUID to match original label-id
              ORIG_DISK_GUID=$(awk -F': ' '/^label-id:/ {print $2}' "$TMPDIR/partition_table.sfdisk" | tr 'a-f' 'A-F' | tr -d '\r')
              if [[ "$ORIG_DISK_GUID" =~ ^[0-9A-F-]+$ ]]; then
                sgdisk -U "$ORIG_DISK_GUID" "$DST" >/dev/null 2>&1 || true
              fi
            fi
          fi
        fi
      fi
      if [ "${COMPACT}" != "yes" ] && [ "${TABLE_WRITTEN:-0}" -eq 0 ]; then
        {
          echo "[RESTORE][DIAG] Compact mode disabled. Importing original sfdisk table."
          if [ "$VERBOSE" = "yes" ]; then echo "[RESTORE][DIAG] Preview (first 20 lines):" >&2; sed -n '1,20p' "$TMPDIR/partition_table.sfdisk" 2>/dev/null >&2 || true; fi
        } >&2
        SF_OUT=$(sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk" 2>&1); SF_RC=$?
        if [ $SF_RC -ne 0 ]; then
          {
            echo "[RESTORE][DIAG][ERROR] sfdisk failed with code $SF_RC"
            echo "[RESTORE][DIAG][ERROR] sfdisk output:"
            echo "$SF_OUT"
          } >&2
        fi
        # After importing table, set disk GUID from label-id
        if command -v sgdisk >/dev/null 2>&1; then
          ORIG_DISK_GUID=$(awk -F': ' '/^label-id:/ {print $2}' "$TMPDIR/partition_table.sfdisk" | tr 'a-f' 'A-F' | tr -d '\r')
          if [[ "$ORIG_DISK_GUID" =~ ^[0-9A-F-]+$ ]]; then
            sgdisk -U "$ORIG_DISK_GUID" "$DST" >/dev/null 2>&1 || true
          fi
        fi
      fi

      # Use blockdev re-read as fallback when partprobe is unavailable
      partprobe "$DST" 2>/dev/null || blockdev --rereadpt "$DST" 2>/dev/null || true
      sync

      # ---- Filesystem grow after compact partition resize ----
      # After compact restore, partitions with increased size need their
      # filesystems grown to fill the new partition (NTFS, ext4, btrfs).
      if [[ "$COMPACT" =~ ^[Yy]$ ]] && [ -f "$TMPDIR/manifest.tsv" ]; then
        while IFS=$'\t' read -r PNAME FSTOOL _TOOL; do
          [ "$FSTOOL" = "ntfs" ] || [ "$FSTOOL" = "ext4" ] || [ "$FSTOOL" = "btrfs" ] || continue
          IDX=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
          [ -n "$IDX" ] || continue
          if [[ "$DST" =~ nvme[0-9]+n[0-9]+$ ]]; then
            CAND="${DST}p${IDX}"
          else
            CAND="${DST}${IDX}"
          fi
          [ -b "$CAND" ] || continue
          case "$FSTOOL" in
            ntfs)
              if command -v ntfsresize >/dev/null 2>&1; then
                ntfsresize -f "$CAND" 2>/dev/null || echo "[RESTORE][DIAG] WARN: ntfsresize failed for $CAND" >&2
              fi
              ;;
            ext4)
              if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
                e2fsck -f "$CAND" 2>/dev/null || true
                resize2fs "$CAND" 2>/dev/null || echo "[RESTORE][DIAG] WARN: resize2fs failed for $CAND" >&2
              fi
              ;;
            btrfs)
              if command -v btrfs >/dev/null 2>&1; then
                _btrfs_mnt=$(mktemp -d)
                if mount "$CAND" "$_btrfs_mnt" 2>/dev/null; then
                  btrfs filesystem resize max "$_btrfs_mnt" 2>/dev/null || true
                  umount "$_btrfs_mnt" 2>/dev/null || true
                fi
                rmdir "$_btrfs_mnt" 2>/dev/null || true
              fi
              ;;
          esac
        done < "$TMPDIR/manifest.tsv"
      fi
    fi

    # ---- Shared partition restore using restore_partition() ----
    RESTORE_OK="no"  # Reset in case retry loop runs
    if [ -f "$TMPDIR/manifest.tsv" ]; then
      declare -A __ADC_SELECTED=()
      if [ "${PARTIAL_RESTORE:-no}" = "yes" ]; then
        echo "Available partitions in archive (index: fs tool):"
        while IFS=$'\t' read -r PNAME FSTOOL TOOL; do
          IDX=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
          [ -n "$IDX" ] || continue
          echo " - $IDX: ${FSTOOL:-unknown} via ${TOOL:-?}"
        done < "$TMPDIR/manifest.tsv"
        read -rp "Enter partition numbers to restore (comma-separated, ranges ok e.g. 1,3-5): " __ADC_SEL
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
      fi

      # Main restore loop — iterate through manifest and restore each partition
      while IFS=$'\t' read -r PNAME FSTOOL TOOL; do
        # If partial restore, skip entries not chosen
        if [ "${PARTIAL_RESTORE:-no}" = "yes" ]; then
          IDX=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
          [ -n "$IDX" ] && [ -n "${__ADC_SELECTED[$IDX]:-}" ] || { diag "[RESTORE] Skipping partition $PNAME (not selected)"; continue; }
        else
          IDX=""
        fi

        # Resolve target device from partition name suffix
        if [ -n "$IDX" ]; then
          if [[ "$DST" =~ nvme[0-9]+n[0-9]+$ ]]; then
            CAND="${DST}p${IDX}"
          else
            CAND="${DST}${IDX}"
          fi
        else
          CAND=""
        fi
        [ -b "$CAND" ] || { [ -z "$CAND" ] && { echo "WARN: could not map partition $PNAME to target; skipping"; continue; }; }

        BASE="$TMPDIR/part-${PNAME}"
        diag "[RESTORE] Restoring: $PNAME ($FSTOOL via $TOOL) → $CAND"
        restore_partition "$FSTOOL" "$TOOL" "$BASE" "$CAND" || echo "[RESTORE] WARN: restore failed for $PNAME, continuing..." >&2
        sync
      done < "$TMPDIR/manifest.tsv"
    else
      ui_error "manifest.tsv not found in archive."
    fi
    RESTORE_OK="yes"
    echo "[RESTORE] Restore completed successfully." >&2

    # ---- Optional retry on failure ----
    # Guard: only offer retry when partition_table.sfdisk exists (set during
    # non-partial restore at line ~1720). COMPACT is also in scope from that
    # block but we check the file directly since it's the true prerequisite
    # for any retry to be meaningful.
    if [ -f "$TMPDIR/manifest.tsv" ] && [ "${PARTIAL_RESTORE:-no}" != "yes" ] && [ -f "$TMPDIR/partition_table.sfdisk" ]; then
      {
        echo "[RESTORE] Restore completed. Temp workspace kept for diagnostics: $TMPDIR" >&2
        echo "[RESTORE] Verify the restore before rebooting." >&2
      } >&2
      RETRY=$(read_yes_no "Retry restore with same settings? (y/N): ")
      if [[ "$RETRY" =~ ^[Yy]$ ]]; then
        echo "[RESTORE] Retrying..." >&2
        # Clear associative arrays from prior run to avoid stale data
        unset -A __ADC_SELECTED SIZE_NEW 2>/dev/null
        declare -A __ADC_SELECTED=() SIZE_NEW=()
        # Recreate partition table (reuse compact settings)
        SECTOR_SIZE=$(blockdev --getss "$DST" 2>/dev/null || echo 512)
        DISK_SECTORS=$(blockdev --getsz "$DST" 2>/dev/null || echo 0)
        if [ "$DISK_SECTORS" -gt 0 ]; then
          sfdisk "$DST" < "$TMPDIR/partition_table.sfdisk" 2>&1 || true
          partprobe "$DST" 2>/dev/null || blockdev --rereadpt "$DST" 2>/dev/null || true
          sync

          # Re-run partition restore from temp
          while IFS=$'\t' read -r PNAME FSTOOL TOOL; do
            IDX=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
            if [ -n "$IDX" ]; then
              if [[ "$DST" =~ nvme[0-9]+n[0-9]+$ ]]; then
                CAND="${DST}p${IDX}"
              else
                CAND="${DST}${IDX}"
              fi
            else
              CAND=""
            fi
            [ -b "$CAND" ] || { echo "WARN: could not map partition $PNAME to target; skipping"; continue; }
            BASE="$TMPDIR/part-${PNAME}"
            diag "[RESTORE-RETRY] Restoring: $PNAME ($FSTOOL via $TOOL) → $CAND"
            restore_partition "$FSTOOL" "$TOOL" "$BASE" "$CAND" || echo "[RESTORE] WARN: retry failed for $PNAME" >&2
            sync
          done < "$TMPDIR/manifest.tsv"
          RESTORE_OK="yes"
          diag "[RESTORE] Retry completed."
        fi
      fi
    fi
  else
    # Legacy full-disk raw restore
    if [[ "$ARCH_FORMAT" = "raw_compressed" ]] || [[ "$ARCH_FORMAT" = "gz" ]] || [[ "$ARCH_FORMAT" = "zst" ]] || [[ "$ARCH_FORMAT" = "tar" ]]; then
      if [[ "$ARCH_FORMAT" = "zst" ]] || [[ "$ARCH" == *.zst ]]; then
        DECOMP_CMD=(zstd -dc -T"${THREADS}")
      elif [[ "$ARCH_FORMAT" = "gz" ]] || [[ "$ARCH" == *.gz ]]; then
        if command -v pigz >/dev/null 2>&1; then
          DECOMP_CMD=(pigz -dc -p"${THREADS}")
        else
          DECOMP_CMD=(gzip -dc)
        fi
      elif [[ "$ARCH_FORMAT" = "raw_compressed" ]] || [[ "$ARCH_FORMAT" = "tar" ]]; then
        # Re-detect actual compression for raw images since extension is unreliable
        FILE_TYPE=$(file -b "$ARCH" 2>/dev/null || echo "unknown")
        if [[ "$FILE_TYPE" == *"zstd"* ]]; then
          DECOMP_CMD=(zstd -dc -T"${THREADS}")
        elif [[ "$FILE_TYPE" == *"gzip"* ]]; then
          if command -v pigz >/dev/null 2>&1; then
            DECOMP_CMD=(pigz -dc -p"${THREADS}")
          else
            DECOMP_CMD=(gzip -dc)
          fi
        fi
      fi

      if [ ${#DECOMP_CMD[@]} -gt 0 ]; then
        if command -v pv >/dev/null 2>&1; then
          "${DECOMP_CMD[@]}" "$ARCH" | pv | ${IONICE[@]+"${IONICE[@]}"} dd of="$DST" bs=1M conv=fsync status=none
        else
          "${DECOMP_CMD[@]}" "$ARCH" | ${IONICE[@]+"${IONICE[@]}"} dd of="$DST" bs=1M conv=fsync status=progress
        fi
      else
        ui_error "Could not determine decompression tool for raw image: $ARCH"
        exit 1
      fi
    else
      # Truly raw (uncompressed)
      if command -v pv >/dev/null 2>&1; then
        pv "$ARCH" | ${IONICE[@]+"${IONICE[@]}"} dd of="$DST" bs=1M conv=fsync status=none
      else
        dd if="$ARCH" of="$DST" bs=1M conv=fsync status=progress
      fi
    fi
    echo "[RESTORE] Restore completed successfully." >&2
    RESTORE_OK="yes"
  fi
  sync
fi

if [[ "$OP" =~ ^[CcRr]$ ]]; then
  echo "=== Post-clone adjustments ==="
  if [ "${PARTIAL_RESTORE:-no}" != "yes" ]; then
    if command -v sgdisk >/dev/null 2>&1; then
      echo "Fixing GPT backup on target (if needed)..."
      sgdisk -e "$DST" || true
    fi
  fi
  partprobe "$DST" 2>/dev/null || blockdev --rereadpt "$DST" 2>/dev/null || true
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
      mapfile -t _NTFS_TGT < <(lsblk -ln -o NAME,FSTYPE "$DST" 2>/dev/null | awk '$2=="ntfs"{print $1}')
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
        echo "Detected Windows files on target. We recommend skipping GUID randomization to keep BCD valid."
      fi
      RAND_GUIDS=$(read_yes_no "Randomize GPT disk and partition GUIDs on TARGET? (y/N): ")
      if [[ "$RAND_GUIDS" =~ ^[Yy]$ ]]; then
        echo "Randomizing disk GUID on $DST..."
        sgdisk -G "$DST" || true
        # Randomize each partition's PARTUUID
        mapfile -t TP_PARTS < <(lsblk -ln -o NAME,PKNAME "$DST" 2>/dev/null | awk '$2!=""{print $1}')
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
        partprobe "$DST" 2>/dev/null || blockdev --rereadpt "$DST" 2>/dev/null || true
        sync
        printf "\nNew target PARTUUIDs:\n"
        lsblk -o NAME,PARTUUID "$DST" || true
        echo "NOTE: If the restored system uses PARTUUID/UUID in /etc/fstab or bootloader configs, you may need to update them on the target."
      fi
    fi
  fi

  # Offer to enlarge the last growable partition on restore to use remaining free space
  if [[ "$OP" =~ ^[Rr]$ ]] && [ "${PARTIAL_RESTORE:-no}" != "yes" ]; then
    LAST_PART_NAME=$(lsblk -ln -o NAME,PKNAME "$DST" 2>/dev/null | awk '$2!="" {print $1}' | tail -n1)
    if [ -n "$LAST_PART_NAME" ]; then
      LAST_PART="/dev/${LAST_PART_NAME}"
      FSTYPE_LAST=$(lsblk -no FSTYPE "$LAST_PART" 2>/dev/null || true)
      if [ "$FSTYPE_LAST" = "ext4" ] || [ "$FSTYPE_LAST" = "ntfs" ] || [ "$FSTYPE_LAST" = "btrfs" ]; then
        SECTOR_SIZE=$(blockdev --getss "$DST" 2>/dev/null || echo 512)
        DISK_SECTORS=$(blockdev --getsz "$DST" 2>/dev/null || echo 0)
        CUR_BYTES=$(blockdev --getsize64 "$LAST_PART" 2>/dev/null || echo 0)
        if [[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]] && [[ "$DISK_SECTORS" =~ ^[0-9]+$ ]] && [ "$DISK_SECTORS" -gt 0 ] && [ "$CUR_BYTES" -gt 0 ]; then
          START_SECT=$(sfdisk -d "$DST" 2>/dev/null | awk -v p="${LAST_PART}" '$1==p {for(i=1;i<=NF;i++){if($i ~ /^start=/){gsub(/start=/,"",$i); gsub(/,/,"",$i); print $i; exit}}}')
          if [[ "$START_SECT" =~ ^[0-9]+$ ]]; then
            MAX_BYTES=$(( (DISK_SECTORS - START_SECT) * SECTOR_SIZE ))
            if [ "$MAX_BYTES" -gt "$CUR_BYTES" ]; then
              CUR_H=$(numfmt --to=iec "$CUR_BYTES" 2>/dev/null || echo "$CUR_BYTES bytes")
              MAX_H=$(numfmt --to=iec "$MAX_BYTES" 2>/dev/null || echo "$MAX_BYTES bytes")
              printf "\nLast partition: %s (fs=%s)\n" "$LAST_PART" "$FSTYPE_LAST"
              printf "Current size:  %s\n" "$CUR_H"
              printf "Possible max:  %s (using remaining free space)\n" "$MAX_H"
              ENL=$(read_yes_no "Enlarge this partition now to use free space? (y/N): ")
              if [[ "$ENL" =~ ^[Yy]$ ]]; then
                PNUM=$(echo "$LAST_PART_NAME" | grep -Eo '[0-9]+$' || true)
                if [[ "$PNUM" =~ ^[0-9]+$ ]]; then
                  mount | awk -v p="$LAST_PART" '$1 == p {print $3}' | xargs -r -n1 umount || true
                  echo ",+" | sfdisk --no-reread -N "$PNUM" "$DST" 2>/dev/null || true
                  partprobe "$DST" 2>/dev/null || blockdev --rereadpt "$DST" 2>/dev/null || true
                  sync
                  if [ "$FSTYPE_LAST" = "ext4" ]; then
                    if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
                      e2fsck -f "$LAST_PART" 2>/dev/null || true
                      resize2fs "$LAST_PART" 2>/dev/null || true
                      echo "Ext4 filesystem grown."
                    else
                      echo "e2fsck/resize2fs not available; skipped filesystem grow."
                    fi
                  elif [ "$FSTYPE_LAST" = "ntfs" ]; then
                    if command -v ntfsresize >/dev/null 2>&1; then
                      ntfsresize -f "$LAST_PART" 2>/dev/null || true
                      echo "NTFS filesystem grown."
                    else
                      echo "ntfsresize not available; skipped filesystem grow."
                    fi
                  elif [ "$FSTYPE_LAST" = "btrfs" ]; then
                    if grow_btrfs_partition "$LAST_PART"; then
                      echo "Btrfs filesystem grown."
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
  fi

  # Optional: fix low space on Linux root by growing ext4/btrfs to full partition.
  if [ "${PARTIAL_RESTORE:-no}" != "yes" ]; then
    GROW=$(read_yes_no "Grow ext4/btrfs filesystem on TARGET to fill its partition? (y/N): ")
    if [[ "$GROW" =~ ^[Yy]$ ]]; then
      mapfile -t TGT_GROWABLE < <(lsblk -ln -o NAME,FSTYPE "$DST" 2>/dev/null | awk '$2=="ext4" || $2=="btrfs" {print $1"\t"$2}')
      if [ ${#TGT_GROWABLE[@]} -eq 1 ]; then
        TP_NAME=$(echo -e "${TGT_GROWABLE[0]}" | awk -F'\t' '{print $1}')
        TP_FS=$(echo -e "${TGT_GROWABLE[0]}" | awk -F'\t' '{print $2}')
        TP="/dev/${TP_NAME}"
        echo "=== Growing $TP (fs=$TP_FS) to fill its partition ==="
        mount | awk -v p="$TP" '$1 == p {print $3}' | xargs -r -n1 umount || true
        if [ "$TP_FS" = "ext4" ]; then
          if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
            e2fsck -f "$TP" 2>/dev/null || true
            resize2fs "$TP" 2>/dev/null || true
            tune2fs -m 1 "$TP" 2>/dev/null || true
            echo "Ext4 grow done."
          else
            echo "e2fsck/resize2fs not available; skipping ext4 grow."
          fi
        elif [ "$TP_FS" = "btrfs" ]; then
          if grow_btrfs_partition "$TP"; then
            echo "Btrfs grow done."
          fi
        else
          echo "Unsupported filesystem for grow: $TP_FS"
        fi
      else
        echo "Skip grow: ext4/btrfs auto-detect ambiguous or none found on target (${#TGT_GROWABLE[@]} candidates)."
      fi
    fi
  fi
else
  echo "Saved archive: ${ARCH:-archive}"
  _dump_base="${ARCH:-}"
  echo "Partition table dump: ${_dump_base%.${PART_EXT}}.sfdisk (if available)"
fi

echo "=== Done ==="
show_op_time
if [[ "$OP" =~ ^[Cc]$ ]]; then
  log_msg "Clone complete: $SRC → $DST"
  echo "Cloned $SRC to $DST. If the target is larger, you may later expand partitions/filesystems."
elif [[ "$OP" =~ ^[Aa]$ ]]; then
  log_msg "Archive complete: $SRC → $ARCH"
  echo "Archived $SRC to $ARCH successfully."
else
  log_msg "Restore complete: $ARCH → $DST"
  echo "Restored $ARCH to $DST successfully."
fi
log_close
