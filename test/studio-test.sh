#!/bin/bash

# Renders a short synthetic clip through bin/creator-mode-studio with each
# export option and checks the output files (size, format, audio, decodes).

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STUDIO="$ROOT/bin/creator-mode-studio"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/.creator-mode"

pass=0 failed=0
out=""

check() {
  local name=$1
  shift
  if "$@"; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name${out:+: $out}"
    failed=$((failed + 1))
  fi
}

render() { out=$(python3 "$STUDIO" render "$TMP/clip.mp4" --json-progress "$@" 2>/dev/null | tail -1); }
field() { jq -r "$1" <<<"$out"; }
dims() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1"; }
has_audio() { ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$1" | grep -q audio; }
decodes() { ffmpeg -v error -i "$1" -f null - 2>&1 | { ! grep -q .; }; }

ffmpeg -v error -y -f lavfi -i "testsrc2=s=960x540:r=30:d=3" -f lavfi -i "sine=f=440:d=3" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest "$TMP/clip.mp4"
python3 - "$TMP/.creator-mode/clip.events.jsonl" <<'PY'
import json, math, sys
ev = [{"type": "meta", "version": 1, "start": 0, "region": {"x": 0, "y": 0, "w": 640, "h": 360}, "input": "evdev"}]
for i in range(180):
    t = i / 60
    x = 100 + 400 * min(1, t / 0.8) + 1.2 * math.sin(i)  # a fast move, then jitter in place
    ev.append({"t": round(t, 4), "x": x, "y": 120 + 0.8 * math.cos(i)})
ev += [{"t": 1.0, "type": "click", "button": 0}] + [{"t": 1.3 + k * 0.1, "type": "key"} for k in range(6)]
ev.append({"t": 3.0, "type": "end"})
with open(sys.argv[1], "w") as f:
    f.write("\n".join(json.dumps(e) for e in ev) + "\n")
PY

render --encoder x264
check "default render succeeds with a zoom and a cursor" test "$(field '.ok and .zooms == 1 and .cursor')" = true
check "default keeps source size" test "$(dims "$TMP/clip-studio.mp4")" = 960x540
check "default keeps audio" has_audio "$TMP/clip-studio.mp4"
check "default decodes" decodes "$TMP/clip-studio.mp4"
check "typing keeps the click zoom alive" test "$(field '.segments[0].end >= 2.8')" = true

render --encoder x264 --format 9:16 --size 540 --background ocean --inset 6 --shadow 0.8
check "9:16 output is portrait at the requested size" test "$(dims "$TMP/clip-studio-9x16.mp4")" = 540x960
check "9:16 fills the frame and decodes" test "$(field '.layout')" = fill -a -n "$(decodes "$TMP/clip-studio-9x16.mp4" && echo y)"

render --encoder x264 --format 1:1 --layout fit --size 400
check "1:1 fit is square" test "$(dims "$TMP/clip-studio-1x1.mp4")" = 400x400

render --encoder x264 --quality preview
check "preview renders at half size (360p floor)" test "$(dims "$TMP/clip-studio-preview.mp4")" = 640x360

render --export gif --format 1:1 --size 240
check "gif export writes an animated gif" bash -c "[ \"\$(ffprobe -v error -show_entries stream=codec_name,nb_frames -of csv=p=0 '$TMP/clip-studio-1x1.gif')\" \\> gif,10 ]"
check "no partial files are left" bash -c "! ls -A '$TMP' | grep -q part"

mkdir -p "$HOME/.local/state/omarchy/current"
ffmpeg -v error -y -f lavfi -i "testsrc=s=320x180:d=1" -frames:v 1 "$TMP/wall.png"
ln -s "$TMP/wall.png" "$HOME/.local/state/omarchy/current/background"
render --encoder x264 --background wallpaper --out "$TMP/wall.mp4"
check "wallpaper background renders" test "$(field .ok)" = true

rm -f "$HOME/.local/state/omarchy/current/background"
render --background wallpaper --out "$TMP/nowall.mp4"
check "missing wallpaper is a usage error" test "$(field .error)" = usage

render --format 3:7
check "unknown format is a usage error" test "$(field .error)" = usage

CREATOR_MODE_VAAPI_DEVICE=/nonexistent render --encoder vaapi --out "$TMP/v.mp4"
check "forced vaapi without a device fails clearly" test "$(field .error)" = vaapi_unavailable
CREATOR_MODE_VAAPI_DEVICE=/nonexistent render --encoder auto --out "$TMP/auto.mp4"
check "auto encoder falls back to x264" test "$(field .encoder)" = x264

offsets() {
  python3 - "$STUDIO" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("studio", sys.argv[1])
st = importlib.util.module_from_spec(importlib.util.spec_from_loader("studio", loader))
loader.exec_module(st)
meta = {"start": 100.0}
assert abs(st.capture_offset(meta, {"recStart": 101.5}, 12.0, 9.0) - 1.5) < 1e-9
assert st.capture_offset(meta, {}, 12.0, 9.0) == 3.0
assert st.capture_offset(meta, {"recStart": "x"}, 12.0, 9.0) == 3.0
assert abs(st.webcam_lead({"recStart": 101.5, "webcamStart": 101.25}, 20.0, 9.0) - 0.25) < 1e-9
assert st.webcam_lead({}, 10.0, 9.0) == 1.0
PY
}
check "cursor and webcam line up on the recorder's start mark, not the end mark" offsets

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
