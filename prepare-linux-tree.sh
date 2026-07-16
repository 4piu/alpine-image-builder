#!/bin/bash
# Applies a target/profile's patches and (if present) DTS full-replacement
# override to a cloned kernel tree, resetting it to pristine first.
#
# sources/linux is shared across whichever target/profile you build next
# (see Makefile), so unlike kernel.config fragments -- which never touch
# the tree, only get merged into .config -- patches and a DTS override
# physically mutate tracked files. Switching TARGET/CUSTOM_PROFILE between
# builds has to reset and reapply, not accumulate. A fingerprint of the
# current patch/override set is stamped into $marker_file so repeat
# invocations with an unchanged set are a fast no-op.
#
# Usage: prepare-linux-tree.sh <linux-dir> <marker-file> <kernel-dt-file> <dts-override-or-empty> [patch-file ...]
# Prints CHANGED or UNCHANGED as the last line of stdout; all diagnostic
# logging goes to stderr.

set -euo pipefail

linux_dir="$1"; shift
marker_file="$1"; shift
kernel_dt_file="$1"; shift
dts_override="$1"; shift
patch_files=("$@")

# Resolve to absolute paths before cd-ing into the kernel tree for git ops.
if [ -n "$dts_override" ]; then
    dts_override="$(realpath "$dts_override")"
fi
abs_patches=()
for p in "${patch_files[@]}"; do
    abs_patches+=("$(realpath "$p")")
done

fingerprint_input()
{
    if [ -n "$dts_override" ]; then
        printf 'dts:%s\n' "$dts_override"
        cat "$dts_override"
    fi
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

# Clear the marker before attempting anything: if this run fails partway
# (some patches applied, one didn't), the tree is left in a state that
# matches neither the old fingerprint nor the new one. An absent marker
# correctly says "unknown, reset and reapply from scratch" to the next
# invocation rather than something claiming the tree still matches
# whatever fingerprint was last recorded. $marker_file deliberately lives
# outside $linux_dir (the Makefile passes sources/.tree-prepared, not
# sources/linux/.tree-prepared) so `git clean -fd` below can't touch it
# out from under this logic.
rm -f "$marker_file"

echo "prepare-linux-tree: patch/DTS-override set changed, resetting $linux_dir to pristine before reapplying" >&2
git -C "$linux_dir" checkout -- .
git -C "$linux_dir" clean -fd

if [ -n "$dts_override" ]; then
    vendor_dir="$(dirname "$kernel_dt_file")"
    base="$(basename "$dts_override" .dts)"
    dest="$linux_dir/arch/arm/boot/dts/$vendor_dir/$base.dts"
    echo "prepare-linux-tree: installing DTS override -> $dest" >&2
    cp "$dts_override" "$dest"

    makefile="$linux_dir/arch/arm/boot/dts/$vendor_dir/Makefile"
    if [ -f "$makefile" ] && ! grep -q "$base\.dtb" "$makefile"; then
        # Reuse whichever dtb-y-style guard an existing sun8i-h3-*.dtb entry
        # in this Makefile already builds under, instead of hardcoding a
        # guard variable that could rot across kernel versions -- if this
        # board family already builds under it, the new entry should too.
        guard_line="$(grep -m1 -E 'dtb-.*\+=.*sun8i-h3-' "$makefile" || true)"
        guard="$(printf '%s' "$guard_line" | sed -E 's/^([[:space:]]*dtb-[^+]*\+=).*/\1/')"
        [ -n "$guard" ] || guard="dtb-y +="
        echo "$guard $base.dtb" >> "$makefile"
    fi
fi

for p in "${abs_patches[@]}"; do
    echo "prepare-linux-tree: applying $p" >&2
    if ! git -C "$linux_dir" apply --whitespace=fix "$p"; then
        echo "ERROR: $p did not apply cleanly against $linux_dir -- fix the patch (or the target/profile it lives under) and rebuild" >&2
        exit 1
    fi
done

echo "$new_fingerprint" > "$marker_file"
echo "CHANGED"
