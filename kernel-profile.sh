#!/bin/bash
# Captures only the delta from an interactive `menuconfig` session as a
# small, reviewable kernel.config fragment -- see target/README.md.
#
# `scripts/diffconfig`'s own output format isn't valid merge_config.sh
# fragment syntax (it prints "CONFIG_X old -> new" summary lines, not
# "CONFIG_X=value" assertions), so this uses `make savedefconfig` instead
# -- its output *is* already valid fragment syntax -- taken before and
# after the menuconfig session, and keeps only the lines that are new.
#
# Known limitation: this only captures additions/changes (comm -13). An
# option you explicitly turn OFF that a lower layer (board defconfig or
# common/) turned on isn't represented as a removal here -- add a
# `# CONFIG_X is not set` line to the resulting fragment by hand if you
# need that.
#
# Usage: kernel-profile.sh <linux-dir> <output-fragment-path>

set -euo pipefail

linux_dir="$1"
out_fragment="$2"

before_config="$linux_dir/.config.kernel-profile-before"
after_config="$linux_dir/.config.kernel-profile-after"
before_defconfig="$linux_dir/defconfig.kernel-profile-before"
after_defconfig="$linux_dir/defconfig.kernel-profile-after"

cleanup()
{
    rm -f "$before_config" "$after_config" "$before_defconfig" "$after_defconfig" \
        "$before_defconfig.sorted" "$after_defconfig.sorted" "$linux_dir/defconfig"
}
trap cleanup EXIT

cp "$linux_dir/.config" "$before_config"

make -C "$linux_dir" menuconfig
cp "$linux_dir/.config" "$after_config"

# Snapshot the minimal defconfig for the "after" state.
make -C "$linux_dir" savedefconfig
cp "$linux_dir/defconfig" "$after_defconfig"

# Snapshot the minimal defconfig for the "before" state, then restore
# .config to the post-menuconfig state -- that's what should remain in
# place for any build that follows this command.
cp "$before_config" "$linux_dir/.config"
make -C "$linux_dir" savedefconfig
cp "$linux_dir/defconfig" "$before_defconfig"
cp "$after_config" "$linux_dir/.config"

sort "$before_defconfig" > "$before_defconfig.sorted"
sort "$after_defconfig" > "$after_defconfig.sorted"
comm -13 "$before_defconfig.sorted" "$after_defconfig.sorted" > "$out_fragment"

echo "Captured delta to $out_fragment -- review it before committing." >&2
