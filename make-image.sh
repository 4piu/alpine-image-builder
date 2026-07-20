#!/bin/bash

source "$(dirname "$0")/colors.sh"

px=$(which kpartx)
if [ -n "$px" ]; then
	popt="vs"
	mapper="/mapper"
else
	px=$(which partx)
	if [ -n "$px" ]; then
		popt="v"
		mapper=''
	else
		log "Neither kpartx or partx are installed"
		exit 1
	fi
fi
log "using '$px' for partitioning"

need_env_var()
{
    for i in "$@"; do
        (
            set +u
            var="$(eval echo \"\$"$i"\")"
            [ -n "${var}" ] || die "Environment variable ${i} not defined, or empty"
        )
    done
}

# Track if image creation was successful
IMAGE_CREATION_SUCCESS=false

cleanup()
{
    local exit_code=$?
    set +eu

    # We end up in this function at the end of script execution
    [ -n "${ROOT_MOUNT:-}" ] && unmount_filesystems
    [ -n "${LOOP:-}" ] && unmap_partitions

    # Remove broken image file if creation failed
    if [ $exit_code -ne 0 ] && [ "$IMAGE_CREATION_SUCCESS" = false ] && [ -n "${IMAGE:-}" ] && [ -f "${IMAGE}" ]; then
        log "Image creation failed, removing broken image file: ${IMAGE}"
        rm -f "${IMAGE}"
    fi
}

# Trap both EXIT and error signals
trap cleanup EXIT
trap 'exit 1' ERR

create_image_file()
{
    # Calculate size
    #
    # rootfs/overlay are directory trees with potentially thousands of
    # small files -- `du -b` (apparent size, exact byte counts) undercounts
    # what they actually cost on the target ext4 filesystem, since every
    # file rounds up to a whole 4K block and every directory itself
    # consumes at least one more block for its entry list. Plain `du`
    # (no -b) reports real block-rounded disk usage instead, which tracks
    # the target filesystem's actual block consumption far more closely.
    # The single-file items below (kernel/dtb/bootscr/uboot) don't need
    # this -- one large file's rounding waste is at most one block either way.
    rootfs_size=$(sudo du -s --block-size=1 "${ROOTFS_DIR}" | awk '{print $1}')
    kernel_size=$(du -bs "${KERNEL}" | awk '{print $1}')
    dtb_size=$(du -bs "${DTB}" | awk '{print $1}')
    bootscr_size=$(du -bs "${BOOTSCR}" | awk '{print $1}')
    uboot_size=$(du -bs "${UBOOT}" | awk '{print $1}')
    # Overlays are optional (DTBO_DIR may be unset or empty) but do land in
    # /boot like everything else above -- omitting them here previously
    # undercounted the image for any target that actually ships one.
    overlay_size=0
    if [ -n "${DTBO_DIR:-}" ] && [ -d "${DTBO_DIR}" ]; then
        overlay_size=$(du -s --block-size=1 "${DTBO_DIR}" | awk '{print $1}')
    fi
    content_size=$(( rootfs_size + kernel_size + dtb_size + bootscr_size + uboot_size + overlay_size ))

    # A flat margin doesn't track reality: ext4's own overhead (journal,
    # inode table, block bitmaps, the reserved GDT blocks -E resize=
    # sets aside for later online-growing) scales with filesystem size,
    # not with a constant -- mke2fs's default journal size alone steps up
    # in chunks as the filesystem grows (e.g. 16MB once you cross ~256K
    # 4K-blocks, i.e. ~1GB). A fixed 20MB was already tight for a small
    # armv7 zImage-based rootfs; arm64's much larger uncompressed Image
    # blew straight through it. 15% of content, floored at 48MB, scales
    # with actual content instead of guessing a single constant that's
    # either too tight for a big image or wasteful for a small one.
    #
    # The floor specifically has to clear ext4's *fixed* structural cost,
    # not just "some margin" -- measured directly (mkfs a same-sized image,
    # diff total vs. free blocks before writing anything) at exactly the
    # ~165MB content size a wifi-profile orangepi-zero3 rootfs lands at:
    # journal (16MB) + inode table/bitmaps/backups (~13MB) = ~29MB, before
    # a single content byte is written. A 32MB floor left only ~3MB of
    # itself as actual margin after that fixed cost -- not enough to
    # absorb any real-world slop between du's block-rounded estimate and
    # what the target ext4 filesystem actually allocates (its own
    # directory-block layout, xattrs, etc. don't have to match the
    # source filesystem's exactly), which is what tipped this into
    # ENOSPC. 48MB leaves genuine headroom above the measured fixed cost
    # instead of being consumed by it.
    margin_size=$(( content_size * 15 / 100 ))
    min_margin=$(( 48 * 1024 * 1024 ))
    if [ "$margin_size" -lt "$min_margin" ]; then
        margin_size=$min_margin
    fi

    total_size=$(( content_size + margin_size ))
    log "Creating empty image file: ${IMAGE} (${total_size}B content=${content_size}B margin=${margin_size}B)"
    truncate -s "${total_size}" "${IMAGE}"
    sync
}

write_partition_table()
{
    log "Creating partition table"
    sfdisk "${IMAGE}" <<__EOF__
# partition table of ${IMAGE}
unit: sectors

${IMAGE}p1 : start=2048, Id=83
__EOF__
}

map_partitions()
{
    # Hack to get what loop device kpartx uses for the mappings
    # /dev/mapper/loopXp1 /dev/mapper/loopXp2 /dev/mapper/loopXp3 /dev/mapper/loopXp4
    log "Mapping image partitions"
    LOOP=$($px -a$popt "${IMAGE}" | grep -Po 'loop[[:digit:]]+' | head -1)
}

unmap_partitions()
{
    log "Unmapping image partitions"
    $px -d$popt /dev/${LOOP}
    losetup -d /dev/${LOOP} || true
    LOOP=""
}

install_uboot()
{
    log "Installing u-boot to image (offset ${UBOOT_WRITE_OFFSET} KiB)"
    (set -x; dd if="${UBOOT}" of="${IMAGE}" bs=1024 seek="${UBOOT_WRITE_OFFSET}" conv=fsync,notrunc)
    sync
}

create_filesystems()
{
    ROOT_DEVICE="/dev/${mapper}${LOOP}p1"
    # -b 4096: without this, mke2fs auto-picks a 1024-byte block size for the
    # tiny pre-expand partition, which caps reserved GDT blocks at blocksize/4
    # = 256 (a hard on-disk limit of the resize inode's indirect block) --
    # not enough to grow to a real SD card. Forcing 4096 raises that cap to
    # 1024, and -E resize= then reserves enough headroom within it to
    # online-resize up to 1TiB later via expand-rootfs.sh.
    (set -x; mkfs.ext4 -b 4096 -E resize=268435456 "${ROOT_DEVICE}")
}

mount_filesystems()
{
    ROOT_MOUNT="$(mktemp -d /tmp/root.XXXXXX)"
    (set -x; mount "${ROOT_DEVICE}" "${ROOT_MOUNT}")
}

unmount_filesystems()
{
    log "Unmounting and cleaning up temp mountpoints"
    if [ -n "${ROOT_MOUNT:-}" ]; then
        umount "${ROOT_MOUNT}"
        rmdir "${ROOT_MOUNT}"
    fi
}

fill_filesystems()
{
    (set -x; cp -a "${ROOTFS_DIR}/." "${ROOT_MOUNT}/")
    mkdir -p "${ROOT_MOUNT}/boot"
    (set -x; cp "${BOOTSCR}" "${KERNEL}" "${DTB}" "${ROOT_MOUNT}/boot/")

    # Copy device tree overlays if they exist
    if [ -n "${DTBO_DIR:-}" ] && [ -d "${DTBO_DIR}" ] && [ "$(ls -A "${DTBO_DIR}" 2>/dev/null)" ]; then
        log "Copying device tree overlays from ${DTBO_DIR} to /boot/overlay"
        mkdir -p "${ROOT_MOUNT}/boot/overlay"
        (set -x; cp "${DTBO_DIR}"/*.dtbo "${ROOT_MOUNT}/boot/overlay/" 2>/dev/null || true)
    else
        log "No device tree overlays found in ${DTBO_DIR:-output/overlay}"
    fi
}

main()
{
    need_env_var UBOOT UBOOT_WRITE_OFFSET BOOTSCR KERNEL DTB ROOTFS_DIR IMAGE

    # Enable strict error handling
    set -euo pipefail

    log "Starting image creation: ${IMAGE}"

    create_image_file
    write_partition_table
    install_uboot
    map_partitions
    create_filesystems
    mount_filesystems
    fill_filesystems

    # Mark image creation as successful
    IMAGE_CREATION_SUCCESS=true
    log "Image creation completed successfully: ${IMAGE}"
}

main
