# Advanced Disk Cloner (Minimal)

Cross-platform disk cloner/archiver/restorer optimized for safety, speed, and multi-OS boot compatibility (Windows, Linux, macOS).

Two editions:
- `clone_minimal.sh`: Linux edition with full support for ext4, NTFS, APFS, HFS+ partitions
- `adc_macos.sh`: macOS standalone edition for native macOS disk operations

On macOS, `clone_minimal.sh` auto-detects and delegates to `adc_macos.sh`.

## Highlights

### Linux Edition (`clone_minimal.sh`)
- Interactive disk selection (`/dev/sdX`, `/dev/nvme*n1`)
- Clone disk → disk via `dd` with GPT backup repair (`sgdisk -e`)
- Archive disk → per-partition images (used-block where available)
  - ext4 via `partclone.extfs`
  - NTFS via `ntfsclone`
  - APFS via raw `dd` (no used-block tool yet)
  - HFS+ via raw `dd`
  - Fallback to raw `dd` for others or mounted FS
  - Stores `partition_table.sfdisk` and `manifest.tsv`
- Restore from archive
  - Recreates GPT (compact layout optional)
  - Preserves original PARTUUIDs and disk GUID (label-id)
  - Optional growth of last partition and ext4/NTFS filesystem
  - Partial restore: restore selected partitions only (no GPT change)
- Clean output (non-verbose): progress bars, concise steps, total runtime summary
- Path UX: TAB completion + prompts anchored to chosen mountpoints
- Auto-install on Ubuntu of required tools; self-test mode

### macOS Edition (`adc_macos.sh`)
- Interactive disk selection via `diskutil` (`/dev/diskN`)
- Clone disk → disk with dd and GPT recovery (`gpt recover`)
- Archive disk → per-partition raw images packed in tar
  - Saves `diskutil_list.txt`, `gpt_show.txt`, and `manifest.tsv`
  - Stores Type GUIDs and Partition UUIDs for each partition
- Restore from archive
  - Recreates GPT with preserved indices, Type GUIDs, and Partition UUIDs
  - Optional compact layout (contiguous partitions)
  - Partial restore by partition index
- Uses raw devices (`/dev/rdiskN`) for maximum throughput
- **Apple Silicon optimizations:**
  - Auto-detects M-series chips (M1/M2/M3/M4)
  - Uses performance cores for compression (efficiency cores reserved for I/O)
  - 32MB buffer sizes optimized for unified memory architecture
  - Prefers `zstd` compression (faster on ARM64 with better ratios)

## Why it boots Windows reliably
- On restore, the script preserves original disk GUID and per-partition PARTUUIDs, keeping Windows BCD device references consistent when the clone is used standalone. If both original and clone will be attached at the same time, choose GUID randomization and then repair BCD externally (WinRE `bcdboot`).

## Requirements

### Linux Edition (`clone_minimal.sh`)
- Linux (tested on Ubuntu)
- Tools (auto-installed on Ubuntu when missing):
  - Core: `coreutils`, `util-linux`, `tar`, `gzip`, `pv`, `gdisk`
  - Used-block: `partclone`, `ntfs-3g` (provides `ntfsclone`)
  - Optional: `zstd`, `pigz`
  - macOS FS support (optional): `apfs-fuse`, `hfsprogs` (for HFS+ fsck)

### macOS Edition (`adc_macos.sh`)
- macOS (Darwin)
- Built-in tools: `diskutil`, `dd`, `gzip`, `gpt`
- Optional (auto-installed via Homebrew when missing):
  - `zstd` - fastest compression for Apple Silicon
  - `pigz` - parallel gzip
  - `pv` - progress display
- If Homebrew is not installed, script will prompt with install instructions

## Install
No install needed. Clone/Download this repo and run the appropriate script:

```bash
# On Linux:
sudo ./clone_minimal.sh

# On macOS (auto-detects and launches adc_macos.sh):
sudo ./clone_minimal.sh
# Or directly:
sudo ./adc_macos.sh
```

### First-Time Setup

**macOS:**
- The script will check for optional performance tools (`zstd`, `pigz`, `pv`)
- If Homebrew is installed, it will offer to auto-install missing tools
- If Homebrew is not installed, you can install it from https://brew.sh or manually install tools

**Linux (Ubuntu):**
- The script auto-installs required tools via `apt` on first run
- No user interaction needed for standard tools
- Optional tools can be installed manually: `sudo apt install zstd pigz`

## Usage

### Linux Edition
```bash
sudo ./clone_minimal.sh          # Interactive menu
sudo ./clone_minimal.sh -v       # Verbose mode (diagnostics)
```

**Cloning macOS disks from Linux:**
- The script auto-detects APFS and HFS+ partitions
- Archives them using raw `dd` (no used-block tool available for APFS yet)
- Preserves partition table structure for restore
- Can clone/archive/restore macOS disks to/from Ubuntu

### macOS Edition
```bash
sudo ./adc_macos.sh              # Interactive menu
sudo ./adc_macos.sh -v           # Verbose mode (diagnostics)
```

**Features:**
- Per-partition raw archive with GPT metadata
- GPT recreation with Type GUID and Partition UUID preservation
- Optional compact layout and partial restore
- Uses `/dev/rdiskN` raw devices for speed

### Operations
- Clone (disk → disk)
  - Select SOURCE and TARGET
  - The script uses `dd` with progress (`pv` if available) and repairs GPT backup

- Archive (disk → compressed image)
  - If `partclone`/`ntfsclone` exist, archives each partition into `tar` with compression
  - Saves `partition_table.sfdisk` and `manifest.tsv`
  - Output path prompts support TAB completion; defaults are anchored to the selected destination mountpoint

- Restore (image → disk)
  - Extracts archive, recreates GPT (optionally compact), restores partitions with the right tool
  - Preserves PARTUUIDs and disk GUID; optional grow of last partition + filesystem
  - Partial restore supported: select partitions to restore without modifying GPT

## Performance
- Multi-threaded compression/decompression:
  - Prefers `zstd -T<N> -3` (best ratio/speed)
  - Fallback to `pigz -3 --rsyncable -p <N>` or `gzip -3`
- I/O: `ionice` and readahead tuning
- For best restore speed, set temp directory to RAM or another disk:
```bash
export ADC_TMPDIR=/dev/shm/adc_tmp    # if sufficient RAM
# or
export ADC_TMPDIR=/mnt/fast-ssd/tmp
```

On macOS, the script prefers raw devices (`/dev/rdiskN`) to maximize throughput.

## Cross-Platform Capabilities

### Linux can handle:
- **Windows disks**: Full support with NTFS used-block imaging (`ntfsclone`), GUID preservation, BCD compatibility
- **Linux disks**: ext4 used-block imaging (`partclone.extfs`), all standard Linux filesystems
- **macOS disks**: APFS and HFS+ via raw `dd`, GPT preservation, bootable restore

### macOS can handle:
- **macOS disks**: Native APFS, HFS+, and other Apple formats with full GPT and UUID support
- **Windows disks**: NTFS partitions via raw imaging, GPT preservation
- **Linux disks**: ext4 and other Linux filesystems via raw imaging, GPT preservation

Both editions preserve GPT structure, partition types, and UUIDs for reliable cross-platform boot compatibility.

## Partial Restore (NTFS only or specific partitions)
- Choose Restore → select image → select target disk → when prompted, choose Partial restore and select partition numbers (e.g., `3` for `sdb3`).
- Partition table is untouched; the target partition must exist and be large enough.

## Safety Notes
- Windows: Disable Fast Startup/hibernation before archiving. On restore, preserve GUIDs when the clone will be used standalone. Randomize GUIDs only if both original and clone will be connected together; then repair BCD externally.
- Live cloning of mounted systems is discouraged; the script warns but will proceed if confirmed.

## License
MIT

