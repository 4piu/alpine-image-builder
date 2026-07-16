#!/bin/bash

readonly CCred=`printf '\033[0;31m'`
readonly CCyellow=`printf '\033[0;33m'`
readonly CCgreen=`printf '\033[92m'`
readonly CCblue=`printf '\033[94m'`
readonly CCcyan=`printf '\033[36m'`
readonly CCend=`printf '\033[0m'`
readonly CCbold=`printf '\033[1m'`
readonly CCunderline=`printf '\033[4m'`


echo_err()
{
    >&2 echo "$@"
}

die()
{
    echo_err "${CCred}${CCbold}ERROR: $@${CCend}"
    exit 2
}

log()
{
    echo_err "${CCblue}[${CCend}${CCgreen}*${CCend}${CCblue}]${CCend} $@"
}

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
    margin_size=$(( 20 * 1024 * 1024 )) # 20MB margin
    rootfs_size=$(sudo du -bs "${ROOTFS_DIR}" | awk '{print $1}')
    kernel_size=$(du -bs "${KERNEL}" | awk '{print $1}')
    dtb_size=$(du -bs "${DTB}" | awk '{print $1}')
    bootscr_size=$(du -bs "${BOOTSCR}" | awk '{print $1}')
    uboot_size=$(du -bs "${UBOOT}" | awk '{print $1}')
    total_size=$(( rootfs_size + kernel_size + dtb_size + bootscr_size + uboot_size + margin_size ))
    log "Creating empty image file: ${IMAGE} (${total_size}B)"
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
