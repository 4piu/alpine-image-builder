#!/bin/bash

# Script to check for required tools to build an Alpine SBC image.
# Exit codes: 0 = all tools found, 1 = missing tools

set -euo pipefail

CROSS_COMPILE_PREFIX="${CROSS_COMPILE:-arm-none-eabi-}"
CROSS_COMPILER="${CROSS_COMPILE_PREFIX}gcc"
# First hyphen-separated component of the prefix (arm-none-eabi- -> arm,
# aarch64-linux-gnu- -> aarch64) — used to search for an equivalent
# toolchain if the exact CROSS_COMPILE isn't installed, without assuming
# armv7 is the only architecture this project ever targets.
CROSS_ARCH="${CROSS_COMPILE_PREFIX%%-*}"

missing_tools=()
found_tools=()

# Core build tools required
required_tools="gcc make tar sed grep wget git sfdisk mkfs.ext4 losetup xargs mkimage du dtc python3 swig zstd sha256sum realpath comm"

echo "Checking for required build tools..."

# Check for kpartx or partx (disk partitioning tools)
kpartx_path=$(which kpartx 2>/dev/null || true)
partx_path=$(which partx 2>/dev/null || true)

if [ -z "$kpartx_path" ] && [ -z "$partx_path" ]; then
    missing_tools+=("kpartx or partx")
else
    if [ -n "$kpartx_path" ]; then
        found_tools+=("kpartx")
    else
        found_tools+=("partx")
    fi
fi

# Check each required tool
for tool in $required_tools; do
    tool_path=$(which "$tool" 2>/dev/null || true)
    if [ -z "$tool_path" ]; then
        missing_tools+=("$tool")
    else
        found_tools+=("$tool")
    fi
done

# U-Boot 2026.x uses Python tooling which imports these modules during the build.
python3_path=$(which python3 2>/dev/null || true)
if [ -n "$python3_path" ]; then
    if "$python3_path" - <<'PY' >/dev/null 2>&1
import setuptools
PY
    then
        found_tools+=("python3 setuptools module")
    else
        missing_tools+=("python3 setuptools module (install python3-setuptools / py3-setuptools)")
    fi

    if "$python3_path" - <<'PY' >/dev/null 2>&1
import elftools
PY
    then
        found_tools+=("python3 elftools module")
    else
        missing_tools+=("python3 elftools module (install python3-pyelftools / py3-elftools)")
    fi
fi

# Check for cross-compiler
cross_compiler_path=$(which "$CROSS_COMPILER" 2>/dev/null || true)
if [ -z "$cross_compiler_path" ]; then
    # Try to find any cross-compiler for the same architecture as a fallback
    gcc_dir=$(dirname "$(which gcc 2>/dev/null || echo '/usr/bin')")
    gcc_candidates=$(ls "$gcc_dir"/${CROSS_ARCH}-*-gcc 2>/dev/null || true)

    if [ -z "$gcc_candidates" ]; then
        missing_tools+=("$CROSS_COMPILER (or any ${CROSS_ARCH}-*-gcc)")
    else
        # Found alternative cross-compiler for this architecture
        alt_compiler=$(echo "$gcc_candidates" | head -n1)
        found_tools+=("$(basename "$alt_compiler") (alternative to $CROSS_COMPILER)")
    fi
else
    found_tools+=("$CROSS_COMPILER")
fi

# Report results
echo
echo "=== Tool Check Results ==="

if [ ${#found_tools[@]} -gt 0 ]; then
    echo "✓ Found tools (${#found_tools[@]}):"
    printf "  %s\n" "${found_tools[@]}"
fi

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo
    echo "✗ Missing tools (${#missing_tools[@]}):"
    printf "  %s\n" "${missing_tools[@]}"
    echo
    echo "Please install the missing tools before proceeding with the build."
    exit 1
fi

echo
echo "✓ All required tools are available. Ready to proceed with build!"
