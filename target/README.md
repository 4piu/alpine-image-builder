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
    recipes.txt            # tools/recipes/<name> to merge in, one per line
    boot.cmd
    overlays/*.dts
    dts/*.dts
    patches/*.patch
    packages.txt
    setup.sh               # runs once, after first-boot rootfs expansion
  profiles/<profile-name>/  # named, opt-in customization sets
    kernel.config
    recipes.txt
    boot.cmd
    overlays/*.dts
    dts/*.dts
    patches/*.patch
    packages.txt
    setup.sh
```

A target with nothing under `common/`/`profiles/` builds a stock,
vanilla image — no patches applied beyond `board.env`'s own facts.
Everything under `common/`/`profiles/<name>/` is optional; add only what
you actually want to change. `nanopi-neo` and `zeropi` are both plain
vanilla by default (nothing under `common/`) but each also carries a
real `profiles/wifi/` — `recipes.txt` + `packages.txt` for an RTL8821CU
USB dongle — worth a look as a working example before writing your own.

Every artifact resolves the same way, board manifest → `common/` →
`profiles/$(CUSTOM_PROFILE)/`, but *how* each stage combines differs by
kind — worth being explicit about, since "merge" means something
different for a Kconfig fragment than for a whole file:

| Artifact | `common/` + `profiles/<name>/` | Both present? |
| --- | --- | --- |
| `kernel.config` | fragments, merged via `merge_config.sh` | both apply, profile's wins on conflict |
| `recipes.txt` | resolved to `tools/recipes/<name>.config`, merged alongside this tier's `kernel.config` | both apply, profile's wins on conflict |
| `patches/*.patch` | applied in order | both apply, common's first |
| `overlays/*.dts` | compiled and loaded independently | both apply (accumulate) |
| `packages.txt` | concatenated | both apply |
| `setup.sh` | run in order, once | both run, common's first |
| `boot.cmd` | full file replacement | profile's wins, common's ignored |
| `dts/*.dts` | full file replacement | profile's wins, common's ignored |

## `board.env`

Plain `KEY=value` file — no shell quoting, no `$(...)`, nothing
Make-specific, so it's readable directly by both the Makefile and any
shell scripts that need it. Fields:

- `UBOOT_BOARD_DEFCONFIG` — the upstream U-Boot defconfig name for this
  exact board (e.g. `nanopi_neo`). Board-specific: encodes DRAM
  timing/size for this exact PCB. No generic default exists.
- `KERNEL_DT_FILE` — path to the board's device tree blob under the
  kernel source tree (e.g. `allwinner/sun8i-h3-nanopi-neo.dtb`).
- `UBOOT_WRITE_OFFSET` — where `make-image.sh` `dd`s the built U-Boot
  binary into the image, in 1024-byte blocks (i.e. the raw `seek=`
  value). `8` (8 KiB) for sunxi/H3 boards with SPL — this is where the
  boot ROM expects the SPL header, not a tunable.
- `ALPINE_ARCH` — the Alpine architecture tag for this board's CPU
  (e.g. `armv7`).
- `ARCH`, `CROSS_COMPILE`, `KERNEL_DEFCONFIG`, `UBOOT_VERSION` — today
  identical across every target here (there's only one SoC family
  supported so far), but kept as explicit fields rather than a separate
  shared layer — duplication at this file size costs nothing, and it
  means adding a board or a new architecture is always "add a
  `board.env`," never a code change.

Resolved per field — command-line/`workflow_dispatch` overrides win
first, then this file, then (if this file sets `BOARD=<other-target>`)
the referenced target's `board.env`, then error if still unresolved.
`BOARD=` is what lets you name a target anything you want
(`target/whatever_pi_user_name_it/`) while reusing another target's
board facts instead of retyping them, and lets you override individual
fields on top of that reference (e.g. a revision variant with a
different `KERNEL_DT_FILE`) without that being a special case.

## Adding a board

Add `target/<new-board-id>/board.env` with every field set (no `BOARD=`
reference needed, since there's nothing yet to reference) and open a PR.
Names are ones this project invents (e.g. `nanopi-neo`) — nothing about
a board is a stable, hardware-derived identifier, so pick something
clear and kebab-case.

## Building

```
make build TARGET=<name>
make build TARGET=<name> CUSTOM_PROFILE=<profile-name>
```

## Kernel config: `kernel.config`

A fragment, not a full `.config` — `common/kernel.config` and
`profiles/<name>/kernel.config` are merged onto the board's stock
`KERNEL_DEFCONFIG` via the kernel's own `scripts/kconfig/merge_config.sh`
(common's first, so a profile can override a symbol common/ also sets),
then `olddefconfig` resolves whatever the merge leaves ambiguous. Nothing
here is required for a bootable image — an empty target builds with the
completely stock defconfig.

**The build verifies every requested symbol actually stuck, and fails if
one didn't.** Neither `merge_config.sh` nor `olddefconfig` reliably fails
the build on its own when an unmet dependency (or a symbol that doesn't
exist in this `KERNEL_VERSION`) silently drops a requested value —
`verify-kernel-config.sh` checks the final `.config` against every
fragment's requested lines (using the *last* request for a given symbol
across all fragments, so an intentional profile-overrides-common
override is never mistaken for a failure) and hard-errors, listing every
mismatch, if anything didn't take effect.

### `recipes.txt`: pulling in `tools/recipes/` automatically

List recipe names, one per line (`#` comments, blank lines ignored, same
convention as `packages.txt`):

```
# target/<name>/profiles/wifi/recipes.txt
wifi-8821cu
zstd-modules
```

Each name resolves to `tools/recipes/<name>.config` and merges in
alongside this tier's own `kernel.config` (exact order below). A recipe
name that doesn't exist under `tools/recipes/` fails the build
immediately, before anything else happens, not partway through a kernel
build.

This is the *automatic* counterpart to
`tools/recipes/apply-recipes.sh`: `recipes.txt` gets resolved fresh on
every build (nothing to keep in sync, but also nothing you can hand-edit
afterward without it getting overwritten by the recipe again — which is
fine, since you're not supposed to hand-edit a recipe's own content
anyway). Use `apply-recipes.sh` instead when you want to take a recipe as
a *starting point* and then customize it — it merges once into your
`kernel.config` and produces ordinary, committed content from then on,
indistinguishable from anything you wrote by hand.

Full merge order for a single build:
`common/kernel.config` → `common/recipes.txt`'s recipes (in the order
listed) → `profiles/<name>/kernel.config` → `profiles/<name>/recipes.txt`'s
recipes (in the order listed) — i.e. common tier entirely, then profile
tier entirely, matching every other artifact's common-then-profile rule;
within each tier, hand-written `kernel.config` applies before that tier's
recipes.

### Capturing a kernel config change

Don't hand-edit a fragment against 150k lines of `.config`. Use
`menuconfig` and let tooling capture just the delta:

```
make kernel-profile TARGET=<name> CUSTOM_PROFILE=<profile-name>
```

This opens `menuconfig` against the target's currently-resolved config,
then compares a `savedefconfig` snapshot from before and after the
session and writes only the new/changed lines to
`target/<name>/profiles/<profile-name>/kernel.config`. `CUSTOM_PROFILE`
is required — there's no way to name an anonymous capture.

**Known limitation:** this only captures additions/changes. An option
you explicitly turn *off* that a lower layer (the board defconfig, or
`common/`) turned on isn't represented as a removal — add a
`# CONFIG_X is not set` line to the resulting fragment by hand if you
need that. Review the captured fragment before committing either way;
`menuconfig` sessions can pull in more than you meant to change.

## Kernel patches: `patches/*.patch`

Applied to the kernel source tree before configuring, common's first
then the profile's. **Must apply cleanly — a patch that doesn't apply
fails the build outright, not a warning.** Write them in `git diff`/`git
format-patch` format (they're applied with `git apply` against a real
git checkout).

`sources/linux` is shared across whichever target/profile you build
next (only one board is ever actively built at a time — see the
Makefile), so unlike `kernel.config` fragments, which never touch the
source tree, patches physically mutate tracked files. Switching
`TARGET`/`CUSTOM_PROFILE` between builds resets the tree to pristine and
reapplies from scratch rather than accumulating — handled automatically,
nothing to do on your end beyond writing patches that apply cleanly
against the `KERNEL_VERSION` this target builds.

## DTS full replacement: `dts/*.dts`

The escape hatch for a board revision the base device tree doesn't
describe at all — not a fragment, a **full replacement** of the board's
`.dts`. At most one file is meaningful; if both `common/` and a profile
provide one, the profile's wins outright (this tier doesn't accumulate
the way `kernel.config`/`patches`/overlays do). The file is copied into
the kernel tree next to the stock DTS (same vendor subdirectory as
`KERNEL_DT_FILE`) under its own name, and a build entry for it is added
to that directory's `Makefile` automatically — reusing whatever
`dtb-$(CONFIG_...) +=` guard an existing board in the same family already
builds under, so it doesn't need updating by hand as kernel versions
move. `boot.cmd`'s `@DTB_FILE@` and the final image both switch to the
override's filename automatically; nothing else needs to know about it.

For most boards you don't need this — a device tree *overlay* (below)
covers adding/changing a few nodes without replacing the whole file.

## Device tree overlays: `overlays/*.dts`

Overlay-syntax (`/plugin/;`) fragments, compiled to `.dtbo` and applied
by U-Boot to the FDT before the kernel boots (§6) — the right tool for
things that need to be in place before the relevant subsystem finishes
probing (a display module's boot log, enabling USB-on-GPIO). Unlike
`boot.cmd`/`dts`, these **accumulate**: `common/overlays/*.dts` and
`profiles/<name>/overlays/*.dts` both apply if both are present.
Overlay *selection* is decided at build time (baked into `boot.scr`);
toggling one means a rebuild, not a runtime edit — see §6 in the design
notes for why that trade was made deliberately.

```
make overlays TARGET=<name> CUSTOM_PROFILE=<profile-name>   # compile only
make overlay-check TARGET=<name> CUSTOM_PROFILE=<profile-name>   # compile + preview the merged DT
```

`overlay-check` needs `fdtoverlay` (not part of `make check-tools`'s
required list — it's only needed for this optional review step).

## `boot.cmd`

A full replacement of `boot.cmd.template` for changing actual boot
*logic*, not just parameters — most customization needs don't need this;
`overlays/` covers device tree changes, and `@DTB_FILE@`/the overlay list
are substituted into whichever `boot.cmd` is active regardless of source.
Same override precedence as `dts/*.dts`: profile's wins over common's
wins over the shipped default.

## `packages.txt`

Extra `apk` packages installed into the rootfs, one per line (`#` starts
a comment). `common/` and the profile's are concatenated, not merged by
name — duplicate or conflicting entries are `apk`'s problem to resolve,
not this tooling's.

## `setup.sh`: one-time post-expansion hook

A script baked into the image and run **exactly once**, after first-boot
rootfs expansion has fully completed — not on every boot, not
mid-expansion (expansion spans multiple reboots, so this waits on
`expand-rootfs.sh`'s own completion marker rather than guessing from boot
count). If both `common/setup.sh` and the profile's exist, both run,
common's first, as two separate steps of the same hook. A script that
exits non-zero leaves the hook installed to retry next boot rather than
silently dropping the rest of your setup.
