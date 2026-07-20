# Build targets

A target is a board plus whatever customization you want — one
directory holds both, so there's a single place to look, and one
workspace can hold as many boards as you're building for without them
colliding.

```
target/<name>/
  board.env              # which board this target builds
  common/                 # applied to every build of this target
    kernel.config
    uboot.config
    recipes.txt            # tools/recipes/<name> to merge in, one per line
    boot.cmd
    overlays/*.dts
    dts/*.dts
    patches/*.patch
    firmware/*              # extra files for the target's rootfs /lib/firmware
    packages.txt
    setup.sh               # runs once, after first-boot rootfs expansion
  profiles/<profile-name>/  # named, opt-in customization sets
    kernel.config
    uboot.config
    recipes.txt
    boot.cmd
    overlays/*.dts
    dts/*.dts
    patches/*.patch
    firmware/*
    packages.txt
    setup.sh
```

A target with nothing under `common/`/`profiles/` builds a stock image
— no patches applied beyond `board.env`'s own facts. Everything under
`common/`/`profiles/<name>/` is optional; add only what you actually
want to change.

### Current targets in this repo

Nothing below is special-cased in the tooling — these are just examples
worth looking at, not a description of how the system works (that's the
rest of this doc). `zeropi` has nothing under `common/`. `nanopi-neo`
carries one always-on overlay (`common/overlays/sun8i-h3-usbhost1.dts`)
that enables its second USB host controller, off in the stock device
tree. Both targets also carry a real `profiles/wifi/` — `recipes.txt` +
`packages.txt` for an RTL8821CU USB dongle — worth a look as a working
example before writing your own. `orangepi-zero3` is the first arm64
target in this repo (Allwinner H618), and it needs `ATF_PLAT`/
`ATF_VERSION` set in `board.env` since that SoC boots through ARM
Trusted Firmware, unlike the other two targets here. Its onboard
wifi/BT chip has no mainline driver at all, so `common/` vendors one
via `patches/*.patch` (see "Kernel patches" below), plus the firmware
that driver needs via `firmware/*` (see below), instead of just a
`kernel.config` fragment — worth a look if you're bringing up a chip
mainline doesn't support yet, not just enabling one it already does.
Unlike the other two targets, it's always on here rather than gated
behind a profile: this board only ships with this one wifi/BT chip
onboard, so there's no alternative-hardware case a profile would be
selecting between.

Every artifact resolves the same way, board manifest → `common/` →
`profiles/$(PROFILE)/`, but *how* each stage combines differs by
kind:

| Artifact | `common/` + `profiles/<name>/` | Both present? |
| --- | --- | --- |
| `kernel.config` | fragments, merged via `merge_config.sh` | both apply, profile's wins on conflict |
| `uboot.config` | fragments, merged via `merge_config.sh` (same idea, U-Boot's own copy of the script) | both apply, profile's wins on conflict |
| `recipes.txt` | resolved to `tools/recipes/<name>.config`, merged alongside this tier's `kernel.config` | both apply, profile's wins on conflict |
| `patches/*.patch` | applied in order | both apply, common's first |
| `overlays/*.dts` | compiled and loaded independently | both apply (accumulate) |
| `firmware/*` | copied into the rootfs's `/lib/firmware/` | both apply |
| `packages.txt` | concatenated | both apply |
| `setup.sh` | run in order, once | both run, common's first |
| `boot.cmd` | full file replacement | profile's wins, common's ignored |
| `dts/*.dts` | full file replacement | profile's wins, common's ignored |

## `board.env`

Plain `KEY=value` file — no shell quoting, no `$(...)`, nothing
Make-specific, so it's readable directly by both the Makefile and any
shell scripts that need it. Fields:

- `UBOOT_BOARD_DEFCONFIG` — the upstream U-Boot defconfig name for this
  exact board, *without* the `_defconfig` suffix, e.g. `nanopi_neo`
  (U-Boot's own defconfigs always follow `<name>_defconfig`, so the
  Makefile appends that automatically).
- `KERNEL_DT_FILE` — path to the board's device tree blob under the
  kernel source tree (e.g. `allwinner/sun8i-h3-nanopi-neo.dtb`).
- `KERNEL_DEFCONFIG` — the kernel's defconfig *make target, in full*
  (e.g. `sunxi_defconfig`), unlike `UBOOT_BOARD_DEFCONFIG` above. Not
  every arch/platform follows the `<name>_defconfig` convention the same
  way — some build from one generic per-arch `defconfig` rather than a
  per-board-family file (arm64/Allwinner-sunxi boards currently in this
  repo are like that: `arch/arm64/configs/defconfig`, no `sunxi_` prefix
  to it) — so this field has to hold whatever the real target name
  actually is, not just an assumed prefix. Check the kernel source's own
  `arch/<ARCH>/configs/` for your SoC.
- `UBOOT_WRITE_OFFSET` — where `make-image.sh` `dd`s the built U-Boot
  binary into the image, in 1024-byte blocks (i.e. the raw `seek=`
  value). This is entirely platform-specific — there's no project-wide
  default, and getting it wrong means U-Boot doesn't start at all. Check
  your SoC's boot-ROM/SPL documentation (or an existing working image
  for the same platform) for the right value; every Allwinner
  sunxi-platform board in this repo so far uses `8` (8 KiB), which is a
  fact about that one SoC family, not a fact about this tooling.
- `ALPINE_ARCH` — the Alpine architecture tag for this board's CPU
  (e.g. `armv7`, `aarch64`).
- `ARCH`, `CROSS_COMPILE`, `UBOOT_VERSION` — architecture, cross-compiler
  prefix, and U-Boot version for this board. `ARCH` also selects the
  kernel image format and U-Boot boot command (`zImage`/`bootz` for
  `arm`, `Image`/`booti` for `arm64`) -- see `KERNEL_IMAGE_FILE`/
  `BOOT_CMD_NAME` near the top of the Makefile if adding a third `ARCH`.
- `ATF_PLAT`, `ATF_VERSION` — **optional**, both or neither. Boards with
  an EL3 firmware stage (ARM Trusted Firmware, "ATF"/"TF-A") need a
  `bl31.bin` built and handed to U-Boot via `BL31=`; boards without one
  leave both unset and none of this applies. `ATF_PLAT` is upstream
  `trusted-firmware-a`'s platform name for the SoC — check `plat/` at
  the pinned `ATF_VERSION` tag for the right one (e.g. `plat/allwinner/`
  for Allwinner chips: `sun50i_h616` covers H616/H618, `sun50i_h6`
  covers H6, `sun50i_a64` covers A64/H5 — a different vendor has its own
  `plat/<vendor>/` subdirectory). Whether a board needs this at all is a
  property of the SoC, not something to guess: U-Boot's own board
  support code says so explicitly if you know where to look — for
  Allwinner it's `SUNXI_BL31_BASE`'s default in
  `arch/arm/mach-sunxi/Kconfig` under that board's `MACH_SUN50I_*` (zero
  means no ATF, non-zero means it's required); a different vendor's
  U-Boot port will have its own equivalent under its own
  `arch/arm/mach-<vendor>/Kconfig`. Skipping this when it's actually
  needed doesn't fail cleanly — it fails deep inside U-Boot's `binman`
  step instead, so check first rather than finding out the hard way.

Resolved per field — command-line/`workflow_dispatch` overrides win
first, then this file, then (if this file sets `BOARD=<other-target>`)
the referenced target's `board.env`, then error if still unresolved.
`BOARD=` lets you name a target anything you want while reusing another
target's board facts instead of retyping them, and lets you override
individual fields on top of that reference (e.g. a revision variant with
a different `KERNEL_DT_FILE`).

## Adding a board

Add `target/<new-board-id>/board.env` with every field set (no `BOARD=`
reference needed, since there's nothing yet to reference) and open a PR.
Pick a clear, kebab-case name.

## Building

```
make build TARGET=<name>
make build TARGET=<name> PROFILE=<profile-name>
```

## Kernel config: `kernel.config`

A fragment, not a full `.config` — `common/kernel.config` and
`profiles/<name>/kernel.config` are merged onto the board's stock
`KERNEL_DEFCONFIG` via the kernel's own `scripts/kconfig/merge_config.sh`
(common's first, so a profile can override a symbol common/ also sets),
then `olddefconfig` resolves whatever the merge leaves ambiguous.
Nothing here is required for a bootable image — an empty target builds
with the completely stock defconfig.

**The build verifies every requested symbol actually took effect, and
fails (listing exactly what didn't stick) if not** — an unmet dependency
or a symbol that doesn't exist in this `KERNEL_VERSION` never silently
ships the wrong config.

### `recipes.txt`: pulling in `tools/recipes/` automatically

List recipe names, one per line (`#` comments, blank lines ignored, same
convention as `packages.txt`):

```
# target/<name>/profiles/wifi/recipes.txt
wifi-8821cu
```

Each name resolves to `tools/recipes/<name>.config` and merges in
alongside this tier's own `kernel.config` (exact order below). A recipe
name that doesn't exist under `tools/recipes/` fails the build
immediately, before anything else happens.

This is the *automatic* counterpart to
`tools/recipes/apply-recipes.sh`: `recipes.txt` gets resolved fresh on
every build (nothing to keep in sync, but also nothing you can hand-edit
afterward without it getting overwritten by the recipe again). Use
`apply-recipes.sh` instead when you want to take a recipe as a
*starting point* and then customize it — it merges once into your
`kernel.config` and produces ordinary, committed content from then on,
indistinguishable from anything you wrote by hand.

Full merge order for a single build:
`common/kernel.config` → `common/recipes.txt`'s recipes (in the order
listed) → `profiles/<name>/kernel.config` → `profiles/<name>/recipes.txt`'s
recipes (in the order listed).

### `make kernel-menuconfig` / `make uboot-menuconfig`: create, modify, or just view config

Don't hand-edit a fragment against 150k lines of `.config`. Use
`menuconfig` and let tooling capture just the delta — same mechanism for
both the kernel and U-Boot, just pointed at a different tree and a
different output filename:

```
make kernel-menuconfig TARGET=<name>                        # captures into common/kernel.config
make kernel-menuconfig TARGET=<name> PROFILE=<profile-name>  # captures into that profile's kernel.config
make uboot-menuconfig TARGET=<name>                          # captures into common/uboot.config
make uboot-menuconfig TARGET=<name> PROFILE=<profile-name>   # captures into that profile's uboot.config
```

This opens `menuconfig` against the target's currently-resolved config
(base defconfig plus whatever `common/`/the named profile already
contribute), then compares a `savedefconfig` snapshot from before and
after the session and captures the delta into the corresponding
`kernel.config`/`uboot.config` — creating it if it doesn't exist yet,
*appending* to it if it does, so an earlier capture in the same file
isn't lost.

**Just want to look, not change anything?** `menuconfig` itself asks
"save your new configuration?" when you exit — answer no and nothing
changes, so nothing gets captured either (the delta is empty). That
prompt is the actual view/save decision point; there's no separate
"preview" mode here on top of it.

**Known limitation:** the captured delta only contains additions/changes.
An option you explicitly turn *off* that a lower layer (the board
defconfig, `common/`, or an earlier capture) turned on isn't represented
as a removal — add a `# CONFIG_X is not set` line to the resulting
fragment by hand if you need that. Review the captured fragment before
committing either way; `menuconfig` sessions can pull in more than you
meant to change.

## U-Boot config: `uboot.config`

Same idea as kernel config, minus the `recipes.txt` tier (that's Linux
driver Kconfig, not U-Boot): `common/uboot.config` and
`profiles/<name>/uboot.config` are fragments merged onto the board's
stock `UBOOT_BOARD_DEFCONFIG` via U-Boot's own copy of
`scripts/kconfig/merge_config.sh` (common's first, profile's wins on
conflict), then `olddefconfig` resolves the rest. Empty target builds
with the completely stock defconfig, same as kernel config.

Reasons you might actually need this even for an already-supported
board: tuning DRAM timing for a board revision or stability issue
(e.g. `CONFIG_DRAM_CLK` on Allwinner sunxi boards — the equivalent
symbol is platform-specific), trimming unrelated features to stay under
SPL's size budget after adding something else, or changing boot
behavior (`bootdelay`, boot-device priority, a recovery USB/network boot
path, a watchdog kick before Linux takes over).

**The build verifies every requested symbol actually took effect here
too**, same reasoning and same mechanism as `kernel.config` above.

## Kernel patches: `patches/*.patch`

Applied to the kernel source tree before configuring, common's first
then the profile's. **Must apply cleanly — a patch that doesn't apply
fails the build outright, not a warning.** Write them in `git diff`/`git
format-patch` format (they're applied with `git apply` against a real
git checkout).

Switching `TARGET`/`PROFILE` between builds resets the shared
kernel source tree to pristine and reapplies patches from scratch —
handled automatically, nothing to do on your end beyond writing patches
that apply cleanly against the `KERNEL_VERSION` this target builds.

## DTS full replacement: `dts/*.dts`

The escape hatch for a board revision the base device tree doesn't
describe at all — not a fragment, a **full replacement** of the board's
`.dts`. At most one file is meaningful; if both `common/` and a profile
provide one, the profile's wins outright. The file is copied into the
kernel tree next to the stock DTS and built automatically; `boot.cmd`'s
`@DTB_FILE@` and the final image both switch to the override's filename
automatically.

For most boards you don't need this — a device tree *overlay* (below)
covers adding/changing a few nodes without replacing the whole file.

## Device tree overlays: `overlays/*.dts`

Overlay-syntax (`/plugin/;`) fragments, compiled to `.dtbo` and applied
by U-Boot to the FDT before the kernel boots — the right tool for things
that need to be in place before the relevant subsystem finishes probing
(a display module's boot log, enabling USB-on-GPIO). Unlike
`boot.cmd`/`dts`, these **accumulate**: `common/overlays/*.dts` and
`profiles/<name>/overlays/*.dts` both apply if both are present.
Overlay *selection* is decided at build time (baked into `boot.scr`);
toggling one means a rebuild, not a runtime edit.

```
make overlays TARGET=<name> PROFILE=<profile-name>   # compile only
make overlay-check TARGET=<name> PROFILE=<profile-name>   # compile + preview the merged DT
```

`overlay-check` needs `fdtoverlay` (not part of `make check-tools`'s
required list — it's only needed for this optional review step).

A fragment can target a node by path (`target-path = "/soc/whatever@..."`)
without any extra setup. Targeting by label (`target = <&whatever>`), or
referencing another node by label from *inside* a fragment's own
properties (a `<&pio ...>` gpio reference, for instance), needs the
board's base `.dtb` to be built with dtc's `-@` symbol-table flag —
mainline doesn't turn this on for every board, only ones upstream
already expects to carry overlays. If `fdtoverlay` fails with `base
blob does not have a '/__symbols__' node`, that's what's missing; fix
it with a one-line kernel patch (see `orangepi-zero3/common/patches/`
for a real example) setting `DTC_FLAGS_<dtb-stem> := -@` in the
relevant `arch/*/boot/dts/.../Makefile`, not by rewriting the overlay
to avoid labels.

## `firmware/*`

Files copied verbatim into the rootfs's `/lib/firmware/` — for a driver
whose firmware isn't already carried by an apk package
(`linux-firmware-*` and similar) and has to be vendored in this
target/profile itself. Most drivers don't need this: check for an
existing `linux-firmware-*` apk first, and prefer that — it's already
tracked, versioned, and updated independently of this repo. Reach for
`firmware/*` when the driver itself isn't in a package either (a
vendored out-of-tree driver via `patches/*.patch`, for instance) and
the firmware has to travel with it.

See `orangepi-zero3/common/firmware/wcnmodem.bin` for a real
example. It is *not* decoded from the vendored driver's own
`unisocwcn/fw/wcnmodem.bin.hex` (a multi-chip-variant pack meant to
cover several Marlin3/Marlin3-Lite/Marlin3E chip steppings from one
file) — confirmed on real hardware, that pack has no image for the
Marlin3-Lite stepping this board's AW859A module actually ships
(chipid `0x2355b001`), only Marlin3 and Marlin3E ones, so the driver's
own chip-to-image matching (`marlin_judge_images()` in
`patches/0001-vendor-uwe5622-driver.patch`) can never find a usable
entry for it. The real, working firmware here was instead pulled from
a live Armbian (6.12.23) boot on the same physical board — confirmed
booting that image gets a working `wlan0`, then `/lib/firmware/uwe5622/
wcnmodem.bin` from that install was copied out over SSH. Different chip
steppings genuinely need different firmware; when the vendored driver
source doesn't carry the one you need, a known-working distro image for
the *same physical board* is a legitimate source to pull the real
binary from — prefer it over guessing at a substitute image.

## `boot.cmd`

A full replacement of `boot.cmd.template` for changing actual boot
*logic*, not just parameters — most customization needs don't need this;
`overlays/` covers device tree changes, and `@DTB_FILE@`/`@KERNEL_FILE@`/
`@BOOT_CMD@`/the overlay list are substituted into whichever `boot.cmd`
is active regardless of source. `@KERNEL_FILE@`/`@BOOT_CMD@` exist so a
custom `boot.cmd` still works across architectures without hand-picking
`zImage`/`bootz` vs `Image`/`booti` — use them instead of hardcoding
either if you write your own. Same override precedence as `dts/*.dts`:
profile's wins over common's wins over the shipped default.

Kernel/DTB/overlay load addresses in the shipped template are
`${kernel_addr_r}`/`${fdt_addr_r}`/`${fdtoverlay_addr_r}` — U-Boot's own
per-board environment defaults, not hardcoded values — so they're
already sized correctly for whatever this board's own U-Boot port
considers safe (arm64's `Image` is uncompressed and can be tens of MB;
a board with less DRAM needs everything packed tighter). Don't
hardcode literal addresses in a custom `boot.cmd` — a large enough
kernel silently overwriting a DTB loaded too close to it in memory is a
real failure mode this project has already hit once, not a
hypothetical.

The one thing still assumed by the shipped template is booting from
`mmc 0:1` — a board that boots from a different device needs its own
`boot.cmd` (`common/boot.cmd`) rather than relying on the default.

## `packages.txt`

Extra `apk` packages installed into the rootfs, one per line (`#` starts
a comment). `common/` and the profile's are concatenated, not merged by
name — duplicate or conflicting entries are `apk`'s problem to resolve,
not this tooling's.

## `setup.sh`: one-time post-expansion hook

A script baked into the image and run **exactly once**, after first-boot
rootfs expansion has fully completed — not on every boot, not
mid-expansion. If both `common/setup.sh` and the profile's exist, both
run, common's first, as two separate steps of the same hook. A script
that exits non-zero leaves the hook installed to retry next boot rather
than silently dropping the rest of your setup.
