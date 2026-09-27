# Creator Mode for Omarchy

A keyboard-driven screen-recording panel for **Omarchy 4.0.4**: press a key, see a clean
**3 · 2 · 1** countdown, record the focused monitor (or an area, window or monitor picked with Omarchy's own picker) with a live timer, then get the saved
file path and an **Open folder** action. It is a native Omarchy shell plugin, it follows
the active theme, and it installs only into your home directory.

```
SUPER + ALT + R   → panel (idle)
Enter             → 3 · 2 · 1 → REC ● 00:12   (top-center pill, not captured as a modal)
SUPER + ALT + R   → Saving… → Rendering studio cut 42% → "Studio cut saved" · path · O Open folder
```

## Studio mode (Screen Studio-style cut)

Studio is on by default (`S` toggles it, `B` cycles the background, `F` cycles the format). While recording, `bin/creator-mode-track`
logs the cursor from Hyprland's IPC socket (~60 Hz) and, if `/dev/input/event*` is readable, mouse clicks and
the *fact* that a key was pressed (never which key). The real cursor is hidden in the capture
(`gpu-screen-recorder -cursor no`, only when the installed recorder supports it and the tracker is running).
After you stop, `bin/creator-mode-studio` renders `<name>-studio.mp4` next to the raw file:

- **Auto-zoom** (1.8×) eased in just before each click, held while you click or type nearby. A typing burst
  outside a zoom zooms in on the last click (the field you're typing into). Zooming and panning are one
  eased move; the camera pans only once the cursor leaves a dead zone, so small moves don't shake it.
- **Smooth cursor** redrawn from the log: jitter is filtered out, then spring-smoothed (`--smoothing 0..1`).
  It's an anti-aliased arrow with a soft shadow, squishes on click with an expanding **click ring**, and
  fades out after 2.5 s idle (`--hide-idle N`, `0` never).
- **Motion blur** on fast cursor moves and fast camera moves (`--no-motion-blur` to turn it off).
- **Framing:** padding, rounded corners, soft drop shadow (`--shadow 0..1`), optional inset border
  (`--inset PX --inset-color #rrggbb`) and a background: the Omarchy theme gradient (default), `wallpaper`
  (your current Omarchy wallpaper, blurred; `--blur N`), presets `midnight sunset ocean aurora candy peach
  dusk lime forest slate mono`, `#rrggbb[:#rrggbb]`, or an image path.
- **Formats:** `--format source|16:9|9:16|1:1|4:5`, `--size` (short side in px). When the aspect changes a lot
  (e.g. landscape screen → 9:16) the recording is cropped to the format and the crop follows the cursor
  (`--layout fill`); `--layout fit` keeps the whole screen on the background instead.
- **Exports:** MP4 (default) or `--export gif` (palette-optimized, ≤720 px, `--gif-fps 15`).
- **Speed:** `--quality preview` renders at half size, 30 fps, without motion blur (~8× faster).
  `--encoder auto` (default) uses VAAPI (`h264_vaapi`) when a test encode on `/dev/dri/renderD*` works,
  otherwise libx264; `--encoder vaapi|x264` forces one.
- Audio is copied untouched (not in GIFs) unless you change levels or edit the timeline. The raw recording
  is never modified; a failed or skipped render (`Esc`) still leaves it saved.

### Timeline editor

`E` on the saved screen (or `creator-mode-rec edit <file>`) opens a local editor in your browser
(`bin/creator-mode-editor`, served on `127.0.0.1` behind a random token, standard library only). It shows
the raw recording with a filmstrip and three tracks:

- **Trim** with the filmstrip handles or `I`/`O` at the playhead.
- **Cut** (`X`) or **speed up** (`S`, 1.5–8×, or 0.5× slow-mo) a range you drag across the filmstrip.
- **Zooms:** the automatic zooms are shown dashed. Drag to move, drag the edges to resize, change the level,
  click the video to choose where it zooms, turn cursor-follow on/off, `Del` to remove, `Z` to add one.
  *Auto zooms* goes back to the automatic ones and *No zooms* removes them all.
- **Audio:** desktop and mic levels (separate when recorded with Studio + desktop+mic) and noise reduction.
- **Webcam:** show/hide the bubble, corner, size, mirror.
- Background, format and GIF/MP4 export, then *Quick preview* or *Render*; the result plays in the page.

Playback in the editor skips cuts, plays sped-up ranges faster and previews the zooms. Edits are saved as
you go to `.creator-mode/<name>.edit.json`; every later render (including `creator-mode-studio render`)
applies them. `--no-edits` ignores the file and `creator-mode-studio plan <file>` prints the zoom plan and
the edits as JSON.

### Webcam and audio

With Studio on, `W` in the panel turns on the **webcam bubble**. `ffmpeg` records `/dev/video0` next to
the screen (`.creator-mode/<name>.webcam.mkv`) and the render puts it in a round, bordered bubble in a
corner (bottom right, 24% of the short side by default). Set `CREATOR_MODE_WEBCAM_DEVICE` to use
another camera. With Studio on and `desktop+mic` audio, the recording gets three tracks: the usual mix
(what players play), desktop only and mic only. That way the studio render and the editor can set
`--system-volume`, `--mic-volume` and `--denoise` separately.

Without access to `/dev/input` (you're not in the `input` group), clicks can't be seen and zooms follow
where the cursor comes to rest instead. For click-accurate zooms: `sudo usermod -aG input $USER` and log in
again. If the tracker can't start at all, Creator Mode records a normal video with the real cursor.

Re-render any recording with other settings (output names get `-9x16`, `-preview`, `.gif` suffixes):

```bash
S=~/.config/omarchy/plugins/hustlecoding.creator-mode/bin/creator-mode-studio
$S render ~/Videos/creator-mode-….mp4 --background wallpaper --zoom 2.2 --inset 8
$S render ~/Videos/creator-mode-….mp4 --format 9:16 --quality preview     # quick check for a Short/Reel
$S render ~/Videos/creator-mode-….mp4 --format 1:1 --export gif --size 600
```

Events are kept in `<recordings dir>/.creator-mode/<name>.events.jsonl` (cursor positions, click and keypress
times only).

## Compatibility findings (Omarchy 4.0.4)

These come from the Omarchy source at git tag `v4.0.4`, not from the latest online manual.
The repo's `version` file at that tag still reads `4.0.0.alpha`, so rely on the tag, not that file.

| Question | Finding in 4.0.4 | Consequence |
| --- | --- | --- |
| Native shell plugins? | **Yes.** Third-party plugins live in `~/.config/omarchy/plugins/<id>/` with a `manifest.json` (`schemaVersion: 1`). Kinds: `bar-widget`, `bar`, `panel`, `overlay`, `menu`, `service`. | Built as an `overlay` plugin; no standalone-panel fallback needed. |
| Lifecycle | Overlay entry points are QML `Item`s that get `shell`, `manifest`, `omarchyPath` injected and expose `open(payloadJson)` / `close()`. `omarchy-shell shell summon <id> [json]` loads the plugin and calls `open`. | The keybinding calls `summon`; the same key opens, stops, or cancels depending on state. |
| Enable / validate | `omarchy-plugin-validate <dir>` (rejects symlinks and unsafe paths), `omarchy-plugin-enable <id>` / `omarchy-plugin-disable <id>` (persisted in `~/.config/omarchy/shell.json`). | The installer only uses these CLIs and never edits `shell.json` directly. |
| Theme | Plugins can `import qs.Commons` (`Color`, `Style`, `Border`) and `qs.Ui` (`BorderSurface`). | All colors, fonts, radius, and borders come from the active theme. The red REC dot uses `Color.urgent`. |
| Recording tool | `omarchy-capture-screenrecording` wraps **gpu-screen-recorder**. It saves to `$OMARCHY_SCREENRECORD_DIR` → `XDG_VIDEOS_DIR` → `~/Videos` and stops with SIGINT. | Same recorder, the same core flags (`-k auto -f 60 -fm cfr -fallback-cpu-encoding yes`, 4K cap), and the same output directory. |
| Why not call that script directly? | Its stop path is `pkill -SIGINT -f "^gpu-screen-recorder"`, which kills **every** recording. It also exposes no status or PID, and its default mode opens a region picker. | A small controller (`bin/creator-mode-rec`) starts the recorder itself and signals only its own PID. |
| Keybindings | 4.0 uses Lua: `o.bind("KEYS", "Description", "command")` in `~/.config/hypr/bindings.lua`, loaded after the defaults. Omarchy binds `ALT + PRINT` to recording. `SUPER + ALT + R` is unused by the defaults. | The installer adds one marked block. It refuses to install if the key is already bound. |

## Architecture

```
Hyprland key ──► omarchy-shell shell summon hustlecoding.creator-mode '{"hotkey":…}'
                        │
                        ▼
  CreatorMode.qml (overlay plugin, keepLoaded, runs inside Omarchy's Quickshell)
    phases: idle → [picking →] countdown → starting → recording → saving → saved | error
    • centered card: layer-shell Overlay, exclusive keyboard focus (panel states)
    • top-center REC pill (below the bar): no keyboard focus, so you can keep working while recording
    • every action = one Process call, one JSON reply
                        │  bash bin/creator-mode-rec <cmd>
                        ▼
  bin/creator-mode-rec (controller)
    check  → deps, output dir, foreign recorder?     status → idle | recording | crashed
    pick   → omarchy-capture-region smart --match-monitor (Omarchy's picker, same as ALT + PRINT);
             whole monitor → monitor:NAME, anything else → region:WxH+X+Y
    start  → flock; refuse if ours or a foreign gpu-screen-recorder is running;
             setsid gpu-screen-recorder -w <monitor | WxH+X+Y> … -o <file>;
             reply "recording" only after the process is alive AND the file is non-empty
    stop   → verify /proc/<pid>/cmdline still contains <file>; SIGINT that PID only;
             wait for exit; reply "saved" only if ffprobe reads a duration
    reveal → xdg-open / nautilus --select on the folder
    state  → $XDG_RUNTIME_DIR/creator-mode/{state,lock,recorder.log}
```

Guarantees:

- **No duplicate recordings.** An `flock` serializes controller commands, and the state file tracks our one recording. `start` refuses while our recorder or any other `gpu-screen-recorder` (for example Omarchy's `ALT + PRINT`) is running.
- **Only our process is ever stopped.** No `pkill`: the tracked PID is signalled only after `/proc/<pid>/cmdline` confirms it is still writing our output file. A foreign recording is never touched; the panel explains how to stop it.
- **"Recording" is honest.** The pill appears only after the controller confirms the recorder is alive and writing. If the recorder dies at startup, you see its last error line instead.
- **"Saved" is honest.** The saved state appears only after the recorder exits and `ffprobe` can read the file. If the recorder crashed but left a readable file, it is shown as *recovered*. An unreadable file is reported as an error, with its path.
- **State survives shell restarts.** Recording state lives in the controller's state file, not in QML. After `omarchy-restart-shell`, re-opening the panel finds and can stop the running recording.

Keys:

| State | Keys |
| --- | --- |
| idle | `Enter`/`Space`/`R` full screen · `P` pick area/window/monitor, then countdown · `A` cycle audio (none → desktop → desktop+mic) · `S` studio on/off · `B` cycle background · `F` cycle format (source → 16:9 → 9:16 → 1:1 → 4:5) · `W` webcam bubble (studio on, camera found) · `Esc`/`Q` close |
| picking | Omarchy's picker keys: drag an area, click a window, `Enter` highlighted window, `Ctrl + Enter` whole monitor, `Esc` cancels back to idle |
| countdown | `Esc` or the hotkey cancels |
| recording | hotkey (`SUPER + ALT + R`) stops |
| rendering | `Esc` skips the studio cut (raw recording stays saved) |
| saved | `O` open folder · `E` edit timeline · `Enter` new recording · `Esc` done |
| error | `Enter` retry · `Esc` close |

## Dependencies

Everything below ships with a standard Omarchy 4.0.4 install:
`gpu-screen-recorder`, `ffmpeg` (`ffprobe`, and the studio render), `python` (studio tracker/renderer, standard library only), `util-linux` (for `flock`), `hyprland` (for `hyprctl`), `jq`, `xdg-utils`, plus Omarchy's `omarchy-shell` / `omarchy-plugin-*`.
If one is missing, the panel names it and shows the install command (`sudo pacman -S …`). The installer warns too.

No network, paid services, or AI APIs are used.

## Install / run / uninstall

```bash
git clone https://github.com/HustleCoding/omarchy-creator-mode.git
cd omarchy-creator-mode
./install.sh                                   # binds SUPER + ALT + R
# or: CREATOR_MODE_KEY="SUPER + SHIFT + R" ./install.sh
# or: CREATOR_MODE_KEY=none ./install.sh       # no keybinding
```

Run it:

```bash
# press SUPER + ALT + R, or:
omarchy-shell shell summon hustlecoding.creator-mode
```

Recordings are saved as `creator-mode-YYYY-MM-DD_HH-MM-SS.mp4` in the same folder Omarchy uses (`$OMARCHY_SCREENRECORD_DIR`, then `XDG_VIDEOS_DIR`, then `~/Videos`).

Re-running `./install.sh` updates the files in place and never duplicates the binding. After an update, run `omarchy-restart-shell` to load the new QML. A running recording keeps going through the restart.

```bash
./uninstall.sh
```

The uninstaller stops a Creator Mode recording only if one is active, disables the plugin, removes only the marked binding block and the plugin directory, and clears runtime state. **Your recordings are never deleted.**

What the installer touches:

| Location | Change |
| --- | --- |
| `~/.config/omarchy/plugins/hustlecoding.creator-mode/` | plugin files (refuses to overwrite a different plugin at that path) |
| `~/.config/omarchy/shell.json` | only via `omarchy-plugin-enable` |
| `~/.config/hypr/bindings.lua` | one block between `-- >>> creator-mode` and `-- <<< creator-mode` |
| Omarchy package files (`$OMARCHY_PATH`) | **nothing** |

## What was tested, and where

My cloud VM has no GPU and no Hyprland. Testing ran in an Arch Linux container with the real Omarchy `v4.0.4` source, real Quickshell, and Sway in headless mode (pixman renderer).

| Area | How | Result |
| --- | --- | --- |
| Shell lint / security | `bash -n`, `shellcheck -x` on all scripts, Semgrep (`p/secrets`, `p/command-injection`, `r/bash`) | clean |
| Controller logic | `test/controller-test.sh` with `test/fake-recorder` (dependency errors, start, duplicate start, stop + ffprobe, foreign recorder left alive, crash at startup, start timeout, SIGINT ignored, dead recorder, corrupt output) | 26/26 pass. **Fake recorder: this proves the logic, not real capture.** |
| Real `gpu-screen-recorder` | Controller started the real binary on the headless output | Only the **failure path** could run: it exits with an OpenGL/llvmpipe error, and the panel shows that error instead of "recording". |
| Real capture, success path | `test/stand-in-recorder` runs **wf-recorder** (real Wayland screen capture) behind the same process contract | Real MP4 saved; `ffprobe` read the duration (e.g. 4.5 s). The panel went countdown → REC pill → Saving… → Saved with the correct path and size. |
| Plugin integration | `omarchy-plugin-validate`, `omarchy-plugin-enable`, `omarchy-shell shell rescanPlugins/listPlugins/summon` against Omarchy's real shell | Plugin loads, validates, and summons. All states render with the Omarchy theme. |
| Installer | Fresh install, re-install (1 block, no dupes), Lua parse of `bindings.lua`, user and default key collisions refused, uninstall ×2, `shell.json` otherwise unchanged | pass |
| Keyboard focus | `wtype` into headless Sway | Keys reach the panel on first open. After the card is hidden and re-shown, headless Sway stops delivering keys to the new surface. **Omarchy's own menu shows the same behavior in this rig** (Esc stops working after re-open), so I treat it as a test-environment limitation. `O` / Open folder was verified directly through the controller (`reveal` opens Nautilus with the file selected). |

### Official Omarchy 4.0.4 VM (real Hyprland)

A second pass ran on the official `omarchy-4.0.4.iso` installed in a QEMU/KVM VM (`omarchy 4.0.4-1`, Hyprland 0.56.2, Quickshell 0.3.1, gpu-screen-recorder 6.1.0). Keys were sent as virtual keyboard input through QEMU's monitor (QMP), so Hyprland handled the global bindings like a physical keyboard. The VM has a virtio GPU and no AMD/Intel/NVIDIA hardware.

| Area | Result |
| --- | --- |
| `./install.sh` on a stock install | Validated, enabled, and bound `SUPER + ALT + R`. Re-running it added no second block. |
| `SUPER + ALT + R` hotkey | Opens the panel. Pressing it while recording stops the recording. |
| Keyboard focus across re-opens | Works: open, Esc, re-open, Esc, re-open, Enter all worked. The headless-Sway problem does not happen on Hyprland. |
| Countdown + Esc cancel | 3 → 2 → 1 shown; Esc returns to idle with "Countdown cancelled". |
| Monitor detection | `hyprctl monitors -j` found `Virtual-1` without an override. |
| Real `gpu-screen-recorder` | **Failure path only.** With the plain virtio GPU it fails with `llvmpipe ... failed to load opengl`. With virgl it fails with `unknown gpu vendor: Mesa`. gpu-screen-recorder supports only AMD/Intel/NVIDIA GPUs. Both errors appear on the error card, and REC is never shown. |
| Success path (wf-recorder stand-in, real Hyprland capture) | countdown → REC pill with a live timer → Saving… → Saved. The file was 1920x1080 and `ffprobe` read 11.7 s. `O` opened Nautilus on `~/Videos`. |
| Pick area (`P`) | Omarchy's picker (slurp + frozen screen) opened with the panel hidden. `Esc` returned to idle with "Selection cancelled". A dragged 801×501 area → countdown "Area 801×501" → REC → Saved; wf-recorder got `-g 399,299 801x501` and `ffprobe` read an 800×500, 7.4 s file (the stand-in's x264 rounds to even sizes). `Enter` over a window → "Area 1896×1030" (the window). `Ctrl + Enter` → "Monitor Virtual-1". |
| Foreign recorder guard | With an outside `gpu-screen-recorder` process running, start was refused and the outside process was left running. |
| `./uninstall.sh` | Removed the binding block, the plugin dir, and the `shell.json` entry. The recordings were kept. |

The VM showed that the REC pill in the top-right corner overlapped the bar and Omarchy's notification toasts. The pill now sits top-center, below the bar.

**Still needs your machine (real GPU):**

1. The real `gpu-screen-recorder` success path: file quality, encoder choice, audio (desktop / mic).
2. The REC pill's readability on your monitor and theme, including HiDPI.

## Local test checklist

Run on the Omarchy desktop after `./install.sh`.

- [ ] **Open:** `SUPER + ALT + R` shows the themed card: "Ready to record", "Full screen, or pick an area, window or monitor · No audio", key hints.
- [ ] **Pick area:** `SUPER + ALT + R` → `P`. The card hides and Omarchy's picker appears. `Esc` returns to the card with "Selection cancelled". `P` again, drag an area: the countdown shows "Area W×H", and the saved video shows only that area.
- [ ] **Countdown cancel:** `Enter`, then `Esc` during the countdown. The card returns to idle with "Countdown cancelled". No file is created, and `pgrep -a gpu-screen-recorder` prints nothing.
- [ ] **Start:** `Enter` shows 3 → 2 → 1, the card disappears, and the top-center **● REC 00:00** pill counts up. `pgrep -a gpu-screen-recorder` shows one process.
- [ ] **Duplicate guard:** press `ALT + PRINT` (Omarchy's recorder) while Creator Mode is idle, then `SUPER + ALT + R` → `Enter`. You get the "Another recording is running" error, and the other recording keeps running. Stop it with `ALT + PRINT`.
- [ ] **Stop:** while recording, press `SUPER + ALT + R`. The pill shows **Saving…**, then the card shows "Recording saved" with duration, size, and the full path.
- [ ] **Saved output:** `ffprobe <path>` reports a duration close to the timer; the file plays in your video player.
- [ ] **Open folder:** `O` opens the file manager with the file selected.
- [ ] **Missing dependency (controller):** `CREATOR_MODE_RECORDER=nope ~/.config/omarchy/plugins/hustlecoding.creator-mode/bin/creator-mode-rec check` prints `"ok":false` with `Missing: nope. Install with: sudo pacman -S nope`. That same message is what the panel shows.
- [ ] **Recorder failure (controller):** `CREATOR_MODE_RECORDER=false ~/.config/omarchy/plugins/hustlecoding.creator-mode/bin/creator-mode-rec start` prints `"error":"recorder_failed"` ("The recorder exited before recording started…"), and `… status` still says `idle`.
- [ ] **Recorder failure (panel, optional):** `quickshell kill -p "$OMARCHY_PATH/shell"; CREATOR_MODE_RECORDER=false setsid -f quickshell -n -p "$OMARCHY_PATH/shell"`, then `SUPER + ALT + R` → `Enter`. After the countdown you get a red error card, never the REC pill. Restore with `omarchy-restart-shell`.
- [ ] **Uninstall:** `./uninstall.sh`. The binding is gone from `~/.config/hypr/bindings.lua`, the plugin is gone from `omarchy-shell shell listPlugins`, and recordings are still in `~/Videos`.

## 60-second demo script

| Time | On screen | Say |
| --- | --- | --- |
| 0:00 | Desktop, terminal in the repo | "This is Creator Mode, a recording panel I built as a native Omarchy 4 plugin." |
| 0:08 | Run `./install.sh` | "One installer. It copies the plugin into my config, enables it with Omarchy's own CLI, and adds one keybinding. Nothing in Omarchy itself changes." |
| 0:18 | Press `SUPER + ALT + R` | "Here's the panel. It picks up my theme, shows which monitor it will capture, and every action has a key." |
| 0:25 | Press `Enter`, then `Esc` during the countdown | "Countdown, and Escape cancels it. Nothing was recorded." |
| 0:30 | Press `Enter`, let 3-2-1 finish | "Now for real: three, two, one…" |
| 0:34 | Point at the top-center pill, do something on screen | "The red REC pill only shows up once the recorder has actually started writing. The timer is live." |
| 0:44 | Press `SUPER + ALT + R` | "Same key to stop. It says Saving until the file is finalized and verified…" |
| 0:48 | Saved card | "…and here's the exact file, with length and size." |
| 0:52 | Press `O` | "O opens the folder with the file selected." |
| 0:56 | `SUPER + ALT + R`, `P`, drag an area | "And P uses Omarchy's own picker if I only want part of the screen." |

## Handoff

**Works (verified in the container rig):** plugin validation, enable, and summon on Omarchy 4.0.4's real shell; themed idle, countdown, cancel, REC pill with timer, Saving…, Saved, and error states; real Wayland capture through the stand-in with a verified MP4; duplicate and foreign-recording refusal; PID-scoped stop; readable dependency and recorder errors; an idempotent, collision-checked, reversible installer.

**Also verified on the official Omarchy 4.0.4 VM (real Hyprland):** the hotkey, keyboard focus across re-opens, monitor detection, the area/window/monitor picker, Open folder, the foreign-recorder guard, and install/uninstall.

**Not verified here:** a real `gpu-screen-recorder` recording (it needs an AMD/Intel/NVIDIA GPU), audio capture, and readability on a real monitor. Those are items 1–2 above; the checklist covers them.

**Known limitations:**

- No webcam overlay (out of scope). Portal capture (`OMARCHY_SCREENRECORD_USE_PORTAL`) isn't supported; Creator Mode always uses the kms backend like Omarchy's default.
- A foreign `gpu-screen-recorder` is detected by process name. Creator Mode refuses to start next to it but never stops it.
- Omarchy's built-in bar indicator (which watches for `gpu-screen-recorder`) may also light up while Creator Mode records. It doesn't conflict.
- Clicking the bar indicator runs Omarchy's own stop, which kills all recorders. Creator Mode then sees its recorder exit and reports "recovered" if the file is readable.

## Development

```bash
bash -n bin/creator-mode-rec
shellcheck -x bin/creator-mode-rec install.sh uninstall.sh test/*.sh test/fake-recorder test/stand-in-recorder
python3 -m py_compile bin/creator-mode-track bin/creator-mode-studio bin/creator-mode-editor
./test/controller-test.sh        # needs ffmpeg/ffprobe + flock; fake recorder + fake Hyprland socket
./test/studio-test.sh            # renders a synthetic clip with every format/export option
./test/editor-test.sh            # timeline edits, webcam, split audio, and the editor's HTTP API
```

Environment overrides (for testing only): `CREATOR_MODE_RECORDER`, `CREATOR_MODE_MONITOR`,
`CREATOR_MODE_STATE_DIR`, `CREATOR_MODE_START_TIMEOUT`, `CREATOR_MODE_STOP_TIMEOUT`, `CREATOR_MODE_REGION`
(logical `X,Y,W,H` of the capture), `CREATOR_MODE_HYPR_SOCKET`, `CREATOR_MODE_TRACKER`, `CREATOR_MODE_STUDIO`.
