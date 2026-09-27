#!/bin/bash

# Reverses install.sh: stops a Creator Mode recording if one is running (the
# file is kept), disables the plugin, removes the marked keybinding block and
# the plugin folder. Recordings in your Videos folder are never touched.

set -euo pipefail

ID="hustlecoding.creator-mode"
DEST="$HOME/.config/omarchy/plugins/$ID"
BINDINGS="$HOME/.config/hypr/bindings.lua"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/creator-mode"
BEGIN_MARK="-- >>> creator-mode (managed by omarchy-creator-mode; remove with uninstall.sh)"
END_MARK="-- <<< creator-mode"

say() { printf '%s\n' "$*"; }

if [[ -x $DEST/bin/creator-mode-rec ]] && command -v jq >/dev/null 2>&1; then
  if [[ $("$DEST/bin/creator-mode-rec" status 2>/dev/null | jq -r '.state // ""') == "recording" ]]; then
    say "Stopping the Creator Mode recording first..."
    "$DEST/bin/creator-mode-rec" stop | jq -r 'if .ok then "Saved \(.file)" else "Warning: \(.message)" end' || true
  fi
fi

if command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell hide "$ID" >/dev/null 2>&1 || true
  enabled=$(omarchy-shell shell listPlugins 2>/dev/null | jq -r --arg id "$ID" '.[] | select(.id == $id) | .enabled' 2>/dev/null || true)
  [[ $enabled == "true" ]] && omarchy-plugin-disable "$ID"
fi

if [[ -f $BINDINGS ]] && grep -qxF -- "$BEGIN_MARK" "$BINDINGS"; then
  new=$(mktemp)
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }
  ' "$BINDINGS" >"$new"
  cat "$new" >"$BINDINGS"
  rm -f "$new"
  say "Removed the Creator Mode keybinding from $BINDINGS"
  if command -v hyprctl >/dev/null 2>&1; then hyprctl reload >/dev/null 2>&1 || true; fi
fi

if [[ -f $DEST/manifest.json ]] && [[ $(jq -r '.id // ""' "$DEST/manifest.json" 2>/dev/null) == "$ID" ]]; then
  rm -rf "$DEST"
  say "Removed $DEST"
  if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
  fi
fi

rm -rf "$STATE_DIR"
say "Creator Mode uninstalled. Your recordings were left in place."
