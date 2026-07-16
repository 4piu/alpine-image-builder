#!/bin/bash
# Verifies that every CONFIG_X assertion requested by a set of
# kernel.config fragments actually stuck in the resulting .config after
# merge_config.sh + olddefconfig. Neither of those treats an unmet
# dependency (or a symbol that doesn't exist in this kernel version) as
# a hard failure on its own -- a requested value can silently not appear
# in the final .config, which matters a lot for a recipe someone pulled
# in via recipes.txt without hand-reviewing every symbol.
#
# Usage: verify-kernel-config.sh <config-file> <fragment-file> [<fragment-file> ...]
# Exits non-zero and lists every mismatch if anything didn't stick.

set -euo pipefail

config_file="$1"; shift

# symbol name -> the last fragment line that requested it. Built up in
# the same order the fragments were passed to merge_config.sh, so a
# later fragment intentionally overriding an earlier one's symbol (the
# whole point of the common -> profile merge order) naturally replaces
# the earlier request here too -- only the final, effective request per
# symbol gets checked, not every fragment's request independently.
declare -A wanted

for fragment in "$@"; do
    while IFS= read -r line; do
        case "$line" in
            CONFIG_*=*)
                symbol="${line%%=*}"
                ;;
            "# CONFIG_"*" is not set")
                symbol="${line#\# }"
                symbol="${symbol%% is not set}"
                ;;
            *)
                continue
                ;;
        esac
        wanted["$symbol"]="$line"
    done < "$fragment"
done

mismatches=()
for symbol in "${!wanted[@]}"; do
    line="${wanted[$symbol]}"
    if ! grep -qxF "$line" "$config_file"; then
        mismatches+=("$symbol: wanted '$line'")
    fi
done

if [ ${#mismatches[@]} -gt 0 ]; then
    echo "ERROR: the following requested kernel config values did not stick in $config_file" >&2
    echo "(unmet dependency, or the symbol doesn't exist in this kernel version):" >&2
    printf '  %s\n' "${mismatches[@]}" | sort >&2
    exit 1
fi
