# newdisk-check.sh

A Bash script for **validating new or used disks** before adding them to a ZFS pool, such as a RAIDZ2 configuration.  
Designed to work on TrueNAS, Linux, and BSD systems. Fully **PuTTY-friendly**, colorized, and safe for terminals that do not support emojis.

---

## Features

- Root and device validation checks
- Detects if the disk is already part of a ZFS pool
- SMART health check (short and long tests)
- Detects ongoing SMART tests and waits if necessary
- SMR vs CMR detection
- Optional **safe mode** (non-destructive)
- Destructive tests (badblocks 4-pass write test)
- Automatic wiping of old filesystem and ZFS signatures
- Badblocks estimated time remaining (ETA)
- Colorized output for [INFO], [WARN], [ERROR], [OK]
- ASCII-only output, PuTTY-safe

---

## Requirements

- Bash 4+
- `smartctl` (from `smartmontools`)
- `badblocks`
- `wipefs` (from `util-linux`)
- Root privileges

---

## Installation

Download the script:

    curl -O https://raw.githubusercontent.com/darkice83/newdisk-check/main/newdisk-check.sh

Make it executable:

    chmod +x newdisk-check.sh

Optionally, move it to a system path:

    sudo mv newdisk-check.sh /usr/local/sbin/

---

## Usage

Run the script on a device:

    sudo ./newdisk-check.sh /dev/sdX

### Options

- `--safe-mode`  
  Run only non-destructive checks (SMART, SMR/CMR, device validation). Skips badblocks and wipefs.

- `--log-file <file>` *(optional, future feature)*  
  Log all output to a specified file.

---

## Example

Full destructive test:

    sudo ./newdisk-check.sh /dev/sdb

Non-destructive / safe mode:

    sudo ./newdisk-check.sh --safe-mode /dev/sdb

---

## Output

- `[INFO]` — General information
- `[WARN]` — Warnings or non-fatal issues
- `[ERROR]` — Fatal errors
- `[OK]` — Successful checks

All output is **ANSI colorized** for terminals that support it, but will display cleanly in PuTTY or vi.

---

## Notes

- Destructive tests **will erase the entire disk**.
- Always verify the correct device (`/dev/sdX`) before running.
- Recommended to run in **safe mode** first for used disks.
- Compatible with TrueNAS, Linux, and BSD ZFS systems.

---

## Author

Shawn’s GPT-5 assistant for initial commit, future edits by Shawn

---

## License

MIT License
