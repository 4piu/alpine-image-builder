#!/bin/sh
# One-time post-expansion hook for this target -- see target/README.md.
# Baked into the image and run exactly once, after first-boot rootfs
# expansion has fully completed (not on every boot, not mid-expansion).
# Empty (or missing entirely) has no effect.
#
# Runs as root, via `sh`, after expand-rootfs.sh's completion marker
# shows up. A non-zero exit leaves the hook installed to retry next boot.
#
# Add commands like:
#   apk add --no-cache htop
#   rc-update add some-service default
