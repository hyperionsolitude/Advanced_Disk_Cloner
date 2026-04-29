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

## Offline-Friendly Usage (Preloaded Packages)
To run on machines with no internet, pre-download Ubuntu dependency packages on an online machine:

```bash
sudo ./clone_minimal.sh --bundle-deps /path/to/adc-debs
```

Copy that folder to the offline machine, then run:

```bash
sudo ./clone_minimal.sh --offline-bundle /path/to/adc-debs
```

You can also export `ADC_DEB_BUNDLE` and use `--offline`.

### Single-file offline package archive (recommended)
Create one archive that contains all required packages:

```bash
sudo ./clone_minimal.sh --bundle-deps-archive /path/to/adc-offline-pkgs.tar.gz
```

You can also pass only a directory path (no file name); the script auto-creates a timestamped archive name in that directory.

Then on a fresh/offline system:

```bash
sudo ./clone_minimal.sh --offline-archive /path/to/adc-offline-pkgs.tar.gz
```

## Build Installable Debian Package (.deb)
You can generate a **true offline all-in-one** `.deb` installer directly from the script.  
The produced package embeds required runtime packages and installs them during `dpkg -i`.

```bash
sudo ./clone_minimal.sh --build-deb /path/to/output-dir/
```

Or provide an explicit package filename:

```bash
sudo ./clone_minimal.sh --build-deb /path/to/advanced-disk-cloner.deb
```

Install on target system:

```bash
sudo dpkg -i /path/to/advanced-disk-cloner*.deb
```

Note: dependency installation from embedded offline packages is applied on first app launch (not during `dpkg -i`) to avoid dpkg lock conflicts.

After install, launch friendly UI:

```bash
advanced-disk-cloner
```

You can also force dialog mode directly:

```bash
sudo ./clone_minimal.sh --ui
```

## Usage
- Verbose mode (diagnostics):
```bash
sudo ./clone_minimal.sh -v
```
- Self-test:
```bash
sudo ./clone_minimal.sh --self-test
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

## Safety Notes
- Windows: Disable Fast Startup/hibernation before archiving. On restore, preserve GUIDs when the clone will be used standalone. Randomize GUIDs only if both original and clone will be connected together; then repair BCD externally.
- Live cloning of mounted systems is discouraged; the script warns but will proceed if confirmed.

## License
MIT

