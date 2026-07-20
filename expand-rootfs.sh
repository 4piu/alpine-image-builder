#!/bin/sh
# Auto-expand rootfs script
# This script expands the root partition and filesystem to fill the entire disk

FIRST_SECTOR=2048

LOG_PREFIX="expand-rootfs:"
LOG_OUT="/dev/kmsg"
DONE_MARKER="/etc/expand-rootfs.done"

# Derive the root partition and its parent disk from the kernel command
# line rather than assuming /dev/mmcblk0 — boot.cmd sets root= to whatever
# device this image actually boots from, so read that back instead of
# hardcoding an SD-card-specific device name. Pure shell (no sed/lsblk)
# since BusyBox ash's own case/parameter-expansion globbing is enough and
# this needs to work from a minimal Alpine rootfs.
ROOT_PART=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        root=*) ROOT_PART="${arg#root=}" ;;
    esac
done

if [ -z "$ROOT_PART" ] || [ ! -b "$ROOT_PART" ]; then
    echo "$LOG_PREFIX Could not determine root partition from /proc/cmdline. Exiting." | tee $LOG_OUT
    exit 1
fi

# Strip trailing digits one at a time (safe for both "sda1" and "mmcblk0p1"
# style names — a single %-glob can't do this unambiguously since it takes
# the shortest match, which would strip only the final "0" of "p10").
ROOT_DEV="$ROOT_PART"
while true; do
    case "$ROOT_DEV" in
        *[0-9]) ROOT_DEV="${ROOT_DEV%[0-9]}" ;;
        *) break ;;
    esac
done
# mmcblk/nvme-style names separate the partition number with a "p"
# (mmcblk0p1 -> mmcblk0), plain disk names don't (sda1 -> sda).
case "$ROOT_DEV" in
    *p) ROOT_DEV="${ROOT_DEV%p}" ;;
esac

if [ ! -b "$ROOT_DEV" ]; then
    echo "$LOG_PREFIX Root device $ROOT_DEV not found. Exiting." | tee $LOG_OUT
    exit 1
fi

# Get partition size difference
size_diff=$(( $(blockdev --getsize64 "$ROOT_DEV") - $(blockdev --getsize64 "$ROOT_PART") ))
echo "$LOG_PREFIX Size difference: $size_diff bytes" | tee $LOG_OUT

# If size difference is less than 10MB, assume no need to expand
if [ $size_diff -gt $((10 * 1024 * 1024)) ]; then
    echo "$LOG_PREFIX Expanding root partition" | tee $LOG_OUT

# Use fdisk to expand the partition
fdisk "$ROOT_DEV" <<FDISK_EOF > /dev/null 2>&1
d
n
p
1
$FIRST_SECTOR

w
FDISK_EOF
echo "$LOG_PREFIX Partition table updated. Rebooting to apply changes..." | tee $LOG_OUT
reboot && exit 0
fi

# Resize the filesystem (after reboot)
set -e
echo "$LOG_PREFIX Expanding ext4 filesystem..." | tee $LOG_OUT
resize2fs -f "$ROOT_PART"
# Leave a positive marker before self-removing, so a later one-time
# setup.d/*.sh hook (chained as a second local.d service) has something
# to gate on without depending on this script or its runlevel symlink
# still existing.
touch "$DONE_MARKER"
rm -f /etc/local.d/expand-rootfs.start
reboot
