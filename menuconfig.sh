#!/bin/bash
# Opens `menuconfig` against a target's currently-resolved config (kernel
# or U-Boot -- any Kconfig/kbuild-style tree works the same way) and
# captures only the delta -- see target/README.md. menuconfig's own exit
# prompt ("save your configuration?") is what decides whether a session's
# changes are kept or thrown away; saying "no" there leaves .config (and
# so the captured delta) unchanged, i.e. empty.
#
# `scripts/diffconfig`'s own output format isn't valid merge_config.sh
# fragment syntax (it prints "CONFIG_X old -> new" summary lines, not
# "CONFIG_X=value" assertions), so this uses `make savedefconfig`
# instead -- its output *is* already valid fragment syntax -- taken
# before and after the menuconfig session, keeping only the lines that
# are new.
#
# Known limitation: this only captures additions/changes (comm -13). An
# option you explicitly turn OFF that a lower layer (board defconfig,
# common/, or an earlier recipe) turned on isn't represented as a
# removal here -- add a `# CONFIG_X is not set` line to the resulting
# fragment by hand if you need that.
#
# Usage: menuconfig.sh <src-dir> <output-fragment-path>
# <src-dir> is the kernel or U-Boot source tree (must already have a
# .config). Captures the delta into <output-fragment-path>, appending if
# it already exists (so previously-captured content isn't lost).

set -euo pipefail

src_dir="$1"
out_fragment="$2"

before_config="$src_dir/.config.menuconfig-before"
after_config="$src_dir/.config.menuconfig-after"
before_defconfig="$src_dir/defconfig.menuconfig-before"
after_defconfig="$src_dir/defconfig.menuconfig-after"

cleanup()
{
    rm -f "$before_config" "$after_config" "$before_defconfig" "$after_defconfig" \
        "$before_defconfig.sorted" "$after_defconfig.sorted" "$src_dir/defconfig"
}
trap cleanup EXIT

cp "$src_dir/.config" "$before_config"

make -C "$src_dir" menuconfig
cp "$src_dir/.config" "$after_config"

# Snapshot the minimal defconfig for the "after" state.
make -C "$src_dir" savedefconfig
cp "$src_dir/defconfig" "$after_defconfig"

# Snapshot the minimal defconfig for the "before" state too, so the
# delta below is relative to where this session actually started, not
# to Kconfig's own defaults.
cp "$before_config" "$src_dir/.config"
make -C "$src_dir" savedefconfig
cp "$src_dir/defconfig" "$before_defconfig"

sort "$before_defconfig" > "$before_defconfig.sorted"
sort "$after_defconfig" > "$after_defconfig.sorted"
delta="$(comm -13 "$before_defconfig.sorted" "$after_defconfig.sorted")"

# Advance .config to the "after" (captured) state -- it's currently at
# "before" from the snapshot restore above.
cp "$after_config" "$src_dir/.config"

if [ -z "$delta" ]; then
    echo "No changes made -- $out_fragment left untouched." >&2
    exit 0
fi

if [ -s "$out_fragment" ]; then
    printf '\n# --- captured %s ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out_fragment"
    echo "$delta" >> "$out_fragment"
    echo "Appended new changes to $out_fragment -- review it before committing." >&2
else
    echo "$delta" > "$out_fragment"
    echo "Captured to $out_fragment -- review it before committing." >&2
fi
