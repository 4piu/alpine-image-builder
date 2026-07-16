#!/bin/bash
# Merges one or more tools/recipes/<name>.config fragments into a
# target/profile's kernel.config and prints the diff for review. Never
# applied automatically -- copy fragments by hand instead if you'd
# rather not run this. See tools/recipes/README.md.
#
# Usage: tools/recipes/apply-recipes.sh target/<name>/profiles/<profile-name>/ <recipe-name> [<recipe-name> ...]

set -euo pipefail

recipe_dir="$(cd "$(dirname "$0")" && pwd)"

list_available()
{
    local available
    available="$(cd "$recipe_dir" && ls -- *.config 2>/dev/null | sed 's/\.config$//')"
    if [ -n "$available" ]; then
        echo "Available recipes:" >&2
        echo "$available" | sed 's/^/  /' >&2
    fi
}

if [ $# -lt 2 ]; then
    echo "Usage: $0 target/<name>/profiles/<profile-name>/ <recipe-name> [<recipe-name> ...]" >&2
    list_available
    exit 1
fi

dest_dir="$1"; shift
dest="$dest_dir/kernel.config"

mkdir -p "$dest_dir"
touch "$dest"
before="$(mktemp)"
trap 'rm -f "$before"' EXIT
cp "$dest" "$before"

applied_any=false
for name in "$@"; do
    recipe="$recipe_dir/$name.config"
    if [ ! -f "$recipe" ]; then
        echo "No such recipe: $name (expected $recipe)" >&2
        list_available
        exit 1
    fi

    # Marker-based idempotency: each applied recipe is tagged with its
    # own "--- recipe: NAME ---" header, so re-running this against a
    # profile that already has it is a no-op instead of a duplicate
    # block -- generic across every recipe, no need to know which
    # Kconfig symbols any given one happens to set.
    marker="# --- recipe: $name ---"
    if grep -qF "$marker" "$dest"; then
        echo "$name already applied to $dest -- skipping." >&2
        continue
    fi

    if [ -s "$dest" ]; then
        printf '\n' >> "$dest"
    fi
    echo "$marker" >> "$dest"
    cat "$recipe" >> "$dest"
    applied_any=true
done

if [ "$applied_any" = false ]; then
    echo "Nothing new to apply."
    exit 0
fi

echo "Merged into $dest -- review before building:"
diff -u "$before" "$dest" || true
