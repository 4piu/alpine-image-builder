# Importing board-bringup content from Armbian

`tools/armbian-import.sh` pulls patches, DT files, and firmware from
`armbian/build` and `armbian/firmware` into a target's `common/` or
`profiles/<name>/`, as ordinary committed content — never a live
dependency at build time. See `notes/armbian-kernel-patches-brainstorm.md`
for the reasoning; this doc is the how-to, plus the case study's own
hard-earned lesson about not stopping at the first tree you check.

## Finding your board's `KERNELPATCHDIR`

Armbian resolves a board to a kernel patch directory through a few
layers — there's no shortcut, you have to walk it once per board. Worked
example, traced end-to-end for `orangepi-zero3`:

1. `config/boards/<board>.csc` (or `.conf`) in `armbian/build` —
   `orangepizero3.csc` sets `BOARDFAMILY="sun50iw9"` and
   `KERNEL_TARGET="current,edge"`.
2. `config/sources/families/<family>.conf` — `sun50iw9.conf` sources
   `include/sunxi64_common.inc`.
3. That include file sets `KERNEL_MAJOR_MINOR` per `$BRANCH`
   (`current` → `6.18`, `edge` → `7.0` at the time this was written —
   check the file directly, these move) and then:
   `KERNELPATCHDIR="archive/sunxi-${KERNEL_MAJOR_MINOR}"`.

So for `orangepi-zero3` on the `current` branch, `KERNELPATCHDIR` is
`archive/sunxi-6.18` — that's the `<patch-dir>` argument `list kernel`/
`import kernel` expect. A different board means redoing this walk from
its own `.csc`/`.conf` — the mapping is Armbian's own board→family→branch
logic, and `armbian-import.sh` deliberately doesn't try to reproduce it
(see the brainstorm doc for why: it's coupling to something this project
doesn't control, for a lookup a human can do once per board).

## Three source trees, checked in order

**Check all three before concluding a gap isn't covered upstream.**
The single biggest mistake made while building this tool was stopping
after the first tree came up empty — see the brainstorm doc's own
corrections for two real instances of this.

- **`kernel <patch-dir>`** — `patch/kernel/<patch-dir>/` in
  `armbian/build`. General per-family/per-kernel-version board bringup:
  DT wiring for hardware mainline already drives, small compat fixes.
  Selected via that directory's own `series.conf` (`-`-prefixed lines
  disabled), plus `dt_*`/`overlay_*` subdirectories (full-file DTS /
  DT-overlay sources, not `series.conf`-gated at all).
- **`misc <driver-name>`** — `patch/misc/<driver-name>/` in
  `armbian/build`. Flat patch directories for a whole out-of-tree driver,
  opted into by a board's `extensions/<name>.sh`. This is where a
  wholesale missing driver (the `orangepi-zero3` wifi/BT case) actually
  lives — checking only `patch/kernel/` will not find it.
- **`firmware`** — `armbian/firmware`, a **separate repo**, not a
  directory inside `armbian/build`. Flat binary/text firmware and
  calibration files. Byte-identical, in the one case checked against a
  physically-owned board's known-working firmware.

```
tools/armbian-import.sh list kernel   archive/sunxi-6.18 wifi
tools/armbian-import.sh list misc     wireless-uwe5622
tools/armbian-import.sh list firmware uwe5622
```

Each result's first column tags what it is (`[patch]`, `[dts]`,
`[overlay]`, `[file]`) and where it'll land.

## Importing

```
tools/armbian-import.sh import target/<name>/common kernel   archive/sunxi-6.18 patches.armbian/some-patch.patch
tools/armbian-import.sh import target/<name>/common misc     wireless-uwe5622   some-driver-patch.patch
tools/armbian-import.sh import target/<name>/common firmware                    uwe5622/wcnmodem.bin
```

Routing is mechanical, driven by the source path's shape:

| Source | Lands in | Note |
| --- | --- | --- |
| `patches.*/foo.patch` (kernel or misc) | `patches/armbian-NNNN-foo.patch` | `NNNN` = next number in this target's existing `armbian-*` sequence |
| `dt_*/foo.dts` | `dts/foo.dts` | full-replacement escape hatch — only one is ever used; `import` warns if a different one is already there |
| `overlay_*/foo.dtso` | `overlays/foo.dts` | renamed `.dtso`→`.dts` to match this project's own overlay glob; already-verified real overlay-syntax (`/plugin/;`) source |
| an `armbian/firmware` path | `firmware/<basename>` | basename only — Armbian's own subdirectory layout in *their* repo isn't a runtime requirement; check what the driver's own `request_firmware()` call actually expects before assuming a subdirectory needs preserving |

Every import is recorded in `<target-dir>/ARMBIAN-IMPORTS.md` (source
path, resolved commit, import date) and is idempotent — re-running the
same import skips what's already there.

## What this tool doesn't do, on purpose

- **Doesn't select or merge Armbian's `config/kernel/<family>-<branch>.config`.**
  That file is a large, un-scoped defconfig-style fragment, not a small
  delta — pulling it in wholesale repeats the mistake this project's own
  base-defconfig design already rules out. Add the specific `CONFIG_*`
  symbols a patch actually needs to your own `kernel.config` by hand;
  `verify-config.sh` catches anything that doesn't stick.
- **Doesn't apply anything, ever.** Every import lands as a plain file
  you review (`git diff`) before it's ever touched by a build. A patch
  that doesn't apply cleanly is caught the same way a hand-written one
  would be — `prepare-linux-tree.sh`'s existing hard-fail gate, not
  anything this tool adds.
- **Doesn't guarantee an imported patch still applies as-is forever.**
  Upstream drift happens — `orangepi-zero3`'s own imported DT patch
  needed a `patch --fuzz=3` rebase within about two years of its original
  authorship. Re-check on your next `KERNEL_VERSION` bump; that's what
  `ARMBIAN-IMPORTS.md`'s note is there to remind you to do.
- **Doesn't mean "compiles clean" or "works on real hardware."**
  Importing a chain of version-targeted compat patches doesn't guarantee
  they cover every API surface your exact kernel version actually has —
  `orangepi-zero3`'s own rebuild hit three genuine compile failures
  (a removed `from_timer()` API, a cfg80211 `add_key`/`roam_info` MLO
  signature change with no matching Armbian patch at exactly the right
  version, a VFS `dir_context.actor` return-type change) that only
  showed up by actually compiling against the real cross-toolchain, not
  by patches merely applying. Treat "the patches apply" as a necessary
  first checkpoint, not the finish line — a real build (and, beyond what
  this environment can do, a real boot) is still the actual test.
