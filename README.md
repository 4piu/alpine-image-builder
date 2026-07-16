# alpine-image-builder

A build toolkit for running Alpine Linux on EOL/community-supported SBCs —
cross-compiles U-Boot + Linux, bootstraps an Alpine root filesystem via
`apk`, and assembles a bootable `.img`. Successor to the (soon to be
retired) `nanopi-alpine` and `zeropi-alpine` repos, generalized to support
more boards without forking.

**This is a toolkit you run yourself, not a source of prebuilt images.**
Clone it, point it at a board, build. GitHub Actions is a convenience
wrapper around the same `make` targets you'd run locally — not a separate
product, and not a place to download images from.

Status: early — under active restructuring, not yet fully working. See
`notes/build-pipeline-brainstorm.md` for the design rationale and
`notes/implementation-progress.md` for what's actually done so far.

## Layout

- `target/<name>/` — a build target: `board.env` (which U-Boot/kernel
  defconfig, which device tree — either set directly, or referenced from
  another target via `BOARD=`) plus your customization —
  `common/` (applied to every build of that target) and
  `profiles/<name>/` (named, opt-in customization sets: kernel config
  fragments, `boot.cmd` overrides, device tree overlays, extra packages,
  a one-time setup script). Nothing beyond `board.env` is required — an
  unmodified target builds a stock, vanilla image. Adding a new board is
  a PR adding a `target/<new-board-id>/board.env`, not a fork.
- `tools/recipes/` — ready-to-use customization fragments for common
  cases (e.g. enabling a specific USB wifi chipset), documented on the
  wiki, meant to be copied into your own `target/<name>/profiles/`.
- `docs/` — reference docs for customizing the build (currently: kernel
  config tribal knowledge — module compression, symbols that must stay
  builtin, the on-device incremental-build escape hatch).

## Requirements

- `gcc-arm-linux-gnueabihf` (or another `arm-*-gcc`) to cross-compile
  U-Boot and the kernel
- `dtc`, `u-boot-tools` (`mkimage`), `zstd`
- `sfdisk`/`fdisk`, `losetup`, `mkfs.ext4`, `kpartx`/`partx`
- `git`, `wget`, `tar`, `sed`, `grep`, `xargs`, `du`, `comm`, `coreutils`
  (`sha256sum`, `realpath`)
- `swig`, `python3`, `python3-setuptools`, `python3-pyelftools`
- `sudo` rights (mounting filesystems, installing kernel modules during
  the build)
- `fdtoverlay` — only if you use `make overlay-check` to preview a
  device tree overlay merge; not required for a normal build

Run `make check-tools` to verify before building.

## Building

```
make build TARGET=<name> CUSTOM_PROFILE=<name>   # CUSTOM_PROFILE optional
```

Starting targets: `nanopi-neo`, `zeropi` — both vanilla by default, both
also carry a real `profiles/wifi` (`CUSTOM_PROFILE=wifi`) for an
RTL8821CU USB dongle, worth a look as a working example.

## CI (on your own fork)

- **Build** (`.github/workflows/build.yml`) — `workflow_dispatch` with
  the same inputs as `make build`; leave `target` blank to build every
  target in the repo, or name one. Uploads `alpine.img` as a workflow
  artifact.
- **Smoke test** (`.github/workflows/smoke-test.yml`) — runs on PRs that
  touch a `board.env`, stock config only, to catch a board going
  uncompilable as upstream defconfigs move. Not a substitute for testing
  on real hardware, which stays manual.
- **Scheduled rebuild** (`.github/workflows/scheduled-rebuild.yml`) —
  off by default; set the repo variable `SCHEDULED_REBUILD_ENABLED=true`
  to opt in.

## License

MIT — see `LICENSE`.
