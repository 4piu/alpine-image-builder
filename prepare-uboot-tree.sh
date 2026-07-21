#!/bin/bash
# Applies a target/profile's U-Boot patches to a cloned U-Boot tree,
# resetting it to pristine first. Mirrors prepare-linux-tree.sh's own
# reset/reapply/fingerprint contract exactly, minus the kernel-only DTS
# full-replacement handling -- U-Boot has no equivalent escape hatch here.
#
# sources/u-boot is shared across whichever target/profile you build next
# (see Makefile), so like the kernel's patches, these physically mutate
# tracked files. Switching TARGET/PROFILE between builds has to reset and
# reapply, not accumulate. A fingerprint of the current patch set is
# stamped into $marker_file so repeat invocations with an unchanged set
# are a fast no-op.
#
# Usage: prepare-uboot-tree.sh <uboot-dir> <marker-file> [patch-file ...]
# Prints CHANGED or UNCHANGED as the last line of stdout; all diagnostic
# logging goes to stderr.

set -euo pipefail

source "$(dirname "$0")/colors.sh"

uboot_dir="$1"; shift
marker_file="$1"; shift
patch_files=("$@")

# Resolve to absolute paths before cd-ing into the U-Boot tree for git ops.
abs_patches=()
for p in "${patch_files[@]}"; do
    abs_patches+=("$(realpath "$p")")
done

fingerprint_input()
{
    for p in "${abs_patches[@]}"; do
        printf 'patch:%s\n' "$p"
        cat "$p"
    done
}

new_fingerprint="$(fingerprint_input | sha256sum | cut -d' ' -f1)"
current_fingerprint="none"
[ -f "$marker_file" ] && current_fingerprint="$(cat "$marker_file")"

if [ "$new_fingerprint" = "$current_fingerprint" ]; then
    echo "UNCHANGED"
    exit 0
fi

# Clear the marker before attempting anything -- same reasoning as
# prepare-linux-tree.sh: a partial failure should leave the next
# invocation seeing "unknown, reset and reapply from scratch", not a
# marker claiming a fingerprint the tree doesn't actually match.
# $marker_file deliberately lives outside $uboot_dir (the Makefile passes
# sources/.uboot-tree-prepared, not sources/u-boot/.uboot-tree-prepared)
# so `git clean -fd` below can't touch it out from under this logic.
rm -f "$marker_file"

echo "prepare-uboot-tree: patch set changed, resetting $uboot_dir to pristine before reapplying" >&2
git -C "$uboot_dir" checkout -- .
git -C "$uboot_dir" clean -fd

for p in "${abs_patches[@]}"; do
    echo "prepare-uboot-tree: applying $p" >&2
    if ! git -C "$uboot_dir" apply --whitespace=fix "$p"; then
        echo_err "${CCred}${CCbold}ERROR: $p did not apply cleanly against $uboot_dir -- fix the patch (or the target/profile it lives under) and rebuild${CCend}"
        exit 1
    fi
done

echo "$new_fingerprint" > "$marker_file"
echo "CHANGED"
