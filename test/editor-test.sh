#!/bin/bash

# Timeline edits, webcam bubble and split audio through bin/creator-mode-studio,
# plus the HTTP API of bin/creator-mode-editor, on a synthetic clip.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STUDIO="$ROOT/bin/creator-mode-studio"
EDITOR="$ROOT/bin/creator-mode-editor"
TMP=$(mktemp -d)
editor_pid=""
cleanup() {
  [[ -n $editor_pid ]] && kill "$editor_pid" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home"
M="$TMP/.creator-mode"
mkdir -p "$HOME" "$M"

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

render() { out=$(python3 "$STUDIO" render "$TMP/clip.mp4" --encoder x264 --quality preview --json-progress "$@" 2>/dev/null | tail -1); }
plan() { out=$(python3 "$STUDIO" plan "$TMP/clip.mp4" 2>/dev/null); }
field() { jq -r "$1" <<<"$out"; }
vdur() { ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 "$1"; }
near() { awk -v a="$1" -v b="$2" -v e="${3:-0.15}" 'BEGIN { d = a - b; exit !(d < e && d > -e) }'; }
atracks() { ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | wc -l; }
edits() { printf '%s' "$1" >"$M/clip.edit.json"; }

# 6 s clip with three audio tracks (mix, system, mic) like a studio desktop+mic capture.
ffmpeg -v error -y -f lavfi -i "testsrc2=s=640x360:r=30:d=6" -f lavfi -i "sine=f=440:d=6" \
  -f lavfi -i "sine=f=660:d=6" -f lavfi -i "sine=f=880:d=6" -map 0 -map 1 -map 2 -map 3 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest "$TMP/clip.mp4"
python3 - "$M/clip.events.jsonl" <<'PY'
import json, sys
ev = [{"type": "meta", "version": 1, "start": 0, "region": {"x": 0, "y": 0, "w": 640, "h": 360}, "input": "evdev"}]
ev += [{"t": i / 60, "x": 100 + i, "y": 150} for i in range(360)]
ev += [{"t": 1.0, "type": "click", "button": 0}, {"t": 4.0, "type": "click", "button": 0}, {"t": 6.0, "type": "end"}]
with open(sys.argv[1], "w") as f:
    f.write("\n".join(json.dumps(e) for e in ev) + "\n")
PY

plan
check "plan without edits: full length, auto zooms" test "$(field '.ok and .outputDuration == 6 and (.autoSegments | length) >= 1 and .edits.zooms == null')" = true
check "plan reports a single mixed track without a session file" test "$(field '.audioTracks == ["mix"] and .webcam == false')" = true

edits '{"trim":[0.5,5.5],"cuts":[[2,3]],"speed":[{"start":3.5,"end":5,"rate":3}]}'
plan
check "trim + cut + 3x speed-up gives 3 s" near "$(field .outputDuration)" 3.0 0.01
render
check "edited render is 3 s long" near "$(vdur "$TMP/clip-studio-preview.mp4")" 3.0
check "edited render keeps audio in sync length" near "$(ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 "$TMP/clip-studio-preview.mp4")" 3.0

render --no-edits --out "$TMP/noedits.mp4"
check "--no-edits renders the full length" near "$(vdur "$TMP/noedits.mp4")" 6.0

edits '{"zooms":[]}'
render
check "empty zoom list removes every zoom" test "$(field '.zooms')" = 0
edits '{"zooms":[{"start":2,"end":3,"zoom":2.5,"x":0.2,"y":0.3,"follow":false}]}'
render
check "custom zoom replaces the auto zooms" test "$(field '.zooms == 1 and .segments[0].zoom == 2.5 and .segments[0].follow == false')" = true

edits '{"trim":[9,-4],"cuts":[["a",1]],"speed":[{"start":0,"end":1,"rate":999}],"zooms":[{"start":1,"end":2,"zoom":99,"x":7}],"webcam":{"corner":"middle"}}'
plan
check "bad edit values are clamped or dropped" test "$(field '.edits.trim == [0,6] and .edits.cuts == [] and .edits.speed[0].rate == 8 and .edits.zooms[0].zoom == 4 and .edits.zooms[0].x == 1 and .edits.webcam.corner == "br"')" = true

edits '{"cuts":[[0,6]]}'
render --out "$TMP/empty.mp4"
check "cutting everything is a usage error" test "$(field .error)" = usage

# Webcam + separate desktop/mic tracks.
ffmpeg -v error -y -f lavfi -i "smptebars=s=320x240:r=30:d=6.4" -c:v libx264 -preset ultrafast "$M/clip.webcam.mkv"
printf '{"audio":["mix","system","mic"],"webcam":"clip.webcam.mkv"}\n' >"$M/clip.session.json"
edits '{"audio":{"system":0.4,"mic":1.5,"denoise":true},"webcam":{"corner":"tl","size":0.3}}'
plan
check "session file exposes webcam and split tracks" test "$(field '.webcam and .audioTracks == ["mix","system","mic"]')" = true
render
check "webcam + audio mix render succeeds" test "$(field '.ok and .webcam and .audioMix')" = true
check "mixed output has one audio track" test "$(atracks "$TMP/clip-studio-preview.mp4")" = 1
cp "$TMP/clip-studio-preview.mp4" "$TMP/cam.mp4"
edits '{"webcam":{"enabled":false}}'
render
check "webcam can be turned off in the edits" test "$(field '.ok and (.webcam | not)')" = true
corner_psnr() {
  ffmpeg -v info -ss 1 -i "$TMP/cam.mp4" -ss 1 -i "$TMP/clip-studio-preview.mp4" -frames:v 1 \
    -lavfi "[0:v]crop=$1[a];[1:v]crop=$1[b];[a][b]psnr" -f null - 2>&1 | sed -n 's/.*average:\([0-9.inf]*\).*/\1/p' | cut -d. -f1
}
tl=$(corner_psnr 60:60:40:40) br=$(corner_psnr 60:60:540:260)
out="top-left psnr $tl, bottom-right psnr $br"
check "webcam bubble is drawn in the chosen corner only" bash -c "[ '$tl' -lt 25 ] && [ '$br' = inf -o '${br:-0}' -gt 40 ] 2>/dev/null"
out=""
check "no partial files are left" bash -c "! ls -A '$TMP' | grep -q part"

# Editor HTTP API.
rm -f "$M/clip.edit.json"
python3 "$EDITOR" "$TMP/clip.mp4" --no-open >"$TMP/editor.out" 2>&1 &
editor_pid=$!
for _ in $(seq 100); do [[ -s $TMP/editor.out ]] && break; sleep 0.1; done
url=$(jq -r .url "$TMP/editor.out" 2>/dev/null)
check "editor prints a tokenized localhost URL" bash -c "[[ '$url' =~ ^http://127\.0\.0\.1:[0-9]+/[A-Za-z0-9_-]{20,}/$ ]]"
origin=${url%/*/}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "page is served" test "$(code "$url")" = 200
check "wrong token is refused" test "$(code "$origin/nope/state")" = 404
check "video supports range requests" test "$(code -H 'Range: bytes=0-99' "${url}video")" = 206
check "filmstrip exists" test "$(code "${url}thumbs.jpg")" = 200
out=$(curl -s "${url}state")
check "state returns the plan" test "$(field '.ok and .duration == 6')" = true
out=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"trim":[1,5]}' "${url}edits")
check "saving edits returns the clamped plan" test "$(field '.ok and .outputDuration == 4')" = true
check "edits are written next to the recording" test "$(jq -c .trim "$M/clip.edit.json")" = "[1,5]"
check "cross-origin posts are refused" test "$(code -X POST -H 'Origin: http://evil.example' -d '{}' "${url}edits")" = 403
check "render with a bad background falls back safely" test "$(code -X POST -d '{"quality":"preview","background":"x;rm -rf /"}' "${url}render")" = 200
for _ in $(seq 120); do
  out=$(curl -s "${url}progress")
  [[ $(field .running) == false ]] && break
  sleep 0.5
done
check "editor render finishes with the edited length" test "$(field '.result.ok and .result.duration == 4')" = true
check "rendered output is served" test "$(code "${url}output")" = 200
curl -s -X POST -d '{}' "${url}quit" >/dev/null
for _ in $(seq 100); do kill -0 "$editor_pid" 2>/dev/null || break; sleep 0.1; done
check "quit stops the editor" bash -c "! kill -0 $editor_pid 2>/dev/null"
editor_pid=""

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
