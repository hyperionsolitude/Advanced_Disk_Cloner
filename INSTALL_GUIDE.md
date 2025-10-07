# Installation Guide

## Quick Start

### macOS
```bash
cd /path/to/Advanced_Disk_Cloner
sudo ./adc_macos.sh
```

On first run, you'll see:
```
=== Advanced Disk Cloner (macOS Edition) ===
Checking prerequisites...
Missing optional tool: pigz
Install pigz via Homebrew? (y/N): y
Installing pigz via Homebrew...
Missing optional tool: pv
Install pv via Homebrew? (y/N): y
Installing pv via Homebrew...
Darwin support active: per-partition raw archive/restore with GPT preservation.
Hardware: Apple M4 (10 cores, 16GB RAM)
Optimizations: 32m buffer, 4-thread compression, zstd compressor
```

### Linux (Ubuntu)
```bash
cd /path/to/Advanced_Disk_Cloner
sudo ./clone_minimal.sh
```

On first run, Ubuntu auto-installs all required tools:
```
=== Advanced Disk Cloner ===
Checking prerequisites...
Ensuring required commands are available...
Installing packages via apt: partclone ntfs-3g gdisk pv pigz zstd
...
Archive mode: used-block ext4=yes, ntfs=yes, apfs/hfs+=no/no (fallback to raw for others)
```

## Prerequisites by Platform

### macOS
**Built-in (no install needed):**
- `dd`, `gzip`, `tar`, `diskutil`, `gpt`

**Optional (auto-installed via Homebrew):**
- `zstd` - Best compression for Apple Silicon (recommended)
- `pigz` - Parallel gzip (2-3x faster than gzip)
- `pv` - Progress bar display

**Install Homebrew (if not installed):**
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Manual installation:**
```bash
brew install zstd pigz pv
```

### Linux (Ubuntu)
**Auto-installed on first run:**
- `coreutils`, `util-linux`, `tar`, `gzip`, `pv`
- `gdisk`, `partclone`, `ntfs-3g`, `e2fsprogs`
- `pigz`, `zstd` (optional but recommended)

**For macOS filesystem support (optional):**
```bash
sudo apt install apfs-fuse hfsprogs
```

## Performance Recommendations

### For macOS Users
✅ **Strongly recommended:** Install `zstd`
- 20-30% faster compression on Apple Silicon
- 10-15% better compression ratios
- Lower CPU usage vs pigz/gzip

```bash
brew install zstd pigz pv
```

### For Ubuntu Users
✅ **Recommended:** Install optional tools
```bash
sudo apt install zstd pigz pv
```

## Verification

### Check installed tools (macOS):
```bash
./adc_macos.sh -v 2>&1 | head -20
```

### Check installed tools (Linux):
```bash
./clone_minimal.sh --self-test
```

## Performance Impact

| Tool | Speed Impact | Archive Size Impact |
|------|-------------|---------------------|
| zstd | 2-3x faster (M-series) | 10-15% smaller |
| pigz | 2-3x faster vs gzip | Same as gzip |
| pv | Visual progress only | No impact |

## Troubleshooting

### macOS: "Homebrew not found"
1. Install Homebrew from https://brew.sh
2. Restart terminal
3. Re-run the script

### Linux: "Missing required commands"
1. Update package list: `sudo apt update`
2. Manually install: `sudo apt install <package-name>`
3. Re-run the script

### Both: "Permission denied"
- Always run with `sudo`: `sudo ./adc_macos.sh` or `sudo ./clone_minimal.sh`
- Disk operations require root access
