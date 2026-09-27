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

echo
echo "$pass passed, $failed failed"
((failed == 0))
