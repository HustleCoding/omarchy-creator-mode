#!/bin/bash

# Installs Creator Mode into user-owned locations only:
#   ~/.config/omarchy/plugins/hustlecoding.creator-mode/   (plugin files)
#   ~/.config/hypr/bindings.lua                            (one marked block)
# and enables it through Omarchy's own plugin CLI. Safe to re-run.
#
#   ./install.sh                         bind SUPER + ALT + R
#   CREATOR_MODE_KEY="SUPER + SHIFT + R" ./install.sh
#   CREATOR_MODE_KEY=none ./install.sh   skip the keybinding

set -euo pipefail

ID="hustlecoding.creator-mode"
SRC=$(cd "$(dirname "$0")" && pwd)
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
DEST="$PLUGINS_DIR/$ID"
BINDINGS="$HOME/.config/hypr/bindings.lua"
KEY="${CREATOR_MODE_KEY:-SUPER + ALT + R}"
BEGIN_MARK="-- >>> creator-mode (managed by omarchy-creator-mode; remove with uninstall.sh)"
END_MARK="-- <<< creator-mode"

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

for cmd in omarchy-shell omarchy-plugin-validate omarchy-plugin-enable jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found. Run this on an Omarchy 4 desktop."
done

missing=()
for cmd in gpu-screen-recorder ffprobe flock hyprctl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if ((${#missing[@]} > 0)); then
  say "Warning: missing ${missing[*]}. Creator Mode will show this in its panel until installed."
fi

# ---- plugin files

if [[ -e $DEST && ! -f $DEST/manifest.json ]]; then
  die "$DEST exists but isn't a Creator Mode install; move it away first."
fi
if [[ -f $DEST/manifest.json ]] && [[ $(jq -r '.id // ""' "$DEST/manifest.json") != "$ID" ]]; then
  die "$DEST holds a different plugin; move it away first."
fi

was_installed=false
[[ -d $DEST ]] && was_installed=true

mkdir -p "$PLUGINS_DIR"
stage=$(mktemp -d "$PLUGINS_DIR/.creator-mode.XXXXXX")
trap 'rm -rf "$stage"' EXIT
install -m 644 "$SRC/manifest.json" "$SRC/CreatorMode.qml" "$stage/"
install -d "$stage/bin"
install -m 755 "$SRC/bin/creator-mode-rec" "$stage/bin/"
omarchy-plugin-validate "$stage" >/dev/null || die "plugin failed Omarchy's manifest validation"

rm -rf "$DEST"
mv "$stage" "$DEST"
trap - EXIT
say "Installed plugin files to $DEST"

# ---- enable in the running shell

if omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  enabled=$(omarchy-shell shell listPlugins 2>/dev/null | jq -r --arg id "$ID" '.[] | select(.id == $id) | .enabled' 2>/dev/null || true)
  if [[ $enabled == "true" ]]; then
    say "Plugin already enabled"
    [[ $was_installed == "true" ]] && say "Run omarchy-restart-shell to load the updated version (a running recording keeps going)."
  else
    omarchy-plugin-enable "$ID"
  fi
else
  say "The Omarchy shell isn't running here; after logging in, run: omarchy plugin enable $ID"
fi

# ---- keybinding

bind_line() {
  local key=$1
  printf 'o.bind("%s", "Creator Mode", "omarchy-shell shell summon %s '"'"'{\\"hotkey\\":\\"%s\\"}'"'"'")\n' "$key" "$ID" "$key"
}

strip_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }
  ' "$1"
}

key_taken() {
  local key=$1 pattern
  pattern=$(printf '%s' "$key" | sed 's/[][\.*^$/+?(){}|]/\\&/g; s/ *\\+ */ *\\+ */g')
  local text
  text=$(strip_block "$BINDINGS")
  if [[ -n ${OMARCHY_PATH:-} ]]; then
    text+=$'\n'$(cat "$OMARCHY_PATH"/default/hypr/bindings/*.lua 2>/dev/null || true)
  fi
  grep -v '^[[:space:]]*--' <<<"$text" | grep -Ei "bind\\(\"$pattern\"" >/dev/null
}

if [[ $KEY == "none" ]]; then
  say "Skipping keybinding (CREATOR_MODE_KEY=none)"
elif [[ ! -f $BINDINGS ]]; then
  say "No $BINDINGS found; skipping keybinding. Open the panel with: omarchy-shell shell summon $ID"
elif key_taken "$KEY"; then
  say "'$KEY' is already bound; skipping. Pick another with CREATOR_MODE_KEY=\"SUPER + SHIFT + R\" ./install.sh"
else
  new=$(mktemp)
  strip_block "$BINDINGS" >"$new"
  [[ -z $(tail -c1 "$new") ]] || printf '\n' >>"$new"
  { printf '%s\n' "$BEGIN_MARK"; bind_line "$KEY"; printf '%s\n' "$END_MARK"; } >>"$new"
  if [[ $(sha256sum <"$new") == $(sha256sum <"$BINDINGS") ]]; then
    rm -f "$new"
    say "Keybinding $KEY already present"
  else
    cp -p "$BINDINGS" "$BINDINGS.creator-mode.bak"
    cat "$new" >"$BINDINGS"
    rm -f "$new"
    say "Bound $KEY in $BINDINGS (backup: $BINDINGS.creator-mode.bak)"
    if command -v hyprctl >/dev/null 2>&1; then hyprctl reload >/dev/null 2>&1 || true; fi
  fi
fi

say "Done. Press $KEY (or run: omarchy-shell shell summon $ID) to open Creator Mode."
