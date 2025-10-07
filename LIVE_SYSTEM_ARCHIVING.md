# Live System Archiving Guide

## Can I Archive a Live macOS System?

**Short answer:** Yes, but it's **not recommended** for production backups.

**Long answer:** The script will detect if you're archiving your boot disk and warn you with alternatives.

## What Happens When You Archive a Live System

### ⚠️ The Warning You'll See:

```
SOURCE: /dev/disk0

⚠️  WARNING: You are operating on the BOOT DISK (contains running macOS)
    - Archiving a live system may produce inconsistent snapshots
    - Files being written during archive may be partially captured
    - System files may be in use and locked

💡 RECOMMENDED: Boot from another disk or macOS Recovery to archive this disk
    - Hold Cmd+R during boot for Recovery Mode
    - Boot from external USB with macOS installer
    - Use Target Disk Mode from another Mac

Proceed with READ-ONLY archiving of live system anyway? (y/N):
```

## Risks of Live System Archiving

### ❌ **Potential Issues:**

1. **Inconsistent state**
   - Files being written during archive may be half-written
   - Database files (Mail, Photos, Safari) may be corrupted in archive
   - Application caches may be inconsistent

2. **APFS snapshots interference**
   - macOS creates automatic APFS snapshots
   - Archive captures current state, not a clean snapshot
   - System Volume Sealed System (SSV) complexity

3. **Locked files**
   - Some system files may be in use and locked
   - VM swap files, kernel extensions may be inaccessible
   - Results in incomplete archive

4. **Boot issues after restore**
   - Restored system may not boot cleanly
   - May require Recovery Mode repairs
   - FileVault encryption keys may be mismatched

### ✅ **What Usually Works:**

- **Read operations** - Archive/Clone operations are READ-ONLY on source
- **Most user files** - Documents, Downloads, Desktop typically fine
- **Applications** - Most apps archive correctly
- **Basic restore** - Often works but may need fsck/first aid

## Safe Alternatives (RECOMMENDED)

### 1. **macOS Recovery Mode** (Best Option)
```bash
# Reboot and hold Cmd+R until Apple logo appears
# Open Terminal from Utilities menu
# Mount external drive for archive destination
cd /Volumes/ExternalDrive/Advanced_Disk_Cloner
./adc_macos.sh

# Select your main disk as source
# Archive to external drive
```

**Pros:**
- ✅ System disk is NOT running (read-only mount)
- ✅ No active processes writing to disk
- ✅ Clean, consistent snapshot
- ✅ Bootable restore guaranteed

**Cons:**
- ⏱️ Requires reboot
- 📁 Need archive destination accessible from Recovery

### 2. **Boot from External USB/Disk**
```bash
# Create bootable macOS installer on USB
# Boot holding Option key, select USB
# Run script from USB or another external drive
```

**Pros:**
- ✅ Complete isolation from source disk
- ✅ Can archive entire internal disk
- ✅ Multiple Macs can use same USB

**Cons:**
- ⏱️ Need to create bootable USB first
- 💾 Requires 16GB+ USB drive

### 3. **Target Disk Mode** (Mac to Mac)
```bash
# Connect Macs with Thunderbolt/USB-C cable
# Boot source Mac holding 'T' key
# Source Mac appears as external disk on host Mac
# Run script on host Mac
```

**Pros:**
- ✅ Source disk completely offline
- ✅ Fast Thunderbolt speeds
- ✅ No software installation needed

**Cons:**
- 🔌 Requires two Macs
- 📱 Requires appropriate cable

### 4. **Single User Mode**
```bash
# Reboot holding Cmd+S
# Mount filesystem read-only:
/sbin/mount -uw /
# Run minimal operations
```

**Pros:**
- ⚡ Quick access
- 🔒 Minimal processes running

**Cons:**
- ⌨️ Command-line only
- 🔧 Advanced users only

## When Live Archiving is Acceptable

### ✅ **Use Cases Where It's OK:**

1. **Quick emergency backup before risky operation**
   - Better than no backup
   - Plan to verify and redo properly later

2. **Non-critical development/test machine**
   - Can afford some inconsistency
   - Easy to recreate if restore fails

3. **User data only (not system)**
   - Archive external drives with data
   - Skip system disk entirely

4. **Combined with Time Machine**
   - Use both: Time Machine for system + this for full disk image
   - Redundancy covers live archive risks

## Best Practices for Live Archiving

If you **must** archive a live system:

### 1. **Minimize activity:**
```bash
# Quit all applications
# Disable Time Machine temporarily
sudo tmutil disable

# Stop Spotlight indexing
sudo mdutil -a -i off

# After archive completes:
sudo tmutil enable
sudo mdutil -a -i on
```

### 2. **Use lowest priority:**
The script already uses `ionice` where available, but close heavy apps.

### 3. **Verify after archive:**
```bash
# Extract and check key files
tar -tzf /path/to/archive.tar.gz | grep -E "(Applications|Users)" | head -20

# Test restore to external disk first
# Boot from external to verify it works
```

### 4. **Archive when system is idle:**
- Late night/early morning
- After reboot (minimal processes)
- No downloads/installations running

## Comparison Matrix

| Method | Safety | Speed | Convenience | Recommended |
|--------|--------|-------|-------------|-------------|
| Recovery Mode | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ✅ YES |
| External Boot | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ | ✅ YES |
| Target Disk Mode | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ | ✅ YES |
| Live Archive | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⚠️ Caution |

## Summary

### ✅ **Can you do it?** 
Yes, the script allows it with a warning.

### ⚠️ **Should you do it?** 
Only if:
- It's an emergency backup
- You understand the risks
- You plan to verify the archive
- You have time to redo it properly later

### 💡 **What should you do?**
**Boot from Recovery Mode** (Cmd+R on startup) and archive from there for:
- Production systems
- Important data
- Guaranteed bootable restore
- Maximum safety

The extra 5 minutes to reboot into Recovery is worth the peace of mind! 🛡️
