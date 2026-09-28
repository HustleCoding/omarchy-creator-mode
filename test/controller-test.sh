#!/bin/bash

# Exercises bin/creator-mode-rec against test/fake-recorder (a stand-in that
# follows gpu-screen-recorder's process contract but captures nothing).
# Proves the controller's state machine, ownership and error handling; it does
# NOT prove real screen capture.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CTL="$ROOT/bin/creator-mode-rec"
TMP=$(mktemp -d)
trap 'pkill -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

export CREATOR_MODE_STATE_DIR="$TMP/state"
export OMARCHY_SCREENRECORD_DIR="$TMP/videos"
export CREATOR_MODE_MONITOR="TEST-1"
export CREATOR_MODE_RECORDER="$ROOT/test/fake-recorder"
export HOME="$TMP/home"
mkdir -p "$HOME"

pass=0 failed=0
out=""

no_fake_running() { ! pgrep -f "^/bin/bash $CREATOR_MODE_RECORDER" >/dev/null; }

run() { out=$("$CTL" "$@" 2>/dev/null); }

expect() {
  local name=$1 filter=$2
  if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    echo "FAIL $name: not JSON: $out"
    failed=$((failed + 1))
  elif jq -e "$filter" >/dev/null <<<"$out"; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name: $out"
    failed=$((failed + 1))
  fi
}

check() {
  local name=$1
  shift
  if "$@"; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    failed=$((failed + 1))
  fi
}

CREATOR_MODE_RECORDER=definitely-not-installed run check
expect "missing recorder is reported with a pacman hint" '.ok == false and .error == "missing_dependency" and (.message | test("sudo pacman -S"))'

run check
expect "check passes and reports the output dir" ".ok and .outputDir == \"$OMARCHY_SCREENRECORD_DIR\""

run status
expect "status is idle before recording" '.ok and .state == "idle"'

run start
expect "start reports recording only once the file exists" '.ok and .state == "recording" and (.pid > 0)'
file=$(jq -r .file <<<"$out")
pid=$(jq -r .pid <<<"$out")
check "output file is under the Omarchy recordings dir" [ -s "$file" ] 
check "recorder is alive" kill -0 "$pid"

run status
expect "status reports the same recording" ".state == \"recording\" and .pid == $pid"

run start
expect "second start is refused (no duplicate recordings)" '.ok == false and .error == "already_recording"'

run stop
expect "stop reports saved with a real duration" '.ok and .state == "saved" and .duration > 0 and .size > 0'
check "recorder has exited" bash -c "! kill -0 $pid 2>/dev/null"
check "file is a readable video" bash -c "ffprobe -v error '$file'"

run stop
expect "stop with nothing running is a clear error" '.ok == false and .error == "not_recording"'

# A recording started outside Creator Mode must be refused and left alone.
bash -c "exec -a gpu-screen-recorder sleep 30" &
foreign=$!
sleep 0.2
run status
expect "status flags a foreign recording" '.foreignRecording == true'
run start
expect "start refuses while a foreign recording runs" '.ok == false and .error == "foreign_recording"'
run stop
check "stop never signals the foreign recorder" kill -0 "$foreign"
kill "$foreign"
wait "$foreign" 2>/dev/null

FAKE_RECORDER_MODE=exit-early run start
expect "recorder crash on start surfaces its error line" '.ok == false and .error == "recorder_failed" and (.message | test("failed to load opengl"))'
run status
expect "failed start leaves no state behind" '.state == "idle"'

FAKE_RECORDER_MODE=never-write CREATOR_MODE_START_TIMEOUT=1 run start
expect "recorder that never writes times out" '.ok == false and .error == "start_timeout"'
check "timed-out recorder was cleaned up" no_fake_running

FAKE_RECORDER_MODE=ignore-int CREATOR_MODE_STOP_TIMEOUT=1 run start
expect "start with stubborn recorder" '.ok'
pid=$(jq -r .pid <<<"$out")
CREATOR_MODE_STOP_TIMEOUT=1 run stop
expect "stop reports save_timeout instead of success" '.ok == false and .error == "save_timeout"'
check "stubborn recorder was force-stopped" bash -c "sleep 0.3; ! kill -0 $pid 2>/dev/null"

run start
pid=$(jq -r .pid <<<"$out")
kill -KILL "$pid"
sleep 0.3
run status
expect "status notices a recorder that died" '.state == "crashed"'
run stop
expect "unreadable leftover file is not reported as saved" '.ok == false and .error == "invalid_output"'

run start
expect "a new recording can start after failures" '.ok and .state == "recording"'
run stop
expect "and saves" '.ok and .state == "saved"'

# Picker: the same omarchy-capture-region contract, faked.
cat >"$TMP/picker" <<'PICK'
#!/bin/bash
[[ $* == "smart --match-monitor" ]] || exit 2
[[ -n $FAKE_PICK ]] || exit 1
echo "$FAKE_PICK"
PICK
chmod +x "$TMP/picker"
export CREATOR_MODE_PICKER="$TMP/picker"

FAKE_PICK="10,-20 640x480" run pick
expect "pick maps a region to gpu-screen-recorder geometry" '.ok and .target == "region:640x480+10+-20"'
FAKE_PICK="monitor:DP-2" run pick
expect "pick keeps a whole-monitor selection as a monitor" '.ok and .target == "monitor:DP-2"'
FAKE_PICK="" run pick
expect "cancelled pick is reported as cancelled" '.ok == false and .error == "cancelled"'
CREATOR_MODE_PICKER=definitely-not-installed run pick
expect "missing picker is reported" '.ok == false and .error == "missing_dependency"'

run start --target='region:1x1+0+0;rm -rf ~'
expect "malformed target is rejected" '.ok == false and .error == "usage"'

export FAKE_RECORDER_ARGS="$TMP/args"
run start --target=region:640x480+10+-20
expect "region start records" '.ok and .state == "recording"'
check "region is passed to the recorder as -w WxH+X+Y" bash -c "grep -qxF -- '640x480+10+-20' '$TMP/args' && ! grep -qxF -- -s '$TMP/args'"
run stop
expect "region recording saves" '.ok and .state == "saved"'

CREATOR_MODE_RESOLUTION=0x0 run start --target=monitor:DP-2
check "picked monitor is passed to the recorder" grep -qxF -- 'DP-2' "$TMP/args"
run stop
unset FAKE_RECORDER_ARGS

# Studio: cursor tracking alongside the recording, then the polished render.
"$ROOT/test/fake-hypr-socket" "$TMP/hypr.sock" &
sleep 0.3
export CREATOR_MODE_HYPR_SOCKET="$TMP/hypr.sock" CREATOR_MODE_REGION="0,0,320,240" FAKE_RECORDER_ARGS="$TMP/args"

run start --studio=maybe
expect "unknown studio mode is rejected" '.ok == false and .error == "usage"'

run start --studio=on
expect "studio start tracks the cursor" '.ok and .state == "recording" and .studio == true'
check "real cursor is hidden while the tracker redraws it" bash -c "grep -qxF -- -cursor '$TMP/args' && grep -qxF -- no '$TMP/args'"
sleep 0.5
run stop
expect "studio stop reports the events file" '.ok and .state == "saved" and (.events | type) == "string"'
file=$(jq -r .file <<<"$out")
events=$(jq -r .events <<<"$out")
check "events file has a header, cursor samples and an end mark" bash -c "
  head -n1 '$events' | jq -e '.type == \"meta\" and .region.w == 320' >/dev/null &&
  grep -q '\"x\":' '$events' && tail -n1 '$events' | jq -e '.type == \"end\"' >/dev/null"
check "events file logs the visible windows (class only) for the cursor shape" bash -c "
  grep '\"type\":\"windows\"' '$events' | head -n1 | jq -e '.w == [[10,10,300,220,\"Alacritty\"]]' >/dev/null"
check "tracker has exited" bash -c "! pgrep -f -- '[-]-out $events' >/dev/null"

out=$("$CTL" render "$file" --background=ocean 2>/dev/null | tail -n1)
expect "render produces the studio cut next to the recording" '.ok and (.file | endswith("-studio.mp4")) and .cursor == true'
check "studio cut is a readable video" bash -c "ffprobe -v error '$(jq -r .file <<<"$out")'"
check "raw recording is left in place" [ -s "$file" ]

rm -f "${file%.mp4}-studio.mp4"
"$CTL" render "$file" >"$TMP/render.out" 2>/dev/null &
rpid=$!
for _ in $(seq 100); do grep -q progress "$TMP/render.out" && break; sleep 0.05; done
kill -TERM "$rpid"; wait "$rpid" 2>/dev/null
check "cancelled render stops ffmpeg" bash -c "sleep 0.3; ! pgrep -f -- '[-]studio.mp4.part.mp4' >/dev/null"
check "cancelled render leaves no partial file" bash -c "! ls -A '$(dirname "$file")' | grep -q part.mp4"

run render "$TMP/nope.mp4"
expect "render of a missing file is a clear error" '.ok == false and .error == "not_found"'

# Studio + desktop+mic keeps desktop and mic on their own tracks; webcam via ffmpeg.
export CREATOR_MODE_WEBCAM_FORMAT=lavfi CREATOR_MODE_WEBCAM_DEVICE="testsrc2=s=160x120:r=15"
run check
expect "check reports a usable webcam" '.ok and .webcam == true'
run start --webcam=maybe
expect "unknown webcam mode is rejected" '.ok == false and .error == "usage"'
run start --studio=on --audio=desktop+mic --webcam=on
expect "studio start with webcam reports it" '.ok and .studio == true and .webcam == true'
file=$(jq -r .file <<<"$out")
session="$(dirname "$file")/.creator-mode/$(basename "${file%.mp4}").session.json"
check "desktop and mic get separate tracks after the mix" bash -c "[ \"\$(grep -cx -- -a '$TMP/args')\" = 3 ] && grep -qxF -- 'default_output|default_input' '$TMP/args' && grep -qxF -- default_input '$TMP/args'"
check "session file lists the tracks and the webcam" bash -c "jq -e '.audio == [\"mix\",\"system\",\"mic\"] and (.webcam | endswith(\".webcam.mkv\"))' '$session' >/dev/null"
check "session file records when the recorder and webcam started" bash -c "jq -e '(.recStart | type) == \"number\" and (.webcamStart | type) == \"number\" and .recStart >= .webcamStart' '$session' >/dev/null"
wpid=$(sed -n 's/^webcam_pid=//p' "$CREATOR_MODE_STATE_DIR/state")
sleep 1
run stop
expect "stop reports the webcam file" '.ok and .state == "saved" and (.webcam | type) == "string"'
webcam=$(jq -r .webcam <<<"$out")
check "webcam recorder has exited" bash -c "[ -n '$wpid' ] && ! kill -0 '$wpid' 2>/dev/null"
check "webcam file is a readable video" bash -c "ffprobe -v error -show_entries format=duration -of csv=p=0 '$webcam' | grep -q '[1-9]'"

CREATOR_MODE_EDITOR_NO_OPEN=1 run edit "$file"
expect "edit starts the timeline editor on localhost" '.ok and (.url | test("^http://127[.]0[.]0[.]1:[0-9]+/"))'
url=$(jq -r .url <<<"$out")
check "editor serves the page" bash -c "curl -sf '$url' | grep -q 'Timeline'"
curl -s -X POST -d '{}' "${url}quit" >/dev/null
run edit "$TMP/nope.mp4"
expect "edit of a missing file is a clear error" '.ok == false and .error == "not_found"'

run start --webcam=on
expect "webcam without studio records without it and says why" '.ok and .webcam == false and (.notice | test("needs Studio"))'
run stop
CREATOR_MODE_WEBCAM_FORMAT=v4l2 CREATOR_MODE_WEBCAM_DEVICE="$TMP/no-video0" run start --studio=on --webcam=on
expect "missing camera is a notice, not a failure" '.ok and .webcam == false and (.notice | test("No webcam found"))'
run stop
unset CREATOR_MODE_WEBCAM_FORMAT CREATOR_MODE_WEBCAM_DEVICE

CREATOR_MODE_HYPR_SOCKET="$TMP/missing.sock" run start --studio=on
expect "tracker failure degrades to a plain recording" '.ok and .studio == false and (.notice | test("Cursor tracking failed"))'
check "real cursor stays visible without the tracker" bash -c "! grep -qxF -- -cursor '$TMP/args'"
run stop
expect "and still saves" '.ok and .state == "saved" and .events == null'
unset FAKE_RECORDER_ARGS CREATOR_MODE_HYPR_SOCKET CREATOR_MODE_REGION

echo
echo "$pass passed, $failed failed"
((failed == 0))
