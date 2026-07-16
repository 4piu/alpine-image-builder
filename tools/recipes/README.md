# Recipes

Ready-to-use customization fragments for common needs — the answer to
"how do I get feature X" without hand-writing a kernel config fragment
from scratch. Each recipe is a real, repo-tracked file (not just prose in
a wiki page), so it's CI-testable and stays honest as kernel versions
move.

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
what's actually new — safe to run again after adding a recipe to the
list rather than needing to track by hand what you already applied.
Running with no `<recipe-name>` prints the current list of available
recipes.

**Declared in `recipes.txt`, resolved automatically on every build.**
List recipe names, one per line, in `target/<name>/common/recipes.txt`
or `target/<name>/profiles/<name>/recipes.txt` — see `target/README.md`.
Still nothing hidden: the list is a file you commit and review like any
other customization, it's just resolved fresh at build time instead of
merged once into `kernel.config` by hand. The build hard-fails, before
any kernel work starts, if a listed recipe doesn't exist, and hard-fails
again after configuring if any requested symbol didn't actually stick
(an unmet dependency, or a symbol that doesn't exist in this kernel
version) — never a silent partial apply.

See the wiki for the full walkthrough behind each recipe, and
`docs/kernel-customization.md` for kernel-config tribal knowledge that
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
  enabled by Alpine's stock kernel config — this is the exact pain that
  started this project. Pair with `zstd-modules` (see above) or the
  driver won't load. Not build-tested against real kernel source (no
  network access in the environment this was written in) — the fragment
  sets the leaf driver symbol and relies on Kconfig's own `select`
  statements to pull in its dependencies; `merge_config.sh` reports if
  anything doesn't stick, so review that output on first use.
