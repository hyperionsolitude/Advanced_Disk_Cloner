# Advanced Disk Cloner (Minimal)

Single-file, menu-driven disk cloner/archiver/restorer.

Features:
- Numbered disk selection (supports /dev/sdX and /dev/nvme*n1)
- Clone disk → disk with robust dd + GPT backup fix
- Archive disk → compressed image (.img.gz) with partition table dump (.sfdisk)
- Archive (used-block) → per-partition images packed in .tar.gz when tools available
- Restore image → disk
- Live-system safety: warns before live clone/archive

Usage
```bash
sudo ./clone_minimal.sh
```

Notes
- For Windows volumes, disable Fast Startup/Hibernation.
- The archive mode names images after source device by default (e.g., `./sdb.img.gz`).

Prerequisites and auto-install
- Auto-install is supported only on Ubuntu (apt). On Ubuntu, the script will attempt to install if missing:
  - core tools: `coreutils`, `util-linux`, `gzip`, `tar`, `pv`, `gdisk`
  - used-block tools (optional): `partclone`, `ntfs-3g`
- On non-Ubuntu systems, auto-install is skipped. Please install the above packages via your distro's package manager before running.

Used-block archive details
- If `partclone` (for ext4) and/or `ntfsclone` (for NTFS) are available, archive mode creates a `.tar.gz` containing:
  - `partition_table.sfdisk` (dump)
  - `manifest.tsv` (partition list and tool used)
  - Per-partition images: ext4 via `partclone.extfs`, NTFS via `ntfsclone`, others fall back to raw `dd`.
- Restore detects the tarball format, recreates the partition table, and restores each partition with the appropriate tool.
- If those tools are not available, it falls back to the legacy full-disk `dd | gzip` image.

License
MIT

