# Advanced Disk Cloner (Minimal)

Single-file, menu-driven disk cloner/archiver/restorer.

Features:
- Numbered disk selection (supports /dev/sdX and /dev/nvme*n1)
- Clone disk → disk with robust dd + GPT backup fix
- Archive disk → compressed image (.img.gz) with partition table dump (.sfdisk)
- Restore image → disk
- Optional pre-op shrink (ext4/NTFS) for speed/space; partition boundaries unchanged
- Optional post-clone ext4 grow-in-place and set reserved to 1%
- Live-system safety: skips shrinking/growing the live root; warns before live clone/archive

Usage
```bash
sudo ./clone_minimal.sh
```

Notes
- Shrinking ext4/NTFS requires the filesystem to be unmounted. For root (/), boot from a live USB first.
- For Windows volumes, disable Fast Startup/Hibernation.
- The archive mode names images after source device by default (e.g., `./sdb.img.gz`).

License
MIT

