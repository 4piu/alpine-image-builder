#!/bin/bash
# Imports board-bringup content from armbian/build and armbian/firmware into
# a target/profile's committed customization directories -- a one-time,
# user-invoked authoring step, never anything live at build time. Same
# trust boundary as tools/recipes/apply-recipes.sh: content lands as
# ordinary, reviewable files; nothing is fetched or run during `make build`.
# See notes/armbian-kernel-patches-brainstorm.md for why, and
# docs/importing-from-armbian.md for how to find the values this script's
# arguments expect (KERNELPATCHDIR, a driver's patch/misc/ name).
#
# Three source kinds, each shaped differently upstream:
#   kernel <patch-dir>    patch/kernel/<patch-dir>/ in armbian/build --
#                          series.conf-selected patches (any patches.*/
#                          subdirectory), plus dt_*/overlay_* (full-DTS /
#                          DT-overlay files, not series.conf-gated at all).
#   misc <driver-name>    patch/misc/<driver-name>/ in armbian/build --
#                          a flat patch directory for one out-of-tree driver,
#                          opted into by a board's own extensions/*.sh.
#   firmware               armbian/firmware -- a separate repo, flat binary/
#                          text firmware files, no patch semantics at all.
#
# Usage:
#   armbian-import.sh list kernel   <patch-dir>   [pattern]
#   armbian-import.sh list misc     <driver-name> [pattern]
#   armbian-import.sh list firmware               [pattern]
#   armbian-import.sh import <target-dir> kernel   <patch-dir>   <path> [<path> ...]
#   armbian-import.sh import <target-dir> misc     <driver-name> <path> [<path> ...]
#   armbian-import.sh import <target-dir> firmware               <path> [<path> ...]
#
# <target-dir> is a target's common/ or profiles/<name>/ directory, e.g.
# target/orangepi-zero3/common. <path> is whatever `list` printed in its
# first column -- copy it verbatim into the next `import` call.

set -euo pipefail

source "$(dirname "$0")/../colors.sh"

BUILD_REPO="armbian/build"
BUILD_REF="main"
FIRMWARE_REPO="armbian/firmware"
FIRMWARE_REF="master"

command -v curl >/dev/null || die "curl is required to fetch from $BUILD_REPO/$FIRMWARE_REPO"

usage()
{
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

api_get()
{
    # $1 = full api.github.com path+query, e.g. "repos/armbian/build/contents/patch/kernel"
    curl -sf "https://api.github.com/$1" || die "GitHub API request failed: $1 (network issue, or the path doesn't exist upstream)"
}

raw_get()
{
    # $1 = repo, $2 = ref, $3 = path within the repo
    curl -sf "https://raw.githubusercontent.com/$1/$2/$3" || die "Failed to fetch $1/$2/$3 -- check the path is correct (see \`list\`)"
}

# Extracts "name" values from a GitHub Contents API JSON array, in order.
# Relies on the API's own pretty-printed, one-key-per-line output (verified
# directly against a real response) rather than pulling in a JSON parser
# this project doesn't otherwise depend on.
json_names()
{
    grep -o '"name": *"[^"]*"' | sed -E 's/"name": *"([^"]*)"/\1/'
}

json_names_of_type()
{
    # $1 = "file" or "dir". Pairs each entry's "name"/"type" lines (always
    # adjacent in the Contents API's own field order) two at a time.
    local type="$1"
    grep -E '"name":|"type":' | paste -d'\t' - - | awk -F'\t' -v t="\"type\": \"$type\"" '$2 ~ t' \
        | sed -E 's/^[[:space:]]*"name": *"([^"]*)".*/\1/'
}

commit_sha()
{
    # $1 = repo, $2 = ref -- resolves a branch name to the exact commit this
    # import is pinned against, recorded in ARMBIAN-IMPORTS.md so a later
    # re-check knows exactly what was fetched, not just "main, sometime".
    # Captured into a variable before grep/sed, not piped directly from a
    # live curl -- a pipe into an early-exiting consumer (grep -m1, head)
    # can SIGPIPE curl mid-write, which api_get's own `|| die` then
    # misreports as a network failure even though the fetch succeeded.
    local body; body="$(api_get "repos/$1/commits/$2")"
    echo "$body" | grep -m1 '"sha"' | sed -E 's/.*"sha": *"([^"]*)".*/\1/'
}

# --- list ---------------------------------------------------------------

list_kernel()
{
    local patch_dir="$1" pattern="${2:-}"
    local root series
    root="$(api_get "repos/$BUILD_REPO/contents/patch/kernel/$patch_dir?ref=$BUILD_REF")"

    series="$(raw_get "$BUILD_REPO" "$BUILD_REF" "patch/kernel/$patch_dir/series.conf")"
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -z "$line" ] && continue
        local status="enabled" p="$line"
        if [[ "$p" == -* ]]; then
            status="disabled"
            p="${p#-}"
            p="$(echo "$p" | sed -E 's/^[[:space:]]+//')"
        fi
        if [ -z "$pattern" ] || echo "$p" | grep -qi -- "$pattern"; then
            printf '%-9s %-9s %s\n' "[patch]" "[$status]" "$p"
        fi
    done <<< "$series"

    local dtdir
    for dtdir in $(echo "$root" | json_names_of_type dir | grep -E '^(dt|overlay)_'); do
        local kind="dts"
        [[ "$dtdir" == overlay_* ]] && kind="overlay"
        local f
        for f in $(api_get "repos/$BUILD_REPO/contents/patch/kernel/$patch_dir/$dtdir?ref=$BUILD_REF" | json_names); do
            local p="$dtdir/$f"
            if [ -z "$pattern" ] || echo "$p" | grep -qi -- "$pattern"; then
                printf '%-9s %-9s %s\n' "[$kind]" "" "$p"
            fi
        done
    done
}

list_misc()
{
    local driver="$1" pattern="${2:-}"
    local f
    for f in $(api_get "repos/$BUILD_REPO/contents/patch/misc/$driver?ref=$BUILD_REF" | json_names); do
        if [ -z "$pattern" ] || echo "$f" | grep -qi -- "$pattern"; then
            printf '%-9s %s\n' "[patch]" "$f"
        fi
    done
}

list_firmware()
{
    local pattern="${1:-}"
    local p
    api_get "repos/$FIRMWARE_REPO/git/trees/$FIRMWARE_REF?recursive=1" \
        | grep -E '"path":|"type":' | paste -d'\t' - - \
        | awk -F'\t' '$2 ~ /"type": "blob"/' \
        | sed -E 's/^[[:space:]]*"path": *"([^"]*)".*/\1/' \
        | while IFS= read -r p; do
            if [ -z "$pattern" ] || echo "$p" | grep -qi -- "$pattern"; then
                printf '%-9s %s\n' "[file]" "$p"
            fi
        done
}

# --- import ---------------------------------------------------------------

# Shared bookkeeping: <target-dir>/ARMBIAN-IMPORTS.md tracks every file this
# script has copied in, so a later run skips duplicates and a later
# KERNEL_VERSION bump knows what to recheck. Never written into a patch's
# own header -- that risks confusing git apply's hunk parsing on Armbian's
# mbox-style patches for no real benefit.
ensure_manifest()
{
    local manifest="$1/ARMBIAN-IMPORTS.md"
    if [ ! -f "$manifest" ]; then
        cat > "$manifest" <<'EOF'
# Armbian imports

Tracked here so a future `KERNEL_VERSION` bump knows what to recheck against
upstream -- an Armbian patch can be superseded by mainline (it happens: see
notes/armbian-kernel-patches-brainstorm.md) or itself change. Generated by
`tools/armbian-import.sh`; edit freely, this file drives nothing at build
time.

| Local file | Armbian source | Commit | Imported |
| --- | --- | --- | --- |
EOF
    fi
    echo "$manifest"
}

already_imported()
{
    # $1 = manifest path, $2 = source description to match on
    grep -qF "$2" "$1" 2>/dev/null
}

record_import()
{
    # $1 = manifest, $2 = local file (relative to target-dir), $3 = source description, $4 = sha
    printf '| %s | %s | %s | %s |\n' "$2" "$3" "$4" "$(date +%F)" >> "$1"
}

next_patch_seq()
{
    # Highest existing armbian-NNNN- prefix in <target-dir>/patches/, so a
    # multi-file import extends the sequence instead of colliding with it.
    local dir="$1/patches" max=0 n
    [ -d "$dir" ] || { echo 1; return; }
    for f in "$dir"/armbian-*.patch; do
        [ -e "$f" ] || continue
        n="$(basename "$f" | sed -E 's/^armbian-([0-9]+)-.*/\1/')"
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$max" ] && max="$n"
    done
    echo $((max + 1))
}

import_kernel_or_misc()
{
    # $1 = tree ("kernel" or "misc"), $2 = target-dir, $3 = patch-dir/driver-name, shift 3, rest = paths
    local tree="$1" target_dir="$2" sel="$3"; shift 3
    local manifest seq
    manifest="$(ensure_manifest "$target_dir")"
    seq="$(next_patch_seq "$target_dir")"

    local sha
    sha="$(commit_sha "$BUILD_REPO" "$BUILD_REF")"

    local path
    for path in "$@"; do
        local upstream_path="patch/kernel/$sel/$path"
        [ "$tree" = "misc" ] && upstream_path="patch/misc/$sel/$path"
        local desc="$BUILD_REPO $upstream_path"

        if already_imported "$manifest" "$desc"; then
            log "already imported: $desc -- skipping"
            continue
        fi

        if [ "$tree" = "kernel" ] && [[ "$path" == dt_*/* ]]; then
            local base; base="$(basename "$path")"
            if [[ "$base" == *.dtsi ]]; then
                die "$path is a .dtsi include file, not a standalone board DTS -- this project's dts/*.dts full-replacement mechanism (see target/README.md) only builds a single complete .dts file, and a Makefile wildcard match on *.dts silently won't see a .dtsi at all. Import whichever sibling .dts in the same dt_* directory #includes it instead, or merge this content by hand."
            fi
            local dest_dir="$target_dir/dts"
            mkdir -p "$dest_dir"
            local existing
            existing="$(find "$dest_dir" -maxdepth 1 -name '*.dts' 2>/dev/null | grep -v "/$base\$" || true)"
            [ -n "$existing" ] && warn "$dest_dir already has $(basename "$existing") -- only one dts/*.dts is used (profile wins over common); importing $base anyway, but you likely want to remove one"
            raw_get "$BUILD_REPO" "$BUILD_REF" "$upstream_path" > "$dest_dir/$base"
            record_import "$manifest" "dts/$base" "$desc" "$sha"
            log "imported dts/$base <- $desc"
        elif [ "$tree" = "kernel" ] && [[ "$path" == overlay_*/* ]]; then
            local base; base="$(basename "$path" .dtso)"
            local dest_dir="$target_dir/overlays"
            mkdir -p "$dest_dir"
            raw_get "$BUILD_REPO" "$BUILD_REF" "$upstream_path" > "$dest_dir/$base.dts"
            record_import "$manifest" "overlays/$base.dts" "$desc" "$sha"
            log "imported overlays/$base.dts <- $desc"
        else
            local base; base="$(basename "$path")"
            local dest_dir="$target_dir/patches"
            mkdir -p "$dest_dir"
            local fname; fname="$(printf 'armbian-%04d-%s' "$seq" "$base")"
            raw_get "$BUILD_REPO" "$BUILD_REF" "$upstream_path" > "$dest_dir/$fname"
            record_import "$manifest" "patches/$fname" "$desc" "$sha"
            log "imported patches/$fname <- $desc"
            seq=$((seq + 1))
        fi
    done
}

import_firmware()
{
    local target_dir="$1"; shift
    local manifest; manifest="$(ensure_manifest "$target_dir")"
    local sha; sha="$(commit_sha "$FIRMWARE_REPO" "$FIRMWARE_REF")"

    local path
    for path in "$@"; do
        local desc="$FIRMWARE_REPO $path"
        if already_imported "$manifest" "$desc"; then
            log "already imported: $desc -- skipping"
            continue
        fi
        local base; base="$(basename "$path")"
        local dest_dir="$target_dir/firmware"
        mkdir -p "$dest_dir"
        # Basename only -- Armbian's own subdirectory layout in their
        # firmware repo (e.g. uwe5622/wcnmodem.bin) is their convention,
        # not a runtime requirement; this project's build installs
        # firmware/* flat into the rootfs's /lib/firmware/ (Makefile), which
        # matches what the drivers here actually request at runtime.
        raw_get "$FIRMWARE_REPO" "$FIRMWARE_REF" "$path" > "$dest_dir/$base"
        record_import "$manifest" "firmware/$base" "$desc" "$sha"
        log "imported firmware/$base <- $desc"
    done
}

# --- main -------------------------------------------------------------

[ $# -ge 1 ] || usage

case "$1" in
    list)
        shift
        [ $# -ge 1 ] || usage
        case "$1" in
            kernel)   [ $# -ge 2 ] || usage; list_kernel "$2" "${3:-}" ;;
            misc)     [ $# -ge 2 ] || usage; list_misc "$2" "${3:-}" ;;
            firmware) list_firmware "${2:-}" ;;
            *) usage ;;
        esac
        ;;
    import)
        shift
        [ $# -ge 3 ] || usage
        target_dir="$1"; kind="$2"; shift 2
        case "$kind" in
            kernel)   [ $# -ge 2 ] || usage; sel="$1"; shift; import_kernel_or_misc kernel "$target_dir" "$sel" "$@" ;;
            misc)     [ $# -ge 2 ] || usage; sel="$1"; shift; import_kernel_or_misc misc "$target_dir" "$sel" "$@" ;;
            firmware) [ $# -ge 1 ] || usage; import_firmware "$target_dir" "$@" ;;
            *) usage ;;
        esac
        ;;
    *) usage ;;
esac
