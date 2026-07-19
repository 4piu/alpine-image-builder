# alpine-image-builder

A build toolkit for running Alpine Linux on EOL/community-supported SBCs —
cross-compiles U-Boot + Linux, bootstraps an Alpine root filesystem via
`apk`, and assembles a bootable `.img`.

**This is a toolkit you run yourself, not a source of prebuilt images.**
Clone it, point it at a board, build. GitHub Actions is a convenience
wrapper around the same `make` targets you'd run locally.

## Layout

- `target/<name>/` — a build target: `board.env` (which U-Boot/kernel
  defconfig, which device tree — either set directly, or referenced from
  another target via `BOARD=`) plus your customization —
  `common/` (applied to every build of that target) and
  `profiles/<name>/` (named, opt-in customization sets: kernel config
  fragments, `boot.cmd` overrides, device tree overlays, extra packages,
  a one-time setup script). Nothing beyond `board.env` is required — an
  unmodified target builds a stock image. Adding a new board is a PR
  adding a `target/<new-board-id>/board.env`, not a fork.
- `tools/recipes/` — ready-to-use customization fragments for common
  cases (e.g. enabling a specific USB wifi chipset), meant to be copied
  into (or automatically pulled into) your own `target/<name>/profiles/`.
- `docs/` — reference docs for customizing the build.

## Requirements

- A cross-compiler matching your target's `ARCH` — `gcc-arm-linux-gnueabihf`
  (or another `arm-*-gcc`) for armv7 boards, `gcc-aarch64-linux-gnu` (or
  another `aarch64-*-gcc`) for arm64 boards. Which one you need depends
  on the target you're building, not something to install both of
  up front.
- `dtc`, `u-boot-tools` (`mkimage`), `zstd`
- `sfdisk`/`fdisk`, `losetup`, `mkfs.ext4`, `kpartx`/`partx`
- `git`, `wget`, `tar`, `sed`, `grep`, `xargs`, `du`, `comm`, `coreutils`
  (`sha256sum`, `realpath`)
- `swig`, `python3`, `python3-setuptools`, `python3-pyelftools`
- `sudo` rights (mounting filesystems, installing kernel modules during
  the build)
- `fdtoverlay` — only if you use `make overlay-check` to preview a
  device tree overlay merge; not required for a normal build

`make build`/`make install` run this check themselves as their first
step and fail fast with exactly what's missing — `make check-tools` on
its own is there if you want to check before committing to a build.

## Building

```
make build TARGET=<name> PROFILE=<name>   # PROFILE optional
```

Starting targets: `nanopi-neo`, `zeropi` (both armv7/Allwinner H3), and
`orangepi-zero3` (arm64/Allwinner H618 — needs an `aarch64-*-gcc` and
pulls in ARM Trusted Firmware automatically, see `target/README.md`).
`nanopi-neo`/`zeropi` both carry a real `profiles/wifi` (`PROFILE=wifi`)
for an RTL8821CU USB dongle, worth a look as a working example.
`nanopi-neo` also enables its second USB host controller by default.

## Make commands

Every command below takes `TARGET=<name>` (required) and, where it
makes sense, `PROFILE=<name>` (optional — omit for the stock/base
build). See `target/README.md` for what a target/profile actually is.

- **`make build`** (the default if you just run `make`) — builds the
  full image: kernel, U-Boot (+ ARM Trusted Firmware if the board needs
  it), rootfs, `alpine.img`. Safe to re-run — only rebuilds what
  actually changed.
- **`make install`** — builds (same as `make build`), then interactively
  prompts for a block device and `dd`s the image to it. Asks for
  confirmation before writing; refuses a mounted device.
- **`make check-tools`** — checks your host has everything the build
  needs (see Requirements above) and reports exactly what's missing.
  Runs automatically as the first step of `build`/`install` too.
- **`make kernel-menuconfig`** / **`make uboot-menuconfig`** — open an
  interactive `menuconfig` against the target's currently-resolved
  kernel/U-Boot config and capture just the delta into
  `common/kernel.config`/`uboot.config` (or the named profile's, with
  `PROFILE=`). See `target/README.md` for the full mechanics.
- **`make overlays`** — compiles this target/profile's device tree
  overlays (`.dts` → `.dtbo`) without doing a full build.
- **`make overlay-check`** — compiles overlays and previews the merged
  device tree against the target's built DTB, so you can sanity-check
  before flashing. Needs `fdtoverlay`.
- **`make clean`** — removes this target/profile's `output/` (built
  image, rootfs, etc.). Leaves the shared `sources/` checkouts alone.
- **`make distclean`** — `clean`, plus wipes the shared `sources/`
  (kernel, U-Boot, ATF checkouts and all cached config/fingerprint
  state). Next build starts from a fresh clone of everything.

## CI (on your own fork)

- **Build** (`.github/workflows/build.yml`) — `workflow_dispatch` with
  the same inputs as `make build`; leave `target` blank to build every
  target in the repo, or name one. Uploads `alpine.img` as a workflow
  artifact. **Currently only installs the armv7 cross-compiler** — an
  arm64 target (`orangepi-zero3`) will fail here until the toolchain
  install step is extended; local builds aren't affected.
- **Smoke test** (`.github/workflows/smoke-test.yml`) — runs on PRs that
  touch a `board.env`, stock config only, to catch a board going
  uncompilable as upstream defconfigs move. Not a substitute for testing
  on real hardware, which stays manual.
- **Scheduled rebuild** (`.github/workflows/scheduled-rebuild.yml`) —
  off by default; set the repo variable `SCHEDULED_REBUILD_ENABLED=true`
  to opt in.

## License

MIT — see `LICENSE`.
