# Advanced Disk Cloner (Minimal)

Single-file, menu-driven disk cloner/archiver/restorer optimized for Linux live environments. Focused on safety, speed, and Windows/Linux boot compatibility.

## Highlights
- Interactive disk selection (`/dev/sdX`, `/dev/nvme*n1`)
- Clone disk → disk via `dd` with GPT backup repair (`sgdisk -e`)
- Archive disk → used-block, per-partition images
  - ext4 via `partclone.extfs`
  - NTFS via `ntfsclone`
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

## Why it boots Windows reliably
- On restore, the script preserves original disk GUID and per-partition PARTUUIDs, keeping Windows BCD device references consistent when the clone is used standalone. If both original and clone will be attached at the same time, choose GUID randomization and then repair BCD externally (WinRE `bcdboot`).

## Requirements
- Linux (tested on Ubuntu)
- Tools (auto-installed on Ubuntu when missing):
  - Core: `coreutils`, `util-linux`, `tar`, `gzip`, `pv`, `gdisk`
  - Used-block: `partclone`, `ntfs-3g` (provides `ntfsclone`)
  - Optional: `zstd`, `pigz`

## Install
No install needed. Clone/Download this repo and run the script:
```bash
sudo ./clone_minimal.sh
```

## Usage
- Verbose mode (diagnostics):
```bash
sudo ./clone_minimal.sh -v
```

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

## Partial Restore (NTFS only or specific partitions)
- Choose Restore → select image → select target disk → when prompted, choose Partial restore and select partition numbers (e.g., `3` for `sdb3`).
- Partition table is untouched; the target partition must exist and be large enough.

## Diagnostics
- A helper script collects boot diagnostics:
```bash
sudo bash collect_win_boot_diag.sh /dev/sdX /path/to/log.txt
```
- Captures `lsblk/blkid`, `sfdisk -d`, `gdisk -l`, `efibootmgr -v`, ESP contents, and recent kernel logs.

## Safety Notes
- Windows: Disable Fast Startup/hibernation before archiving. On restore, preserve GUIDs when the clone will be used standalone. Randomize GUIDs only if both original and clone will be connected together; then repair BCD externally.
- Live cloning of mounted systems is discouraged; the script warns but will proceed if confirmed.

## License
MIT

