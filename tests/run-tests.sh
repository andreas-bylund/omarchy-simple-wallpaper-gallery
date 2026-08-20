#!/bin/bash
# Tests for bin/wallpaper-gallery, the plugin's filesystem backend.
#
#   tests/run-tests.sh
#
# Every test runs against a throwaway HOME and a throwaway wallpaper folder,
# so nothing here touches the machine's real Omarchy state. Commands that
# would change the desktop (set, random, hook) are covered through their
# observable side effects on that fake HOME, never by calling out to
# omarchy-theme-bg-set.

set -uo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
GALLERY="$REPO_DIR/bin/wallpaper-gallery"
TAB=$'\t'
KEEP_LINK=".00-wallpaper-gallery-current"

passed=0
failed=0

pass() { printf '  ok   %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; failed=$((failed + 1)); }

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    pass "$label"
  else
    fail "$label" "expected [$expected], got [$actual]"
  fi
}

# Counting our own keep-links, by a name we control.
count_links() {
  find "$1" -maxdepth 2 -name "$KEEP_LINK.*" 2>/dev/null | wc -l
}

count_cache() {
  find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l
}

drop_sandbox() {
  [[ -n ${SANDBOX:-} && -d ${SANDBOX:-} && $SANDBOX == "${TMPDIR:-/tmp}"/* ]] &&
    rm -rf "$SANDBOX"
  return 0
}
trap drop_sandbox EXIT

# A sandbox HOME plus an empty wallpaper folder, replacing any previous one.
make_sandbox() {
  drop_sandbox
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  export XDG_CACHE_HOME="$SANDBOX/cache"
  export XDG_STATE_HOME="$SANDBOX/state"
  WALLPAPERS="$SANDBOX/wallpapers"
  CACHE="$XDG_CACHE_HOME/omarchy-wallpaper-gallery"
  STATE="$XDG_STATE_HOME/omarchy-wallpaper-gallery"
  mkdir -p "$HOME" "$WALLPAPERS"
}

# A minimal valid PNG, so vipsthumbnail has something real to chew on.
make_png() {
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' >"$1"
}

# The wallpaper the keep-mode tests hang their links on.
seed_keeper() {
  make_png "$WALLPAPERS/keeper.png"
  mkdir -p "$STATE"
  printf '%s\n' "$WALLPAPERS/keeper.png" >"$STATE/last-wallpaper"
}

echo "wallpaper-gallery tests"

# --------------------------------------------------------------- list basics
make_sandbox
make_png "$WALLPAPERS/one.png"
make_png "$WALLPAPERS/two.jpg"
: >"$WALLPAPERS/notes.txt"
mkdir -p "$WALLPAPERS/nested"
make_png "$WALLPAPERS/nested/three.png"

rows=$("$GALLERY" list "$WALLPAPERS" 0)
check_eq "list finds images, skips non-images" "2" "$(printf '%s\n' "$rows" | grep -c .)"
check_eq "list stays out of subfolders by default" "0" \
  "$(printf '%s\n' "$rows" | grep -c nested)"
check_eq "list puts the path last" "$WALLPAPERS/one.png" \
  "$(printf '%s\n' "$rows" | head -1 | cut -d"$TAB" -f2-)"
check_eq "list leaves the thumbnail empty before caching" "" \
  "$(printf '%s\n' "$rows" | head -1 | cut -d"$TAB" -f1)"

rows=$("$GALLERY" list "$WALLPAPERS" 1)
check_eq "list recurses when asked" "3" "$(printf '%s\n' "$rows" | grep -c .)"

# ------------------------------------------------------- awkward file names
make_png "$WALLPAPERS/with${TAB}tab.png"
rows=$("$GALLERY" list "$WALLPAPERS" 0)
check_eq "a tab in a filename still yields one row" "3" "$(printf '%s\n' "$rows" | grep -c .)"
check_eq "a tabbed path survives intact" "$WALLPAPERS/with${TAB}tab.png" \
  "$(printf '%s\n' "$rows" | grep 'tab.png' | cut -d"$TAB" -f2-)"

make_png "$WALLPAPERS/with"$'\n'"newline.png"
rows=$("$GALLERY" list "$WALLPAPERS" 0)
check_eq "a newline in a filename is skipped, not mangled" "3" \
  "$(printf '%s\n' "$rows" | grep -c .)"
rm -f "$WALLPAPERS/with"$'\n'"newline.png" "$WALLPAPERS/with${TAB}tab.png"

# ------------------------------------------------- unreadable subdirectories
mkdir -p "$WALLPAPERS/locked"
chmod 000 "$WALLPAPERS/locked"
"$GALLERY" list "$WALLPAPERS" 1 >/dev/null
check_eq "an unreadable subfolder does not fail the listing" "0" "$?"
check_eq "images outside the unreadable subfolder are still listed" "3" \
  "$("$GALLERY" list "$WALLPAPERS" 1 | grep -c .)"
chmod 755 "$WALLPAPERS/locked"
rmdir "$WALLPAPERS/locked"

# ------------------------------------------------------------ missing input
"$GALLERY" list "$SANDBOX/does-not-exist" 0 >/dev/null 2>&1
check_eq "list fails on a missing folder" "1" "$?"

# ------------------------------------------------------------------- tilde
mkdir -p "$HOME/Pictures/shots"
make_png "$HOME/Pictures/shots/pic.png"
# The literal ~ and $HOME are the input under test, not paths for this shell.
# shellcheck disable=SC2088,SC2016
check_eq "a ~ path is expanded" "$HOME/Pictures/shots/pic.png" \
  "$("$GALLERY" list '~/Pictures/shots' 0 | cut -d"$TAB" -f2-)"
# shellcheck disable=SC2016
check_eq "a \$HOME path is expanded" "$HOME/Pictures/shots/pic.png" \
  "$("$GALLERY" list '$HOME/Pictures/shots' 0 | cut -d"$TAB" -f2-)"

# ------------------------------------------------------- hidden subfolders
mkdir -p "$WALLPAPERS/.hidden"
make_png "$WALLPAPERS/.hidden/secret.png"
check_eq "a dot-folder is pruned even when recursing" "0" \
  "$("$GALLERY" list "$WALLPAPERS" 1 | grep -c secret.png)"
rm -rf "$WALLPAPERS/.hidden"

# ------------------------------------------------------------ set validation
"$GALLERY" set "$SANDBOX/gone.png" >/dev/null 2>&1
check_eq "set refuses a path that does not exist" "1" "$?"
check_eq "a refused set records nothing" "0" \
  "$([[ -f $STATE/last-wallpaper ]] && echo 1 || echo 0)"

# ------------------------------------------------------------ hook lifecycle
check_eq "the hook starts off" "off" "$("$GALLERY" hook status)"
"$GALLERY" hook on
check_eq "hook on installs the hook" "on" "$("$GALLERY" hook status)"
check_eq "the installed hook is executable" "1" \
  "$([[ -x $HOME/.config/omarchy/hooks/theme-set.d/wallpaper-gallery-keep ]] && echo 1 || echo 0)"
bash -n "$HOME/.config/omarchy/hooks/theme-set.d/wallpaper-gallery-keep"
check_eq "the generated hook is valid bash" "0" "$?"
"$GALLERY" hook off
check_eq "hook off removes it" "off" "$("$GALLERY" hook status)"

# ------------------------------------------- keep-links spare the user's own
mkdir -p "$HOME/.config/omarchy/themes/mytheme"
mkdir -p "$HOME/.config/omarchy/backgrounds/handmade"
make_png "$HOME/.config/omarchy/backgrounds/handmade/mine.png"
mkdir -p "$HOME/.config/omarchy/backgrounds/empty-of-mine"
seed_keeper
OMARCHY_PATH="$SANDBOX/no-such-omarchy" "$GALLERY" hook on
check_eq "a keep-link is seeded for each theme" "1" \
  "$(count_links "$HOME/.config/omarchy/backgrounds/mytheme")"

OMARCHY_PATH="$SANDBOX/no-such-omarchy" "$GALLERY" hook off
check_eq "hook off clears the keep-links" "0" \
  "$(count_links "$HOME/.config/omarchy/backgrounds")"
check_eq "a folder the user filled themselves survives" "1" \
  "$([[ -f $HOME/.config/omarchy/backgrounds/handmade/mine.png ]] && echo 1 || echo 0)"
check_eq "an empty folder the user made themselves survives" "1" \
  "$([[ -d $HOME/.config/omarchy/backgrounds/empty-of-mine ]] && echo 1 || echo 0)"
check_eq "a folder the plugin created is cleaned up" "0" \
  "$([[ -d $HOME/.config/omarchy/backgrounds/mytheme ]] && echo 1 || echo 0)"

# ----------------------------------------------------- a vanished kept image
seed_keeper
OMARCHY_PATH="$SANDBOX/no-such-omarchy" "$GALLERY" hook on
rm -f "$WALLPAPERS/keeper.png"
mkdir -p "$HOME/.config/omarchy/themes/mytheme"
OMARCHY_PATH="$SANDBOX/no-such-omarchy" "$GALLERY" hook on
check_eq "links to a deleted wallpaper are dropped, not left stale" "0" \
  "$(count_links "$HOME/.config/omarchy/backgrounds")"

# ---------------------------------------------------------------- uninstall
"$GALLERY" hook on >/dev/null
"$GALLERY" uninstall >/dev/null
check_eq "uninstall removes the hook" "0" \
  "$([[ -f $HOME/.config/omarchy/hooks/theme-set.d/wallpaper-gallery-keep ]] && echo 1 || echo 0)"
check_eq "uninstall removes the cache" "0" \
  "$([[ -d $CACHE ]] && echo 1 || echo 0)"
check_eq "uninstall removes the saved state" "0" \
  "$([[ -d $STATE ]] && echo 1 || echo 0)"
check_eq "uninstall still spares the user's own backgrounds" "1" \
  "$([[ -f $HOME/.config/omarchy/backgrounds/handmade/mine.png ]] && echo 1 || echo 0)"

# ------------------------------------------- the backgrounds root, both ways
make_sandbox
mkdir -p "$HOME/.config/omarchy/themes/solo"
mkdir -p "$HOME/.config/omarchy/backgrounds"
seed_keeper
OMARCHY_PATH="$SANDBOX/no-such-omarchy" "$GALLERY" hook on
OMARCHY_PATH="$SANDBOX/no-such-omarchy" "$GALLERY" hook off
check_eq "an empty backgrounds root the user made survives" "1" \
  "$([[ -d $HOME/.config/omarchy/backgrounds ]] && echo 1 || echo 0)"

make_sandbox
mkdir -p "$HOME/.config/omarchy/themes/solo"
seed_keeper
OMARCHY_PATH="$SANDBOX/no-such-omarchy" "$GALLERY" hook on
check_eq "a missing backgrounds root is created" "1" \
  "$([[ -d $HOME/.config/omarchy/backgrounds ]] && echo 1 || echo 0)"
OMARCHY_PATH="$SANDBOX/no-such-omarchy" "$GALLERY" hook off
check_eq "a backgrounds root the plugin made goes with the links" "0" \
  "$([[ -d $HOME/.config/omarchy/backgrounds ]] && echo 1 || echo 0)"

# ------------------------------------------------------- thumbnails (if any)
if command -v vipsthumbnail >/dev/null 2>&1; then
  make_sandbox
  make_png "$WALLPAPERS/thumbme.png"
  "$GALLERY" thumbs "$WALLPAPERS" 0
  thumb=$("$GALLERY" list "$WALLPAPERS" 0 | grep 'thumbme.png' | cut -d"$TAB" -f1)
  check_eq "a generated thumbnail is picked up by list" "1" \
    "$([[ -n $thumb && -f $thumb ]] && echo 1 || echo 0)"
  check_eq "the index has one row per thumbnailed image" "1" \
    "$(grep -c 'thumbme.png' "$CACHE/index.tsv" 2>/dev/null)"
  check_eq "generation leaves no lock files behind" "0" \
    "$(count_cache "$CACHE" '*.jpg.lock')"

  # The row protocol puts the path last so a tab cannot shift the columns;
  # the index has to do the same, or these files miss on every lookup and are
  # re-hashed and re-thumbnailed for as long as they exist.
  make_png "$WALLPAPERS/tabbed${TAB}name.png"
  "$GALLERY" thumbs "$WALLPAPERS" 0
  before=$(grep -c . "$CACHE/index.tsv")
  "$GALLERY" thumbs "$WALLPAPERS" 0
  check_eq "a tabbed filename hits the index instead of being re-added" \
    "$before" "$(grep -c . "$CACHE/index.tsv")"
  thumb=$("$GALLERY" list "$WALLPAPERS" 0 | grep 'name.png' | cut -d"$TAB" -f1)
  check_eq "a tabbed filename gets a cached thumbnail" "1" \
    "$([[ -n $thumb && -f $thumb ]] && echo 1 || echo 0)"

  # ------------------------------------------------------------------ prune
  make_sandbox
  make_png "$WALLPAPERS/stays.png"
  make_png "$WALLPAPERS/goes.png"
  "$GALLERY" thumbs "$WALLPAPERS" 0
  check_eq "both images are thumbnailed" "2" "$(count_cache "$CACHE" '*.jpg')"

  rm -f "$WALLPAPERS/goes.png"
  # A new mtime is a new signature, so the row and thumbnail already cached
  # for this image are superseded rather than reused.
  touch -d '2020-01-01' "$WALLPAPERS/stays.png"
  "$GALLERY" thumbs "$WALLPAPERS" 0
  check_eq "prune keeps one index row per surviving image" "1" \
    "$(grep -c . "$CACHE/index.tsv")"
  check_eq "prune drops superseded and orphaned thumbnails" "1" \
    "$(count_cache "$CACHE" '*.jpg')"

  touch "$CACHE/deadbeef.jpg" "$CACHE/deadbeef.jpg.lock"
  "$GALLERY" prune
  check_eq "prune sweeps thumbnails and locks no row points at" "1" \
    "$(count_cache "$CACHE" '*.jpg')"
  check_eq "prune leaves the index itself alone" "1" \
    "$([[ -f $CACHE/index.tsv ]] && echo 1 || echo 0)"
else
  echo "  skip vipsthumbnail not installed, thumbnail tests skipped"
fi

drop_sandbox

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
