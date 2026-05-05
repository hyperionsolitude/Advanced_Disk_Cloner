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
ORIGINAL_ARGS=("$@")

show_help() {
  cat <<'EOF'
Advanced Disk Cloner

Usage:
  sudo ./clone_minimal.sh [options]

Options:
  -v, --verbose                      Enable verbose diagnostics
  --self-test                        Run environment self-test and exit
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
    *)
      echo "Unknown argument: $1"
      echo "Usage: sudo ./clone_minimal.sh [-v|--verbose] [--offline] [--offline-bundle <dir>] [--offline-archive <file>] [--bundle-deps <dir>] [--bundle-deps-archive <file>] [--build-deb <path|dir>] [--self-test]"
      exit 1
      ;;
  esac
done
diag() { if [ "$VERBOSE" = "yes" ]; then echo "$@" >&2; fi }

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
  local i name size model ptt
  for i in "${!DISKS[@]}"; do
    name="${DISKS[$i]}"
    size=$(lsblk -dn -o SIZE "/dev/$name" 2>/dev/null || echo "?")
    model=$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null | sed 's/^ *$/(unknown)/')
    ptt=$(lsblk -dn -o PTTYPE "/dev/$name" 2>/dev/null || echo "?")
    menu_args+=("$((i+1))" "/dev/$name  size=$size  model=$model  pttype=${ptt:-?}")
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

# List mounted partitions that belong to real disks (sdX / nvme*n1).
# Output format: "<partition_name>\t<mountpoint>"
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
run_root() { if is_root; then "$@"; else sudo "$@"; fi }

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
    declare -A PKG_FOR_CMD
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

# Build numbered list of root disks: /dev/sd[a-z] and /dev/nvme*n1
mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && ($1 ~ /^sd[a-z]+$/ || $1 ~ /^nvme[0-9]+n[0-9]+$/) {print $1}' | sort)

if [ ${#DISKS[@]} -eq 0 ]; then
  ui_error "No supported root disks were found (/dev/sdX or /dev/nvme*n1)."
  exit 1
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
  if command -v partclone.extfs >/dev/null 2>&1 || command -v partclone.btrfs >/dev/null 2>&1 || command -v ntfsclone >/dev/null 2>&1; then
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
        btrfs)
          # If partition is mounted (e.g., active root), avoid partclone and fallback to dd
          MOUNTED_AT=$(findmnt -no TARGET "$DEV" 2>/dev/null || true)
          if command -v partclone.btrfs >/dev/null 2>&1 && [ -z "$MOUNTED_AT" ]; then
            echo -e "$PNAME\tbtrfs\tpartclone" >> "$MANIFEST"
            (
              set +e -o pipefail
    if [ "$PART_EXT" = "zst" ] && command -v zstd >/dev/null 2>&1; then
      if command -v pv >/dev/null 2>&1; then
        { ${IONICE:+$IONICE }partclone.btrfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | ${IONICE:+$IONICE }pv | zstd -T${THREADS} -3 > "${OUTBASE}.pc.zst"
      else
        { partclone.btrfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | zstd -T${THREADS} -3 > "${OUTBASE}.pc.zst"
      fi
    else
      if command -v pv >/dev/null 2>&1; then
        if command -v pigz >/dev/null 2>&1; then
          { ${IONICE:+$IONICE }partclone.btrfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | ${IONICE:+$IONICE }pv | pigz $PIGZ_ARGS > "${OUTBASE}.pc.gz"
        else
          { partclone.btrfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | pv | gzip -3 > "${OUTBASE}.pc.gz"
        fi
      else
        if command -v pigz >/dev/null 2>&1; then
          { partclone.btrfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | pigz $PIGZ_ARGS > "${OUTBASE}.pc.gz"
        else
          { partclone.btrfs -c -s "$DEV" -o - 2>&1 1>&3 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; } } 3>&1 | gzip -3 > "${OUTBASE}.pc.gz"
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
                diag "[ARCH] Done: $PNAME via partclone.btrfs (size=$(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz B"))"
              else
                echo -e "$PNAME\tpartclone\tFAIL\t0" >> "$STATUS_LOG"
                echo "[ARCH] FAIL: $PNAME via partclone.btrfs (no output detected)" >&2
              fi
            else
              echo -e "$PNAME\tpartclone\tFAIL\t0" >> "$STATUS_LOG"
              echo "[ARCH] FAIL: $PNAME via partclone.btrfs (rc=$rc)" >&2
            fi
          else
            echo -e "$PNAME\tbtrfs\tdd" >> "$MANIFEST"
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
    fix_owner_if_sudo "$ARCH"
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
    fix_owner_if_sudo "$ARCH"
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
  
  # Enhanced archive detection: check file content, not just extension
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
  
  diag "[RESTORE] Detected archive format: $ARCH_FORMAT"
  
  # Extract based on detected format
  case "$ARCH_FORMAT" in
    "zst")
      if [ "$HAS_ZSTD" = "yes" ]; then
        if zstd -dc "$ARCH" | tar --no-same-owner -xf - -C "$TMPDIR" 2>&1 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; }; then
          ARCH_IS_TAR=yes
        fi
      else
        ui_error "Archive is zstd-compressed but zstd is not available."
        exit 1
      fi
      ;;
    "gz")
      if [ "$HAS_PIGZ" = "yes" ]; then
        if pigz -dc "$ARCH" | tar --no-same-owner -xf - -C "$TMPDIR" 2>&1 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; }; then
          ARCH_IS_TAR=yes
        fi
      else
        if tar --no-same-owner -xzf "$ARCH" -C "$TMPDIR" 2>&1 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; }; then
          ARCH_IS_TAR=yes
        fi
      fi
      ;;
    "tar")
      if tar --no-same-owner -xf "$ARCH" -C "$TMPDIR" 2>&1 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; }; then
        ARCH_IS_TAR=yes
      fi
      ;;
    *)
      # Fallback: try different methods
      if [ ${#TAR_DECOMP_FLAG[@]} -gt 0 ]; then
        if tar --no-same-owner "${TAR_DECOMP_FLAG[@]}" -x -f "$ARCH" -C "$TMPDIR" 2>&1 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; }; then
          ARCH_IS_TAR=yes
        fi
      else
        if tar --no-same-owner -xzf "$ARCH" -C "$TMPDIR" 2>&1 | { [ "$VERBOSE" = "yes" ] && cat || cat >/dev/null; }; then
          ARCH_IS_TAR=yes
        fi
      fi
      ;;
  esac
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
          # Discover filesystems to allow enlargement prompts (ext4/ntfs/btrfs)
          declare -A FS_BY_IDX
          while IFS=$'\t' read -r PNAME FFS TOOL; do
            # extract numeric index from PNAME
            I=$(echo "$PNAME" | grep -Eo '[0-9]+$' || true)
            [ -n "$I" ] && FS_BY_IDX[$I]="$FFS"
          done < "$TMPDIR/manifest.tsv"
          # Optional enlargement inputs
          ENQ=$(read_yes_no "Enlarge ext4/NTFS/Btrfs partitions before restore? (y/N): ")
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
        ui_error "manifest.tsv not found in archive."
        exit 1
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
            if [ "$FSTOOL" = "btrfs" ]; then
              if { [ -f "${BASE}.pc.gz" ] || [ -f "${BASE}.pc.zst" ]; } && command -v partclone.btrfs >/dev/null 2>&1; then
                if [ -f "${BASE}.pc.zst" ] && command -v zstd >/dev/null 2>&1; then
                  zstd -dc -T${THREADS} "${BASE}.pc.zst" | partclone.btrfs -r -o "$TDEV" -s -
                elif command -v pigz >/dev/null 2>&1; then
                  pigz -dc "${BASE}.pc.gz" | partclone.btrfs -r -o "$TDEV" -s -
                else
                  gzip -dc "${BASE}.pc.gz" | partclone.btrfs -r -o "$TDEV" -s -
                fi
              else
                echo "WARN: missing partclone.btrfs image or tool for $PNAME"
              fi
            elif { [ -f "${BASE}.pc.gz" ] || [ -f "${BASE}.pc.zst" ]; } && command -v partclone.extfs >/dev/null 2>&1; then
              if [ -f "${BASE}.pc.zst" ] && command -v zstd >/dev/null 2>&1; then
                zstd -dc -T${THREADS} "${BASE}.pc.zst" | partclone.extfs -r -o "$TDEV" -s -
              elif command -v pigz >/dev/null 2>&1; then
                pigz -dc "${BASE}.pc.gz" | partclone.extfs -r -o "$TDEV" -s -
              else
                gzip -dc "${BASE}.pc.gz" | partclone.extfs -r -o "$TDEV" -s -
              fi
            else
              echo "WARN: missing partclone image or tool for $PNAME"
            fi
            ;;
          ntfsclone)
            if { [ -f "${BASE}.ntfs.gz" ] || [ -f "${BASE}.ntfs.zst" ]; } && command -v ntfsclone >/dev/null 2>&1; then
              if [ -f "${BASE}.ntfs.zst" ] && command -v zstd >/dev/null 2>&1; then
                zstd -dc -T${THREADS} "${BASE}.ntfs.zst" | ntfsclone --restore-image --overwrite "$TDEV" -
              elif command -v pigz >/dev/null 2>&1; then
                pigz -dc "${BASE}.ntfs.gz" | ntfsclone --restore-image --overwrite "$TDEV" -
              else
                gzip -dc "${BASE}.ntfs.gz" | ntfsclone --restore-image --overwrite "$TDEV" -
              fi
            else
              echo "WARN: missing ntfsclone image or tool for $PNAME"
            fi
            ;;
          dd)
            # Try different raw image formats in order of preference
            IMGFILE=""
            if [ -f "${BASE}.raw.zst" ]; then
              IMGFILE="${BASE}.raw.zst"
              if command -v zstd >/dev/null 2>&1; then
                if command -v pv >/dev/null 2>&1; then
                  zstd -dc -T${THREADS} "$IMGFILE" | pv | dd of="$TDEV" bs=1M conv=fsync status=none
                else
                  zstd -dc -T${THREADS} "$IMGFILE" | dd of="$TDEV" bs=1M status=progress conv=fsync
                fi
              else
                echo "WARN: zstd not available for $IMGFILE"
              fi
            elif [ -f "${BASE}.raw.gz" ]; then
              IMGFILE="${BASE}.raw.gz"
              if command -v pigz >/dev/null 2>&1; then
                if command -v pv >/dev/null 2>&1; then
                  pigz -dc "$IMGFILE" | pv | dd of="$TDEV" bs=1M conv=fsync status=none
                else
                  pigz -dc "$IMGFILE" | dd of="$TDEV" bs=1M status=progress conv=fsync
                fi
              else
                if command -v pv >/dev/null 2>&1; then
                  gzip -dc "$IMGFILE" | pv | dd of="$TDEV" bs=1M conv=fsync status=none
                else
                  gzip -dc "$IMGFILE" | dd of="$TDEV" bs=1M status=progress conv=fsync
                fi
              fi
            elif [ -f "${BASE}.raw" ]; then
              IMGFILE="${BASE}.raw"
              if command -v pv >/dev/null 2>&1; then
                pv "$IMGFILE" | dd of="$TDEV" bs=1M conv=fsync status=none
              else
                dd if="$IMGFILE" of="$TDEV" bs=1M status=progress conv=fsync
              fi
            elif [ -f "${BASE}.raw.raw" ]; then
              IMGFILE="${BASE}.raw.raw"
              if command -v pv >/dev/null 2>&1; then
                pv "$IMGFILE" | dd of="$TDEV" bs=1M conv=fsync status=none
              else
                dd if="$IMGFILE" of="$TDEV" bs=1M status=progress conv=fsync
              fi
            else
              echo "WARN: missing raw image for $PNAME (tried .zst/.gz/.raw/.raw.raw)"
            fi
            ;;
        esac
        sync
      done < "$TMPDIR/manifest.tsv"
    else
      ui_error "manifest.tsv not found in archive."
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
            if [ -f "${BASE}.pc.zst" ] || [ -f "${BASE}.pc.gz" ]; then
              if [ "$FSTOOL" = "btrfs" ] && command -v partclone.btrfs >/dev/null 2>&1; then
                if [ -f "${BASE}.pc.zst" ] && command -v zstd >/dev/null 2>&1; then
                  zstd -dc -T${THREADS} "${BASE}.pc.zst" | partclone.btrfs -r -o "$TDEV" -s -
                else
                  gzip -dc "${BASE}.pc.gz" | partclone.btrfs -r -o "$TDEV" -s -
                fi
              elif command -v partclone.extfs >/dev/null 2>&1; then
                if [ -f "${BASE}.pc.zst" ] && command -v zstd >/dev/null 2>&1; then
                  zstd -dc -T${THREADS} "${BASE}.pc.zst" | partclone.extfs -r -o "$TDEV" -s -
                else
                  gzip -dc "${BASE}.pc.gz" | partclone.extfs -r -o "$TDEV" -s -
                fi
              else
                echo "WARN: missing partclone restore tool for $PNAME"
              fi
              else
                echo "WARN: missing partclone image or tool for $PNAME"
              fi
              ;;
            ntfsclone)
            if { [ -f "${BASE}.ntfs.zst" ] || [ -f "${BASE}.ntfs.gz" ]; } && command -v ntfsclone >/dev/null 2>&1; then
              if [ -f "${BASE}.ntfs.zst" ] && command -v zstd >/dev/null 2>&1; then
                zstd -dc -T${THREADS} "${BASE}.ntfs.zst" | ntfsclone --restore-image --overwrite "$TDEV" -
              else
                gzip -dc "${BASE}.ntfs.gz" | ntfsclone --restore-image --overwrite "$TDEV" -
              fi
              else
                echo "WARN: missing ntfsclone image or tool for $PNAME"
              fi
              ;;
            dd)
            # Try different raw image formats in order of preference
            IMGFILE=""
            if [ -f "${BASE}.raw.zst" ]; then
              IMGFILE="${BASE}.raw.zst"
              if command -v zstd >/dev/null 2>&1; then
                if command -v pv >/dev/null 2>&1; then
                  zstd -dc -T${THREADS} "$IMGFILE" | pv | dd of="$TDEV" bs=16M ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync status=none
                else
                  zstd -dc -T${THREADS} "$IMGFILE" | dd of="$TDEV" bs=16M status=progress ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync
                fi
              else
                echo "WARN: zstd not available for $IMGFILE"
              fi
            elif [ -f "${BASE}.raw.gz" ]; then
              IMGFILE="${BASE}.raw.gz"
              if command -v pigz >/dev/null 2>&1; then
                if command -v pv >/dev/null 2>&1; then
                  pigz -dc "$IMGFILE" | pv | dd of="$TDEV" bs=16M ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync status=none
                else
                  pigz -dc "$IMGFILE" | dd of="$TDEV" bs=16M status=progress ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync
                fi
              else
                if command -v pv >/dev/null 2>&1; then
                  gzip -dc "$IMGFILE" | pv | dd of="$TDEV" bs=16M ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync status=none
                else
                  gzip -dc "$IMGFILE" | dd of="$TDEV" bs=16M status=progress ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync
                fi
              fi
            elif [ -f "${BASE}.raw" ]; then
              IMGFILE="${BASE}.raw"
              if command -v pv >/dev/null 2>&1; then
                pv "$IMGFILE" | dd of="$TDEV" bs=16M ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync status=none
              else
                dd if="$IMGFILE" of="$TDEV" bs=16M status=progress ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync
              fi
            elif [ -f "${BASE}.raw.raw" ]; then
              IMGFILE="${BASE}.raw.raw"
              if command -v pv >/dev/null 2>&1; then
                pv "$IMGFILE" | dd of="$TDEV" bs=16M ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync status=none
              else
                dd if="$IMGFILE" of="$TDEV" bs=16M status=progress ${DD_OFLAGS:+$DD_OFLAGS} conv=fsync
              fi
            else
              echo "WARN: missing raw image for $PNAME (tried .zst/.gz/.raw/.raw.raw)"
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
      if [ "$FSTYPE_LAST" = "ext4" ] || [ "$FSTYPE_LAST" = "ntfs" ] || [ "$FSTYPE_LAST" = "btrfs" ]; then
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

  # Optional: fix low space on Linux root by growing ext4/btrfs to full partition.
  if [ "${PARTIAL_RESTORE:-no}" != "yes" ]; then
    GROW=$(read_yes_no "Grow ext4/btrfs filesystem on TARGET to fill its partition? (y/N): ")
    if [[ "$GROW" =~ ^[Yy]$ ]]; then
    # Auto-detect a single ext4 or btrfs partition on target
    mapfile -t TGT_GROWABLE < <(lsblk -ln -o NAME,FSTYPE "$DST" | awk '$2=="ext4" || $2=="btrfs" {print $1"\t"$2}')
    if [ ${#TGT_GROWABLE[@]} -eq 1 ]; then
      TP_NAME=$(echo -e "${TGT_GROWABLE[0]}" | awk -F'\t' '{print $1}')
      TP_FS=$(echo -e "${TGT_GROWABLE[0]}" | awk -F'\t' '{print $2}')
      TP="/dev/${TP_NAME}"
      echo "=== Growing $TP (fs=$TP_FS) to fill its partition ==="
      mount | awk -v p="$TP" '$1 == p {print $3}' | xargs -r -n1 umount || true
      if [ "$TP_FS" = "ext4" ]; then
        if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
          e2fsck -f "$TP" || true
          resize2fs "$TP" || true
          tune2fs -m 1 "$TP" || true
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

