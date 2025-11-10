#!/bin/bash
#
# zfs-disk-sanity.sh
#
# Complete pre-ingest validation script for TrueNAS / Linux ZFS disks.
#
# Features:
#   - Safe PuTTY-friendly output (ASCII only, no emojis)
#   - Colorized output
#   - Logging to /var/log/newdisk-test-YYYYMMDD-HHMM.log
#   - Optional --safe-mode (no destructive actions)
#   - Pre-checks: root, device exists, device not in any zpool
#   - SMART test handling + detect running SMART tests
#   - SMR vs CMR detection
#   - Destructive confirmation
#   - badblocks write-mode test with ETA
#   - wipefs cleanup
#   - Newbie-friendly comments everywhere
#   - Made with the help of ChatGPT
#

######################################################################
# Color Setup
######################################################################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

info()  { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOGFILE"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOGFILE"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOGFILE"; }
good()  { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOGFILE"; }

######################################################################
# Logging Setup
######################################################################
DATESTAMP=$(date +"%Y%m%d-%H%M")
LOGFILE="/var/log/newdisk-test-$DATESTAMP.log"

# touch creates an empty file OR fails if path isn't writable.
touch "$LOGFILE" || {
    echo -e "${RED}[ERROR] Cannot write to /var/log. Run as root.${RESET}"
    exit 1
}

######################################################################
# Parse Options
######################################################################
SAFE_MODE=false

while [[ "$1" == --* ]]; do
    case "$1" in
        --safe-mode)
            SAFE_MODE=true
            warn "SAFE MODE ENABLED — no destructive tests will run."
            shift
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

DRIVE="$1"

######################################################################
# 0. Basic input check
######################################################################
if [ -z "$DRIVE" ]; then
    error "Usage: $0 [--safe-mode] /dev/sdX"
    exit 1
fi

######################################################################
# 1. Require root
######################################################################
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root."
    exit 1
fi

######################################################################
# 2. Basic device name sanity check
# We only accept device paths that typically represent real block devices.
######################################################################
case "$DRIVE" in
    /dev/sd*|/dev/hd*|/dev/vd*|/dev/da*|/dev/nvme*n*)
        ;;
    *)
        error "$DRIVE does not look like a valid block device path."
        exit 1
        ;;
esac

######################################################################
# 3. Check that the device exists using -b (is a block device)
######################################################################
if [ ! -b "$DRIVE" ]; then
    error "$DRIVE does not exist or is not a block device."
    info "Available block devices:"
    lsblk | tee -a "$LOGFILE"
    exit 1
fi

good "Device exists: $DRIVE"

######################################################################
# 4. Identify persistent /dev/disk/by-id name (used by ZFS)
######################################################################
REALPATH=$(readlink -f "$DRIVE")
BYID=$(readlink -f /dev/disk/by-id/* 2>/dev/null | grep -w "$REALPATH" | head -n 1)
[ -z "$BYID" ] && BYID="$REALPATH"
info "Persistent identifier: $BYID"

######################################################################
# 5. Ensure drive is not already in any zpool
######################################################################
if zpool status -v 2>/dev/null | grep -q "$BYID"; then
    error "Drive appears to be part of an existing ZFS pool!"
    exit 1
fi
good "Drive is not part of a zpool."

######################################################################
# 6. SMR vs CMR Detection
######################################################################
info "Detecting SMR / CMR characteristics…"
MODEL=$(smartctl -i "$DRIVE" | grep -E "Model|Device Model" -m1 | awk -F ':' '{print $2}' | xargs)
ROTATION=$(smartctl -i "$DRIVE" | grep "Rotation Rate" | awk -F ':' '{print $2}' | xargs)

SMR_STATUS="Unknown"
if hdparm -I "$DRIVE" 2>/dev/null | grep -qi "zoned"; then
    SMR_STATUS="Likely SMR (zoned device)"
elif [[ "$MODEL" =~ ST4000DM004|ST8000DM004|ST6000DM003|ST6000DM004 ]]; then
    SMR_STATUS="Known SMR model"
else
    SMR_STATUS="Likely CMR"
fi

info "Model: $MODEL"
info "Rotation Rate: $ROTATION"
warn "SMR Status: $SMR_STATUS"

######################################################################
# 7. SMART test in-progress detection
######################################################################
info "Checking for currently-running SMART tests…"
SMART_PROGRESS=$(smartctl -a "$DRIVE" | grep "Self-test routine in progress")

if [ -n "$SMART_PROGRESS" ]; then
    warn "A SMART test is already running:"
    warn "$SMART_PROGRESS"
    read -p "Wait for it to finish? (y/N): " wait_choice
    if [[ "$wait_choice" =~ ^[Yy]$ ]]; then
        info "Waiting for ongoing SMART test to complete…"
        while true; do
            PROGRESS=$(smartctl -a "$DRIVE" | grep "Self-test routine in progress")
            if [ -z "$PROGRESS" ]; then
                good "SMART test finished."
                break
            else
                info "Still running: $PROGRESS"
            fi
            sleep 60
        done
    else
        error "Aborting because SMART test is already running."
        exit 1
    fi
else
    good "No SMART tests currently running."
fi

######################################################################
# 8. Run SMART Short & Long Tests (Non-destructive)
######################################################################
info "Starting SMART SHORT test…"
smartctl -t short "$DRIVE"
sleep 120   # give it time to finish
smartctl -a "$DRIVE" | tee -a "$LOGFILE"

read -p "Run SMART LONG test? (y/N): " longs
if [[ "$longs" =~ ^[Yy]$ ]]; then
    info "Starting SMART LONG test…"
    smartctl -t long "$DRIVE"
    warn "Long test running in background. Check later with: smartctl -a $DRIVE"
fi

######################################################################
# SAFE MODE ENDS HERE — no destructive actions
######################################################################
if $SAFE_MODE; then
    warn "SAFE MODE enabled — destructive tests skipped."
    exit 0
fi

######################################################################
# 9. Destructive Confirmation
######################################################################
echo -e "${RED}"
echo "======================================================"
echo " DESTRUCTIVE TESTS IMMEDIATELY AHEAD"
echo " - badblocks -w will ERASE ALL DATA"
echo " - wipefs -af will wipe ALL filesystem/ZFS signatures"
echo "======================================================"
echo -e "${RESET}"
read -p "Type YES to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    warn "User aborted before destructive operations."
    exit 0
fi

######################################################################
# 10. Estimate badblocks test duration
######################################################################
DRIVE_SIZE_BYTES=$(blockdev --getsize64 "$DRIVE")
TOTAL_WRITES=$(( DRIVE_SIZE_BYTES * 4 ))  # four passes for -w mode

GB_SIZE=$(( DRIVE_SIZE_BYTES / 1024 / 1024 / 1024 ))

info "Drive size: ${GB_SIZE}GB"
info "Estimated total write volume (4 passes): $(( TOTAL_WRITES / 1024 / 1024 / 1024 ))GB"

######################################################################
# 11. Run destructive badblocks test with ETA
######################################################################
info "Starting badblocks destructive write test…"
badblocks -wsv "$DRIVE" &
BB_PID=$!

(
    START=$(date +%s)
    while kill -0 "$BB_PID" 2>/dev/null; do
        WRITTEN=$(awk '/write_bytes/ {print $2}' /proc/$BB_PID/io 2>/dev/null)

        if [ -n "$WRITTEN" ] && [ "$WRITTEN" -gt 0 ]; then
            PERCENT=$(( WRITTEN * 100 / TOTAL_WRITES ))
            NOW=$(date +%s)
            ELAPSED=$(( NOW - START ))
            ETA=$(( (ELAPSED * TOTAL_WRITES / WRITTEN) - ELAPSED ))
            ETA_FMT=$(printf "%02d:%02d:%02d" $((ETA/3600)) $(((ETA%3600)/60)) $((ETA%60)))

            info "Badblocks progress: ${PERCENT}%   ETA: $ETA_FMT"
        fi

        sleep 30
    done
) &
wait $BB_PID

good "Badblocks test completed."

######################################################################
# 12. wipefs cleanup
######################################################################
info "Clearing old filesystem/ZFS signatures…"
wipefs -af "$DRIVE"
good "wipefs completed."

######################################################################
# Finish
######################################################################
good "Disk validation complete!"
info "Logfile saved to: $LOGFILE"
