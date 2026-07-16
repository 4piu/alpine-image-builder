#!/bin/sh
# Runs a target/profile's setup.sh scripts exactly once, after first-boot
# rootfs expansion has fully completed -- not on every boot, not mid-
# expansion. Installed by build-chroot.sh as /etc/local.d/setup.start
# only when a target/profile actually provides a setup.sh.
#
# expand-rootfs.sh spans multiple reboots before it's actually done, so a
# same-boot-pass local.d ordering isn't enough to guarantee this runs
# after expansion, not alongside or before it -- gate on the completion
# marker expand-rootfs.sh leaves instead.

MARKER=/etc/expand-rootfs.done
SETUP_DIR=/etc/alpine-image-builder/setup.d
LOG_PREFIX="setup:"

if [ ! -f "$MARKER" ]; then
    # Expansion hasn't finished yet -- retry next boot rather than running early.
    exit 0
fi

for s in "$SETUP_DIR"/*; do
    [ -f "$s" ] || continue
    echo "$LOG_PREFIX running $s" | tee /dev/kmsg
    if ! sh "$s"; then
        echo "$LOG_PREFIX $s failed -- leaving hook installed to retry next boot" | tee /dev/kmsg
        exit 1
    fi
done

rm -f /etc/local.d/setup.start
rm -rf "$SETUP_DIR"
