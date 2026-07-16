#!/bin/bash

set -e

# Get script directory and setup variables
cdir="$(dirname "$0")"
chroot_dir="$(readlink -f "$1")"

# If this script fails partway through, remove the incomplete chroot dir so
# a subsequent `make` run doesn't mistake it for a finished rootfs (its
# directory mtime would otherwise satisfy the Makefile dependency as-is).
CHROOT_BUILD_SUCCESS=false
cleanup()
{
    if [ "$CHROOT_BUILD_SUCCESS" != true ] && [ -d "$chroot_dir" ]; then
        echo "build-chroot: build failed, removing incomplete rootfs at $chroot_dir" >&2
        sudo rm -rf "$chroot_dir"
    fi
}
trap cleanup EXIT

sudo mkdir -p "$chroot_dir/etc/apk/keys"
# Provision the Alpine signing keys so apk can verify package signatures
# instead of relying on --allow-untrusted.
sudo cp "$cdir"/apk-keys/*.pub "$chroot_dir/etc/apk/keys/"
# Add repositories
for r in main community; do
    sudo sh -c "echo '$ROOTFS_URL/$r' >> '$chroot_dir/etc/apk/repositories'"
done
# Load extra packages from the resolved target/profile package list, if any
# (PACKAGES_FILE is passed in by the Makefile — it points at whatever
# common/profiles packages.txt applies to this build, not a fixed path
# relative to this script).
if [ -n "${PACKAGES_FILE:-}" ] && [ -f "$PACKAGES_FILE" ]; then
    packages=$(grep -vE '^\s*#' "$PACKAGES_FILE" | xargs)
fi
# Create the chroot base
sudo "$APK" add -p "$chroot_dir" --initdb -U --arch $ALPINE_ARCH alpine-base e2fsprogs-extra $packages
# Enable ttyS0 console
sudo sed -i 's!^#ttyS0!ttyS0!' "$chroot_dir/etc/inittab"

# Add auto-expand rootfs script
if [ -f "$cdir/expand-rootfs.sh" ]; then
    sudo mkdir -p "$chroot_dir/etc/local.d"
    sudo cp "$cdir/expand-rootfs.sh" "$chroot_dir/etc/local.d/expand-rootfs.start"
    sudo chmod +x "$chroot_dir/etc/local.d/expand-rootfs.start"
    # Enable the local service to run at boot
    sudo mkdir -p "$chroot_dir/etc/runlevels/default"
    sudo ln -sf "/etc/init.d/local" "$chroot_dir/etc/runlevels/default/local"
fi

# Install this target/profile's one-time setup.sh scripts (common/ first,
# then the profile's own, per the merge order the Makefile resolves them
# in) plus the generic hook that runs them once expand-rootfs.sh's
# completion marker shows up (§10a).
if [ -n "${SETUP_SCRIPTS:-}" ]; then
    sudo mkdir -p "$chroot_dir/etc/alpine-image-builder/setup.d"
    i=10
    for s in $SETUP_SCRIPTS; do
        dest="$chroot_dir/etc/alpine-image-builder/setup.d/$i-$(basename "$s")"
        sudo cp "$s" "$dest"
        sudo chmod +x "$dest"
        i=$((i + 10))
    done
    sudo cp "$cdir/setup-hook.sh" "$chroot_dir/etc/local.d/setup.start"
    sudo chmod +x "$chroot_dir/etc/local.d/setup.start"
    sudo mkdir -p "$chroot_dir/etc/runlevels/default"
    sudo ln -sf "/etc/init.d/local" "$chroot_dir/etc/runlevels/default/local"
fi

CHROOT_BUILD_SUCCESS=true
