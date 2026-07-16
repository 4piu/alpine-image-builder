# Customizing the kernel

This is the tribal-knowledge reference for anyone touching
`target/<name>/common/kernel.config`, `target/<name>/profiles/<name>/kernel.config`,
`menuconfig` (via `make kernel-menuconfig`), or the on-device incremental-build
escape hatch below. See `target/README.md` for the mechanics (how
fragments merge, how to capture a delta) — this doc is about what to
actually put in a fragment and why.

## The one gotcha that bites almost everyone: module compression

Alpine's `kmod`/`modprobe` expect kernel modules to be zstd-compressed.
**If your change adds or enables *any* loadable module** (`=m`, not
`=y`) — a wifi driver, anything picked up from a recipe in
`tools/recipes/` — add this to your fragment:

```
CONFIG_MODULE_COMPRESS=y
CONFIG_MODULE_COMPRESS_ZSTD=y
```

`menuconfig` does **not** enable this as a dependency of building a
module — it's easy to flip on the driver you wanted, get a clean build,
and then find `modprobe` silently fails to load it on the actual board.
This isn't forced on by default: a stock, unmodified target ships
without it, since a base image that never loads a module shouldn't
carry a deviation from stock nobody asked for. It only becomes *your*
problem the moment your own fragment adds a module — at which point it's
squarely your problem, and now you know about it.

## Symbols that must stay builtin (`=y`), never a module (`=m`)

This project's boot design — not something Alpine itself demands, see
below — boots with `noinitrd` and `root=` passed directly in `bootargs`
(no initramfs to load a module from before root is mounted). That means
the root filesystem driver and the storage controller driver have to be
compiled in, always:

- `CONFIG_EXT4_FS=y` — the root filesystem.
- `CONFIG_MMC_BLOCK=y` — MMC/SD block device support.
- `CONFIG_MMC_SUNXI=y` — the sunxi/H3 MMC host controller specifically.
  A different SoC family needs its own host controller driver built in
  the same way; check what stock `KERNEL_DEFCONFIG` sets before assuming
  it's already covered.

`menuconfig` won't stop you from turning any of these into a module or
switching them off — if a board stops booting after a kernel config
change, check these first.

## What Alpine itself actually needs

Less than you'd expect, and already satisfied by any current mainline
defconfig: `CONFIG_DEVTMPFS=y` + `CONFIG_DEVTMPFS_MOUNT=y` (Alpine's
`mdev`-based `/dev` population depends on both) have been the default in
virtually every mainline defconfig for well over a decade. Nothing else
checked — `CONFIG_TMPFS`, `CONFIG_FW_LOADER` and its firmware-compression
options, `CONFIG_PROC_FS`/`CONFIG_SYSFS` — needed anything beyond what
stock already provides. musl/OpenRC don't impose anything unusual on the
kernel side either; that's a userspace-only distinction, invisible to the
kernel build.

## Escape hatch: native on-device incremental builds

For a one-off driver you don't want to make a whole profile for, and
don't want to wait out a full cross-compiled rebuild for: Alpine ships
the complete kernel build toolchain via `apk` (`build-base`,
`linux-headers`, `bc`, `flex`, `bison`, `openssl-dev`, `elfutils-dev`,
`ncurses-dev` for `menuconfig`) — the kernel build doesn't depend on host
libc, so musl isn't an obstacle (this is how Alpine's own
`linux-lts`/`linux-edge` and postmarketOS build kernels natively). A
**full** fresh build natively on an H3 board (dual/quad Cortex-A7,
~1.2GHz, 512MB–1GB RAM) is realistically 1–3+ hours, not reasonable as a
regular workflow — but an **incremental single-driver build**, starting
from the `.config` your image actually shipped with, is minutes even on
this hardware:

```sh
apk add build-base linux-headers bc flex bison openssl-dev elfutils-dev ncurses-dev
# fetch the matching kernel source, drop your shipped .config in as .config
make oldconfig      # starts from a known-good base instead of drifting
make menuconfig      # flip the one symbol you need
make modules_prepare
make M=drivers/net/wireless/realtek/rtw88 modules
make modules_install
```

This only works cleanly if `make oldconfig` starts from the *exact*
`.config` your image shipped with — if you don't have it, `oldconfig`
drifts and you're back to guessing. Keep a copy of the resolved
`sources/linux/.config` from whichever build you actually flashed.

## Recipes: a starting point, not a preset

`tools/recipes/` holds ready-to-copy fragments for common needs, backed
by real repo-tracked files rather than just wiki prose — see
`tools/recipes/README.md`. They're never applied automatically; copy the
fragment (or run the recipe's script) yourself and review the diff
before building.
