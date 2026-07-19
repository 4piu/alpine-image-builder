################################################################################
# Alpine SBC image builder
#
# Usage:
#   make build TARGET=<name> [PROFILE=<name>]
#
# See target/README.md for what TARGET/PROFILE mean and how a
# target's board.env resolves; notes/build-pipeline-brainstorm.md §2/§3
# for the reasoning behind the shape of this file.
################################################################################

TARGET ?=
PROFILE ?=
BOARD ?=

# Raw ANSI codes so $(error ...)/$(warning ...) -- which Make just prints
# verbatim, no coloring of its own -- stand out from the rest of the
# build's (mostly uncolored) output instead of blending in as just
# another line.
MK_RED := $(shell printf '\033[0;31m')
MK_YELLOW := $(shell printf '\033[0;33m')
MK_NC := $(shell printf '\033[0m')

ifeq ($(TARGET),)
$(error $(MK_RED)TARGET is required, e.g. make build TARGET=nanopi-neo — see target/README.md$(MK_NC))
endif

ifeq ($(wildcard target/$(TARGET)/board.env),)
$(error $(MK_RED)No target/$(TARGET)/board.env -- is TARGET=$(TARGET) spelled correctly? see target/ for available targets$(MK_NC))
endif

# This target's own board.env: plain assignments, so anything it sets here
# always wins over a referenced board's value below, no matter which is
# read first.
-include target/$(TARGET)/board.env

# BOARD=<other-target-name>, if this target's own board.env sets it, borrows
# that target's fields as fallbacks for whatever's still unset here -- never
# as overrides. Rewriting the referenced file's assignments from `=` to `?=`
# before evaluating them is what makes that a fallback instead of a clobber:
# GNU Make's plain `=` always wins the *last* assignment processed, so a raw
# second -include of another plain-assignment file would let the reference
# overwrite this target's own values; `?=` only fills in what's still
# undefined, regardless of where the existing value came from (§2, "Before
# starting" #4).
ifneq ($(BOARD),)
ifeq ($(wildcard target/$(BOARD)/board.env),)
$(error $(MK_RED)target/$(TARGET)/board.env references BOARD=$(BOARD), but target/$(BOARD)/board.env doesn't exist$(MK_NC))
endif
# $(shell) collapses the file's newlines into spaces before $(eval) ever
# sees it, which would flatten the whole rewritten file into a single line
# -- and since board.env conventionally starts with a comment, $(eval)
# would then treat the *entire* fallback as one Make comment. Route the
# rewrite through a real file instead, so -include reads it with its
# newlines intact.
$(shell mkdir -p sources && sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$$/\1?=\2/' target/$(BOARD)/board.env > sources/.board-fallback.mk)
-include sources/.board-fallback.mk
endif

REQUIRED_BOARD_FIELDS := UBOOT_BOARD_DEFCONFIG KERNEL_DT_FILE ARCH CROSS_COMPILE \
                          ALPINE_ARCH KERNEL_DEFCONFIG UBOOT_WRITE_OFFSET \
                          KERNEL_VERSION UBOOT_VERSION ALPINE_VERSION
$(foreach f,$(REQUIRED_BOARD_FIELDS),$(if $($(f)),,$(error $(MK_RED)target/$(TARGET)/board.env (via BOARD=$(BOARD) if set) leaves $(f) unresolved -- see target/README.md$(MK_NC))))

# Both the kernel and U-Boot build systems read these from the environment.
export ARCH
export CROSS_COMPILE

################################################################################
## Config
################################################################################

UBOOT_FORMAT_CUSTOM_NAME ?= u-boot-sunxi-with-spl.bin
ROOTFS_URL = https://dl-cdn.alpinelinux.org/alpine/$(ALPINE_VERSION)

# Per-ARCH kernel image/boot mechanics -- arm's zImage+bootz and arm64's
# Image+booti aren't interchangeable, and arm64 doesn't build to
# arch/arm/... the way arm does. Everything board.env itself provides is
# arch-independent (defconfig names, DT paths); this is the one place
# that has to branch on ARCH instead.
ifeq ($(ARCH),arm)
KERNEL_IMAGE_FILE := zImage
BOOT_CMD_NAME := bootz
MKIMAGE_ARCH := arm
else ifeq ($(ARCH),arm64)
KERNEL_IMAGE_FILE := Image
BOOT_CMD_NAME := booti
MKIMAGE_ARCH := arm64
else
$(error $(MK_RED)ARCH=$(ARCH) has no KERNEL_IMAGE_FILE/BOOT_CMD_NAME/MKIMAGE_ARCH mapping -- add one above$(MK_NC))
endif

TARGET_DIR := target/$(TARGET)
PROFILE_NAME := $(if $(PROFILE),$(PROFILE),base)
PROFILE_DIR := $(TARGET_DIR)/profiles/$(PROFILE)
COMMON_DIR := $(TARGET_DIR)/common
OUTPUT_DIR := output/$(TARGET)/$(PROFILE_NAME)

################################################################################
## Customization merge chain: board manifest -> common/ -> profiles/$(PROFILE)/
## (§3/§4). Every artifact below resolves the same way: whichever pieces
## are present at each stage apply; an unmodified target (nothing under
## common/ or profiles/) builds a stock, vanilla image.
################################################################################

# DTS full replacement -- the escape hatch for a board revision the base
# doesn't describe at all (§6). Full override, not a merge: the profile's
# file wins outright over common's if both happen to provide one, rather
# than both applying. At most one file is meaningful here; if a directory
# somehow has more than one, the alphabetically-first is used.
DTS_OVERRIDE_PROFILE := $(word 1,$(sort $(wildcard $(PROFILE_DIR)/dts/*.dts)))
DTS_OVERRIDE_COMMON := $(word 1,$(sort $(wildcard $(COMMON_DIR)/dts/*.dts)))
DTS_OVERRIDE := $(if $(DTS_OVERRIDE_PROFILE),$(DTS_OVERRIDE_PROFILE),$(DTS_OVERRIDE_COMMON))

# The DTB this build actually produces/boots -- KERNEL_DT_FILE's board.env
# value, unless DTS_OVERRIDE replaces it (same vendor subdirectory, the
# override file's own basename).
EFFECTIVE_DTB_FILE := $(if $(DTS_OVERRIDE),$(dir $(KERNEL_DT_FILE))$(basename $(notdir $(DTS_OVERRIDE))).dtb,$(KERNEL_DT_FILE))

KERNEL_PRODUCTS := $(addprefix sources/linux/,arch/$(ARCH)/boot/$(KERNEL_IMAGE_FILE) arch/$(ARCH)/boot/dts/$(EFFECTIVE_DTB_FILE))
KERNEL_PRODUCTS_OUTPUT := $(addprefix $(OUTPUT_DIR)/,$(notdir $(KERNEL_PRODUCTS)))
ROOTFS_DIR := $(OUTPUT_DIR)/rootfs
ROOTFS_TARBALL := $(OUTPUT_DIR)/rootfs.tar.gz
IMAGE := $(OUTPUT_DIR)/alpine.img

# recipes.txt -- one tools/recipes/<name> per line (# comments, blank
# lines ignored, same convention as packages.txt), resolved to that
# recipe's fragment file and merged in alongside this tier's own
# kernel.config. Applied automatically, but only ever from a file the
# user committed themselves -- same trust boundary the rest of this repo
# already applies to workflow_dispatch inputs and everything else in
# common/profiles/: content lives in a reviewable, version-controlled
# file, nothing hidden mutates the build.
COMMON_RECIPE_NAMES := $(if $(wildcard $(COMMON_DIR)/recipes.txt),$(shell grep -vE '^\s*#' $(COMMON_DIR)/recipes.txt | xargs))
PROFILE_RECIPE_NAMES := $(if $(wildcard $(PROFILE_DIR)/recipes.txt),$(shell grep -vE '^\s*#' $(PROFILE_DIR)/recipes.txt | xargs))
COMMON_RECIPE_FRAGMENTS := $(foreach r,$(COMMON_RECIPE_NAMES),tools/recipes/$(r).config)
PROFILE_RECIPE_FRAGMENTS := $(foreach r,$(PROFILE_RECIPE_NAMES),tools/recipes/$(r).config)

# Fail immediately (parse time, before any build work starts) if
# recipes.txt names something that doesn't exist under tools/recipes/,
# rather than letting merge_config.sh silently skip a fragment file it
# can't find.
$(foreach f,$(COMMON_RECIPE_FRAGMENTS) $(PROFILE_RECIPE_FRAGMENTS),$(if $(wildcard $(f)),,$(error $(MK_RED)$(f) not found -- listed in a recipes.txt but no such recipe exists under tools/recipes/. Available: $(patsubst tools/recipes/%.config,%,$(wildcard tools/recipes/*.config))$(MK_NC))))

# Kernel config: fragments merged onto the stock base defconfig via
# merge_config.sh, common/ first (kernel.config then its recipes.txt) so
# profiles/$(PROFILE)/ (kernel.config then its recipes.txt) can
# override it, never a full-file replacement (§4).
# $(strip ...) matters here, not just tidiness: if all the wildcards are
# empty, the bare concatenation is a run of literal spaces (the spaces
# between the individual calls in this line), which is non-empty as far
# as $(if ...)/shell `[ -n ]` are concerned -- silently treating "no
# fragments" as "one fragment." Same reasoning applies to every
# similarly-built list below.
KERNEL_CONFIG_FRAGMENTS := $(strip $(wildcard $(COMMON_DIR)/kernel.config) $(COMMON_RECIPE_FRAGMENTS) $(wildcard $(PROFILE_DIR)/kernel.config) $(PROFILE_RECIPE_FRAGMENTS))

# U-Boot config: same fragment-merge idea as the kernel, minus the
# recipes.txt tier -- tools/recipes/ is Linux driver Kconfig, not
# U-Boot, so there's nothing to resolve here beyond the two plain files.
UBOOT_CONFIG_FRAGMENTS := $(strip $(wildcard $(COMMON_DIR)/uboot.config) $(wildcard $(PROFILE_DIR)/uboot.config))

# Kernel source patches -- applied in the same common-then-profile order,
# must apply cleanly or the build hard-fails ("Before starting", open
# questions). Unlike kernel.config fragments, these mutate the shared
# sources/linux tree directly, so switching TARGET/PROFILE has to
# reset and reapply, not accumulate -- see prepare-linux-tree.sh.
PATCH_FILES := $(strip $(sort $(wildcard $(COMMON_DIR)/patches/*.patch)) $(sort $(wildcard $(PROFILE_DIR)/patches/*.patch)))

# DT overlays -- accumulate (common's and the profile's both apply),
# unlike boot.cmd/dts which are full overrides. Two static pattern rules
# below, one per source directory, since each output basename needs to
# know which directory its .dts actually came from.
OVERLAY_SOURCES_COMMON := $(wildcard $(COMMON_DIR)/overlays/*.dts)
OVERLAY_SOURCES_PROFILE := $(wildcard $(PROFILE_DIR)/overlays/*.dts)
OVERLAY_TARGETS_COMMON := $(patsubst $(COMMON_DIR)/overlays/%.dts,$(OUTPUT_DIR)/overlay/%.dtbo,$(OVERLAY_SOURCES_COMMON))
OVERLAY_TARGETS_PROFILE := $(patsubst $(PROFILE_DIR)/overlays/%.dts,$(OUTPUT_DIR)/overlay/%.dtbo,$(OVERLAY_SOURCES_PROFILE))
OVERLAY_TARGETS := $(strip $(OVERLAY_TARGETS_COMMON) $(OVERLAY_TARGETS_PROFILE))

# boot.cmd -- full override, same precedence as the DTS override above:
# profile's wins over common's wins over the shipped default template.
BOOT_CMD_SOURCE := $(firstword $(wildcard $(PROFILE_DIR)/boot.cmd) $(wildcard $(COMMON_DIR)/boot.cmd) boot.cmd.template)

# Extra apk packages -- concatenated (not a Kconfig-style merge, just
# more package names), written out to a real file since build-chroot.sh
# takes one PACKAGES_FILE path.
PACKAGES_SOURCES := $(strip $(wildcard $(COMMON_DIR)/packages.txt) $(wildcard $(PROFILE_DIR)/packages.txt))
PACKAGES_FILE := $(if $(PACKAGES_SOURCES),$(OUTPUT_DIR)/packages.merged.txt,)

# One-time setup.sh hook (§10a) -- common's runs first, then the
# profile's, as two separate steps of the same hook (see setup-hook.sh),
# not concatenated text.
SETUP_SCRIPTS := $(strip $(wildcard $(COMMON_DIR)/setup.sh) $(wildcard $(PROFILE_DIR)/setup.sh))

# sources/ is shared across whichever target/profile you build next, not
# isolated per target (§"Before starting" #3 -- only one board is ever
# actively built at a time, so that isolation would solve a concurrency
# problem that doesn't exist). What's real: a stale checkout for the wrong
# KERNEL_VERSION/UBOOT_VERSION would otherwise silently ship the wrong
# kernel/U-Boot. Block on that instead of warning.
ifneq ($(wildcard sources/linux.ready),)
LINUX_READY_VERSION := $(shell cat sources/linux.ready)
ifneq ($(LINUX_READY_VERSION),$(KERNEL_VERSION))
$(error $(MK_RED)sources/linux was checked out for kernel $(LINUX_READY_VERSION), but TARGET=$(TARGET) wants $(KERNEL_VERSION) -- run 'make distclean' (or remove sources/linux and sources/linux.ready) and rebuild$(MK_NC))
endif
endif
ifneq ($(wildcard sources/u-boot.ready),)
UBOOT_READY_VERSION := $(shell cat sources/u-boot.ready)
ifneq ($(UBOOT_READY_VERSION),$(UBOOT_VERSION))
$(error $(MK_RED)sources/u-boot was checked out for U-Boot $(UBOOT_READY_VERSION), but TARGET=$(TARGET) wants $(UBOOT_VERSION) -- run 'make distclean' (or remove sources/u-boot and sources/u-boot.ready) and rebuild$(MK_NC))
endif
endif

# Same "block instead of silently drifting" principle as the version
# checks above, but for patches/DTS-override: these mutate sources/linux
# directly rather than swapping out a whole file, so a plain mtime-based
# Make prerequisite can't detect "the SET of applicable patches changed
# since the last build" (switching TARGET/PROFILE can shrink the
# set, which a file that's merely *newer* can't express). Run the check
# immediately, at parse time, same as the version checks -- and if the
# tree actually needed resetting, drop the stale .config so Make's normal
# dependency resolution regenerates it instead of silently reusing a
# config that was merged against the previous patch set.
ifneq ($(wildcard sources/linux/.git),)
PREPARE_LINUX_TREE_RESULT := $(shell ./prepare-linux-tree.sh sources/linux sources/.tree-prepared $(KERNEL_DT_FILE) "$(DTS_OVERRIDE)" $(PATCH_FILES))
ifneq ($(.SHELLSTATUS),0)
$(error $(MK_RED)Preparing sources/linux for TARGET=$(TARGET) PROFILE=$(PROFILE) failed -- see output above$(MK_NC))
endif
ifeq ($(PREPARE_LINUX_TREE_RESULT),CHANGED)
$(shell rm -f sources/linux/.config)
endif
endif

# Kernel config fragments don't mutate sources/linux (unlike patches) --
# they only ever get merged into .config -- but the same "switching
# TARGET/PROFILE can change the fragment SET, not just edit a fragment
# already in it" problem applies: a plain mtime-based prerequisite can't
# tell "this build wants a different (possibly smaller) fragment set
# than whatever's currently merged into .config" from "nothing changed."
# Same fingerprint-and-force-delete fix as the patches case above. A
# missing marker (no build has ever recorded one, or an older tree from
# before this check existed) counts as "unknown," not "unchanged" -- it
# can never match a real fingerprint, including "none," so it always
# forces one rebuild to establish a known-good baseline rather than
# trusting a .config nothing here can vouch for.
KERNEL_CONFIG_FINGERPRINT := $(if $(KERNEL_CONFIG_FRAGMENTS),$(shell cat $(KERNEL_CONFIG_FRAGMENTS) | sha256sum | cut -d' ' -f1),none)
RECORDED_KERNEL_CONFIG_FINGERPRINT := $(if $(wildcard sources/.kernel-config-fingerprint),$(shell cat sources/.kernel-config-fingerprint),unknown)
ifneq ($(RECORDED_KERNEL_CONFIG_FINGERPRINT),$(KERNEL_CONFIG_FINGERPRINT))
$(shell rm -f sources/linux/.config)
endif

# Same fingerprint-and-force-delete fix, same reasoning, for U-Boot's
# config fragments.
UBOOT_CONFIG_FINGERPRINT := $(if $(UBOOT_CONFIG_FRAGMENTS),$(shell cat $(UBOOT_CONFIG_FRAGMENTS) | sha256sum | cut -d' ' -f1),none)
RECORDED_UBOOT_CONFIG_FINGERPRINT := $(if $(wildcard sources/.uboot-config-fingerprint),$(shell cat sources/.uboot-config-fingerprint),unknown)
ifneq ($(RECORDED_UBOOT_CONFIG_FINGERPRINT),$(UBOOT_CONFIG_FINGERPRINT))
$(shell rm -f sources/u-boot/.config)
endif

################################################################################

# Delete a target's output if its recipe fails partway through, so a failed
# build doesn't leave a stale/partial file that a later `make` treats as done.
.DELETE_ON_ERROR:

.DEFAULT_GOAL := build

# Order-only prerequisite: creates $(OUTPUT_DIR) without forcing a rebuild
# of everything inside it whenever the directory's mtime changes.
$(OUTPUT_DIR)/:
	mkdir -p $@

# Prime the sudo credential, then refresh it in the background for as long
# as this `make` invocation is alive, so a long kernel/u-boot build doesn't
# let the ticket expire and leave modules_install/make-image.sh hanging on
# a password prompt nobody is there to answer. $$PPID here is make's own
# PID (make forks this recipe's shell directly), so the loop self-terminates
# when make exits, whether it succeeds, fails, or gets interrupted.
#
# This has to be the first two lines of build's *own* recipe, not a
# separate prerequisite target -- under `-j`, prerequisites run in
# whatever order Make schedules them, so a `sudo-keepalive` prerequisite
# can start concurrently with the kernel/u-boot compile jobs and its
# password prompt gets buried in their output (build looks hung; it's
# actually just waiting on stdin). Recipe lines within one target always
# run in order regardless of `-j`, so priming here first and only then
# recursing into the real (parallelizable) build guarantees the prompt is
# the only thing on screen when it appears. `$(MAKE)` here shares this
# invocation's jobserver automatically, so `-j` still applies to it.
.PHONY: build
build:
	@sudo -v
	@( makepid=$$PPID; while true; do sleep 60; kill -0 $$makepid 2>/dev/null || exit; sudo -n -v; done 2>/dev/null & )
	$(MAKE) $(MAKEFLAGS) $(IMAGE) $(ROOTFS_TARBALL)

# DT Overlays -- two static pattern rules, one per source directory (see
# OVERLAY_TARGETS_COMMON/PROFILE above for why one rule can't cover both).
$(OVERLAY_TARGETS_COMMON): $(OUTPUT_DIR)/overlay/%.dtbo: $(COMMON_DIR)/overlays/%.dts | $(OUTPUT_DIR)/
	@mkdir -p $(OUTPUT_DIR)/overlay
	dtc -@ -I dts -O dtb -o $@ $<

$(OVERLAY_TARGETS_PROFILE): $(OUTPUT_DIR)/overlay/%.dtbo: $(PROFILE_DIR)/overlays/%.dts | $(OUTPUT_DIR)/
	@mkdir -p $(OUTPUT_DIR)/overlay
	dtc -@ -I dts -O dtb -o $@ $<

.PHONY: overlays
overlays: $(OVERLAY_TARGETS)

.PHONY: overlay-check
overlay-check: $(word 2,$(KERNEL_PRODUCTS_OUTPUT)) $(OVERLAY_TARGETS)
	@if [ -z "$(OVERLAY_TARGETS)" ]; then \
		echo "No overlays for TARGET=$(TARGET) PROFILE=$(PROFILE) -- nothing to check."; \
		exit 0; \
	fi
	fdtoverlay -i $(word 2,$(KERNEL_PRODUCTS_OUTPUT)) -o $(OUTPUT_DIR)/overlay-check.dtb $(OVERLAY_TARGETS)
	dtc -I dtb -O dts $(OUTPUT_DIR)/overlay-check.dtb

# U-Boot
$(OUTPUT_DIR)/boot.scr: $(BOOT_CMD_SOURCE) $(OVERLAY_TARGETS) | $(OUTPUT_DIR)/
	@overlay_list=$$(for f in $(OVERLAY_TARGETS); do basename $$f; done | tr '\n' ' '); \
	sed -e "s/setenv overlay_files \"[^\"]*\"/setenv overlay_files \"$$overlay_list\"/" \
	    -e "s|@DTB_FILE@|$(notdir $(EFFECTIVE_DTB_FILE))|" \
	    -e "s|@KERNEL_FILE@|$(KERNEL_IMAGE_FILE)|" \
	    -e "s|@BOOT_CMD@|$(BOOT_CMD_NAME)|" \
	    $(BOOT_CMD_SOURCE) > $(OUTPUT_DIR)/boot.cmd.tmp
	mkimage -C none -A $(MKIMAGE_ARCH) -T script -d $(OUTPUT_DIR)/boot.cmd.tmp '$@'
	@rm -f $(OUTPUT_DIR)/boot.cmd.tmp

sources/u-boot.ready:
	git clone --depth 1 --branch $(UBOOT_VERSION) git://git.denx.de/u-boot.git 'sources/u-boot'
	echo '$(UBOOT_VERSION)' > $@

sources/u-boot/.config: sources/u-boot.ready $(UBOOT_CONFIG_FRAGMENTS)
	$(MAKE) -C sources/u-boot/ '$(UBOOT_BOARD_DEFCONFIG)_defconfig'
	$(if $(UBOOT_CONFIG_FRAGMENTS),cd sources/u-boot && ./scripts/kconfig/merge_config.sh -m .config $(abspath $(UBOOT_CONFIG_FRAGMENTS)))
	$(if $(UBOOT_CONFIG_FRAGMENTS),$(MAKE) -C sources/u-boot/ $(MAKEFLAGS) olddefconfig)
	$(if $(UBOOT_CONFIG_FRAGMENTS),./verify-config.sh sources/u-boot/.config $(UBOOT_CONFIG_FRAGMENTS))
	@mkdir -p sources && echo '$(UBOOT_CONFIG_FINGERPRINT)' > sources/.uboot-config-fingerprint

sources/u-boot/$(UBOOT_FORMAT_CUSTOM_NAME): sources/u-boot/.config
	$(MAKE) -C sources/u-boot/ $(MAKEFLAGS) KCFLAGS=-fdiagnostics-color=always all

$(OUTPUT_DIR)/$(UBOOT_FORMAT_CUSTOM_NAME): sources/u-boot/$(UBOOT_FORMAT_CUSTOM_NAME) | $(OUTPUT_DIR)/
	cp $< $@

# Linux kernel
sources/linux.ready:
	git clone --depth=1 --branch $(KERNEL_VERSION) https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git 'sources/linux/'
	echo '$(KERNEL_VERSION)' > $@

# ./prepare-linux-tree.sh here covers the fresh-clone path (nothing to
# reset yet, so the parse-time check above skipped it); it's a fast no-op
# if the parse-time check already handled this target/profile's patches
# and DTS override. merge_config.sh only merges (-m); the explicit
# olddefconfig afterward is what actually resolves dependencies (§4).
# Neither merge_config.sh nor olddefconfig reliably fails the build on
# their own if an unmet dependency drops a requested symbol -- verify
# explicitly instead of trusting that, since a recipe pulled in via
# recipes.txt is exactly the kind of fragment nobody's hand-reviewing
# symbol-by-symbol.
sources/linux/.config: sources/linux.ready $(PATCH_FILES) $(KERNEL_CONFIG_FRAGMENTS)
	./prepare-linux-tree.sh sources/linux sources/.tree-prepared $(KERNEL_DT_FILE) "$(DTS_OVERRIDE)" $(PATCH_FILES)
	$(MAKE) -C sources/linux/ '$(KERNEL_DEFCONFIG)'
	$(if $(KERNEL_CONFIG_FRAGMENTS),cd sources/linux && ./scripts/kconfig/merge_config.sh -m .config $(abspath $(KERNEL_CONFIG_FRAGMENTS)))
	$(if $(KERNEL_CONFIG_FRAGMENTS),$(MAKE) -C sources/linux/ $(MAKEFLAGS) olddefconfig)
	$(if $(KERNEL_CONFIG_FRAGMENTS),./verify-config.sh sources/linux/.config $(KERNEL_CONFIG_FRAGMENTS))
	@mkdir -p sources && echo '$(KERNEL_CONFIG_FINGERPRINT)' > sources/.kernel-config-fingerprint

$(KERNEL_PRODUCTS) &: sources/linux/.config
	$(MAKE) -C sources/linux/ $(MAKEFLAGS) KCFLAGS=-fdiagnostics-color=always $(KERNEL_IMAGE_FILE) dtbs

$(KERNEL_PRODUCTS_OUTPUT) &: $(KERNEL_PRODUCTS) | $(OUTPUT_DIR)/
	cp $^ $(OUTPUT_DIR)/

# PROFILE is optional here, unlike everywhere else it's used: with it,
# captures into that profile's kernel.config/uboot.config; without it,
# captures into this target's common/ copy instead of some third
# "discard" mode -- menuconfig's own exit prompt ("save your
# configuration?") is already the point where you choose to keep or
# throw away a session, so a separate view-only mode here would just be
# a second, redundant way to say the same thing. See menuconfig.sh.
MENUCONFIG_TARGET := $(if $(PROFILE),$(PROFILE_DIR),$(COMMON_DIR))

.PHONY: kernel-menuconfig
kernel-menuconfig: sources/linux/.config
	@mkdir -p "$(MENUCONFIG_TARGET)"
	./menuconfig.sh sources/linux "$(MENUCONFIG_TARGET)/kernel.config"

.PHONY: uboot-menuconfig
uboot-menuconfig: sources/u-boot/.config
	@mkdir -p "$(MENUCONFIG_TARGET)"
	./menuconfig.sh sources/u-boot "$(MENUCONFIG_TARGET)/uboot.config"

# Alpine rootfs
sources/apk-tools/apk:
	ROOTFS_URL=$(ROOTFS_URL) ./ensure-apk.sh $@

$(OUTPUT_DIR)/packages.merged.txt: $(PACKAGES_SOURCES) | $(OUTPUT_DIR)/
	cat $(PACKAGES_SOURCES) > $@

$(ROOTFS_DIR): sources/apk-tools/apk $(PACKAGES_FILE) $(SETUP_SCRIPTS)
	ROOTFS_URL=$(ROOTFS_URL) ALPINE_ARCH=$(ALPINE_ARCH) APK="sources/apk-tools/apk" \
	    PACKAGES_FILE="$(PACKAGES_FILE)" SETUP_SCRIPTS="$(SETUP_SCRIPTS)" ./build-chroot.sh $@

# Build and install kernel modules to rootfs
$(ROOTFS_DIR)/lib/modules: $(ROOTFS_DIR) $(KERNEL_PRODUCTS)
	$(MAKE) -C sources/linux/ $(MAKEFLAGS) KCFLAGS=-fdiagnostics-color=always modules
	sudo $(MAKE) -C sources/linux/ $(MAKEFLAGS) INSTALL_MOD_PATH=$(abspath $(ROOTFS_DIR)) modules_install

$(ROOTFS_TARBALL): $(ROOTFS_DIR)/lib/modules | $(OUTPUT_DIR)/
	sudo tar -C $(ROOTFS_DIR) -czf $@ .

# Final image
$(IMAGE): make-image.sh $(OUTPUT_DIR)/$(UBOOT_FORMAT_CUSTOM_NAME) $(OUTPUT_DIR)/boot.scr $(ROOTFS_DIR)/lib/modules $(KERNEL_PRODUCTS_OUTPUT) $(OVERLAY_TARGETS) | $(OUTPUT_DIR)/
	sudo sh -c "                                              \
	    UBOOT='$(OUTPUT_DIR)/$(UBOOT_FORMAT_CUSTOM_NAME)'     \
	    UBOOT_WRITE_OFFSET='$(UBOOT_WRITE_OFFSET)'            \
	    BOOTSCR='$(OUTPUT_DIR)/boot.scr'                      \
	    KERNEL='$(word 1,$(KERNEL_PRODUCTS_OUTPUT))'          \
	    DTB='$(word 2,$(KERNEL_PRODUCTS_OUTPUT))'             \
	    DTBO_DIR='$(OUTPUT_DIR)/overlay'                      \
	    ROOTFS_DIR='$(ROOTFS_DIR)'                            \
	    IMAGE='$@'                                            \
	    ./make-image.sh"

.PHONY: clean
.SILENT: clean
clean:
	if [ -d $(ROOTFS_DIR) ]; then sudo rm -rf $(ROOTFS_DIR); fi
	rm -rf $(OUTPUT_DIR)

.PHONY: distclean
.SILENT: distclean
distclean: clean
	if [ -d sources/u-boot/ ]; then $(MAKE) -C sources/u-boot/ clean; fi
	if [ -d sources/linux/ ]; then $(MAKE) -C sources/linux/ clean; fi
	rm -rf sources/apk-tools sources/u-boot.ready sources/linux.ready sources/.tree-prepared sources/.board-fallback.mk sources/.kernel-config-fingerprint sources/.uboot-config-fingerprint

.PHONY: check-tools
check-tools:
	./check-tools.sh

.PHONY: install
.SILENT: install
install:
	@sudo -v
	@( makepid=$$PPID; while true; do sleep 60; kill -0 $$makepid 2>/dev/null || exit; sudo -n -v; done 2>/dev/null & )
	$(MAKE) $(MAKEFLAGS) $(IMAGE)
	sudo lsblk
	read -p "Enter the SD card device (e.g., /dev/sdX): " DEV; \
	if [ -z "$$DEV" ]; then echo "No device entered. Aborting."; exit 1; fi ; \
	if [ ! -b "$$DEV" ]; then echo "$$DEV is not a block device. Aborting."; exit 1; fi; \
	if lsblk -nrpo MOUNTPOINT "$$DEV" 2>/dev/null | grep -q .; then \
		echo "$$DEV (or one of its partitions) is currently mounted. Unmount it before proceeding. Aborting."; \
		exit 1; \
	fi; \
	read -p "Are you sure you want to write to $$DEV? This will erase all data on the device. (yes/no): " CONFIRM; \
	if [ "$$CONFIRM" != "yes" ]; then echo "Aborting."; exit 1; fi; \
	echo "Writing image to $$DEV..."; \
	sudo dd if=$(IMAGE) of="$$DEV" bs=4M status=progress conv=fsync; \
	sync; \
	echo "Image written to $$DEV. You can now remove the SD card."
