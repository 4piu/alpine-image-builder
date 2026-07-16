# Recipes

Ready-to-use customization fragments for common needs — the answer to
"how do I get feature X" without hand-writing a kernel config fragment
from scratch. Each recipe is a real, repo-tracked file, so it's
CI-testable and stays honest as kernel versions move.

```
tools/recipes/<name>.config     # kernel config fragment
tools/recipes/apply-recipes.sh  # generic: merges any number of recipes
                                 # into your chosen target/profile
```

Two ways to use a recipe — pick whichever fits what you're doing:

**One-time merge, then it's just your `kernel.config`.** Name however
many recipes you want in one go, review the diff, then build. Good for
taking a recipe as a starting point you intend to hand-edit further.

```
tools/recipes/apply-recipes.sh target/<name>/profiles/<profile-name>/ wifi-8821cu zstd-modules
```

Each applied recipe is tagged with a `# --- recipe: <name> ---` marker
in the destination `kernel.config`, so re-running the same list against
a profile that already has some (or all) of them applied only appends
what's actually new. Running with no `<recipe-name>` prints the current
list of available recipes.

**Declared in `recipes.txt`, resolved automatically on every build.**
List recipe names, one per line, in `target/<name>/common/recipes.txt`
or `target/<name>/profiles/<name>/recipes.txt` — see `target/README.md`.
The build hard-fails, before any kernel work starts, if a listed recipe
doesn't exist, and hard-fails again after configuring if any requested
symbol didn't actually stick — never a silent partial apply.

See `docs/kernel-customization.md` for kernel-config background that
applies regardless of which recipe you're using.

## Recipes

- `zstd-modules` — kernel module compression
  (`CONFIG_MODULE_COMPRESS_ZSTD`). Not needed for a stock, module-free
  image, but needed by *any* recipe that adds a loadable module —
  `menuconfig` doesn't turn this on as a dependency of building one, so
  it's easy to add a driver, get a clean build, and have it silently fail
  to load on the actual board. See `docs/kernel-customization.md`.
- `wifi-8821cu` — RTL8821CU USB wifi. Mainlined
  (`drivers/net/wireless/realtek/rtw88`, `CONFIG_RTW88_8821CU`), just not
  enabled by Alpine's stock kernel config. Pair with `zstd-modules` or
  the driver won't load.
