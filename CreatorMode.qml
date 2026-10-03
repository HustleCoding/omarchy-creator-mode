import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Creator Mode: idle -> countdown -> starting -> recording -> saving -> saved,
// with error reachable from every step. The recorder itself is owned by
// bin/creator-mode-rec; this file only drives it and renders its state.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "hustlecoding.creator-mode"
  readonly property string controller: decodeURIComponent(String(Qt.resolvedUrl("bin/creator-mode-rec")).replace(/^file:\/\//, ""))
  property string hotkeyLabel: "Super + Alt + R"

  property bool opened: false
  property string phase: "idle"   // idle | picking | countdown | starting | recording | saving | rendering | saved | error
  property int count: 3
  property string notice: ""

  readonly property var audioModes: ["none", "desktop", "desktop+mic"]
  readonly property var audioLabels: ({ "none": "No audio", "desktop": "Desktop audio", "desktop+mic": "Desktop + mic" })
  property int audioIndex: 0
  readonly property string audioMode: audioModes[audioIndex]

  // Studio: log the cursor while recording, then render an auto-zoomed,
  // framed cut next to the raw file (bin/creator-mode-studio).
  property bool studioAvailable: true
  property bool studioEnabled: true
  readonly property bool studioOn: studioAvailable && studioEnabled
  readonly property var backgrounds: ["theme", "wallpaper", "midnight", "sunset", "ocean", "aurora", "candy", "peach", "dusk", "lime", "forest", "slate", "mono"]
  property int backgroundIndex: 0
  readonly property string background: backgrounds[backgroundIndex]
  readonly property var formats: ["source", "16:9", "9:16", "1:1", "4:5"]
  property int formatIndex: 0
  readonly property string format: formats[formatIndex]
  property bool webcamAvailable: false
  property bool webcamEnabled: false
  readonly property bool webcamOn: studioOn && webcamAvailable && webcamEnabled
  property bool recordingTracked: false
  property real renderProgress: 0
  property string studioFile: ""
  property string studioNotice: ""

  property string captureTarget: "focused"
  property string captureLabel: "Full screen · focused monitor"

  property string outputDir: ""
  property string recordingFile: ""
  property real startedAt: 0
  property real nowMs: Date.now()
  property real savedDuration: 0
  property real savedSize: 0
  property bool savedRecovered: false
  property string errorTitle: ""
  property string errorMessage: ""
  property bool foreignRecording: false

  readonly property bool cardVisible: opened && ["idle", "countdown", "rendering", "saved", "error"].indexOf(phase) !== -1
  // Layer surfaces are part of the capture, so nothing is shown while recording.
  readonly property bool pillVisible: phase === "saving"

  // Theme
  readonly property string fontFamily: Style.font.menuFamily
  readonly property color surface: Color.menu.background
  readonly property color text: Color.menu.text
  readonly property color muted: Util.alpha(Color.menu.text, 0.62)
  readonly property color accent: Color.accent
  readonly property color danger: Color.urgent
  readonly property color scrim: Color.menu.scrim
  readonly property int radius: Style.cornerRadius
  readonly property int pad: Math.max(Style.spacing.panelPadding, Style.space(28))
  readonly property var cardBorder: Border.surfaceSpec("menu", "border",
    phase === "error" ? danger : Color.menu.border, Math.max(1, Style.space(2)))

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    try {
      var payload = payloadJson ? JSON.parse(payloadJson) : ({})
      if (payload && typeof payload.hotkey === "string" && payload.hotkey !== "")
        root.hotkeyLabel = payload.hotkey.split("+").map(function(part) {
          var p = part.trim().toLowerCase()
          return p.charAt(0).toUpperCase() + p.slice(1)
        }).join(" + ")
    } catch (e) {}
    switch (root.phase) {
    case "recording":
      root.stopRecording()
      return
    case "countdown":
      root.cancelCountdown()
      return
    case "picking":
    case "starting":
    case "saving":
      return
    }
    if (root.opened) {
      root.dismiss()
      return
    }
    if (root.phase !== "saved" && root.phase !== "error") root.phase = "idle"
    root.notice = ""
    root.opened = true
    if (root.phase === "idle") root.refreshReadiness()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    if (root.phase === "countdown") root.cancelCountdown()
    root.opened = false
    if (root.phase === "saved" || root.phase === "error") root.phase = "idle"
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  // ------------------------------------------------------------------ actions

  function refreshReadiness() {
    run("check", ["check"])
  }

  function refuseForeign() {
    if (!root.foreignRecording) return false
    root.fail("Another recording is running", "A screen recording started outside Creator Mode is still active. Stop it first (Alt + Print), then try again.")
    return true
  }

  function recordFullScreen() {
    if (root.phase !== "idle") return
    root.captureTarget = "focused"
    root.captureLabel = "Full screen · focused monitor"
    root.beginCountdown()
  }

  function pickArea() {
    if (root.phase !== "idle" || root.refuseForeign()) return
    root.notice = ""
    root.phase = "picking"
    // Let the compositor unmap the overlay so the picker sees the real desktop.
    pickDelay.restart()
  }

  function beginCountdown() {
    if (root.phase !== "idle" || root.refuseForeign()) return
    root.count = 3
    root.notice = ""
    root.phase = "countdown"
    countdownTimer.restart()
  }

  function cancelCountdown() {
    countdownTimer.stop()
    root.phase = "idle"
    root.notice = "Countdown cancelled"
  }

  function startRecording() {
    root.phase = "starting"
    root.opened = false
    // Let the compositor unmap the overlay before the first frame is captured.
    startDelay.restart()
  }

  function stopRecording() {
    if (root.phase !== "recording") return
    root.phase = "saving"
    run("stop", ["stop"])
  }

  function revealFolder() {
    var file = root.studioFile || root.recordingFile
    if (!file) return
    run("reveal", ["reveal", file])
  }

  function toggleStudio() {
    if (!root.studioAvailable) { root.notice = "Studio needs python3 and ffmpeg"; return }
    root.studioEnabled = !root.studioEnabled
  }

  function cycleBackground() {
    root.backgroundIndex = (root.backgroundIndex + 1) % root.backgrounds.length
  }

  function toggleWebcam() {
    if (!root.webcamAvailable) { root.notice = "No webcam found"; return }
    root.webcamEnabled = !root.webcamEnabled
  }

  function openEditor() {
    if (!root.recordingFile) return
    root.notice = "Opening the timeline editor…"
    run("edit", ["edit", root.recordingFile])
  }

  function cycleFormat() {
    root.formatIndex = (root.formatIndex + 1) % root.formats.length
  }

  function startRender() {
    root.renderProgress = 0
    root.studioFile = ""
    root.phase = "rendering"
    root.opened = true
    Qt.callLater(function() { keys.forceActiveFocus() })
    renderProc.result = null
    renderProc.command = ["bash", root.controller, "render", root.recordingFile, "--background=" + root.background, "--format=" + root.format]
    renderProc.running = true
  }

  function cancelRender() {
    if (root.phase !== "rendering") return
    renderProc.cancelled = true
    renderProc.running = false
  }

  function finishRender(exitCode) {
    var result = renderProc.result
    if (renderProc.cancelled) {
      root.studioNotice = "Studio render cancelled; the raw recording is saved."
    } else if (result && result.ok) {
      root.studioFile = result.file
      root.studioNotice = ""
    } else {
      root.studioNotice = "Studio render failed: " + ((result && result.message) || ("exit " + exitCode)) + " The raw recording is saved."
    }
    renderProc.cancelled = false
    root.phase = "saved"
    root.opened = true
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function fail(title, message) {
    countdownTimer.stop()
    root.errorTitle = title
    root.errorMessage = message
    root.phase = "error"
    root.opened = true
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function retry() {
    root.phase = "idle"
    root.notice = ""
    root.refreshReadiness()
  }

  function formatElapsed(ms) {
    var total = Math.max(0, Math.floor(ms / 1000))
    var h = Math.floor(total / 3600)
    var m = Math.floor((total % 3600) / 60)
    var s = total % 60
    var mm = (m < 10 ? "0" : "") + m
    var ss = (s < 10 ? "0" : "") + s
    return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
  }

  function formatSize(bytes) {
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(2) + " GB"
    if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + " MB"
    return Math.max(1, Math.round(bytes / 1024)) + " KB"
  }

  // ------------------------------------------------------- controller process

  property string pendingAction: ""
  property var queued: []

  function run(action, args) {
    if (ctl.running) {
      root.queued = root.queued.concat([{ action: action, args: args }])
      return
    }
    root.pendingAction = action
    ctl.command = ["bash", root.controller].concat(args)
    ctl.running = true
  }

  function parseResult(raw) {
    var lines = String(raw || "").trim().split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      try { return JSON.parse(lines[i]) } catch (e) {}
    }
    return null
  }

  function handleResult(action, exitCode, result) {
    if (!result) {
      result = { ok: false, error: "no_output", message: "Creator Mode's controller didn't respond (exit " + exitCode + "). Controller: " + root.controller }
    }

    if (action === "check") {
      if (!result.ok) { root.fail("Can't record yet", result.message); return }
      root.outputDir = result.outputDir || ""
      root.studioAvailable = result.studio !== false
      root.webcamAvailable = result.webcam === true
      run("status", ["status"])
      return
    }

    if (action === "status" || action === "poll") {
      if (!result.ok) return
      root.foreignRecording = result.foreignRecording === true
      if (result.state === "recording") {
        root.recordingFile = result.file
        root.startedAt = Number(result.startedAt) || Date.now()
        if (root.phase !== "recording") {
          root.opened = false
          root.phase = "recording"
        }
      } else if (result.state === "crashed") {
        root.phase = "saving"
        run("stop", ["stop"])
      } else if (action === "poll" && root.phase === "recording") {
        root.fail("Recording ended", "The recorder is no longer running and left no state behind.")
      }
      return
    }

    if (action === "pick") {
      root.phase = "idle"
      root.opened = true
      Qt.callLater(function() { keys.forceActiveFocus() })
      if (!result.ok) {
        if (result.error === "cancelled") root.notice = result.message
        else root.fail("Can't pick an area", result.message)
        return
      }
      root.captureTarget = result.target
      root.captureLabel = result.label || result.target
      root.beginCountdown()
      return
    }

    if (action === "start") {
      if (!result.ok) {
        root.fail(result.error === "already_recording" ? "Already recording" : "Recording didn't start", result.message)
        if (result.error === "already_recording") run("status", ["status"])
        return
      }
      root.recordingFile = result.file
      root.startedAt = Number(result.startedAt) || Date.now()
      root.nowMs = Date.now()
      root.recordingTracked = result.studio === true
      root.studioNotice = result.notice || ""
      root.phase = "recording"
      return
    }

    if (action === "stop") {
      if (!result.ok && result.error === "busy" && root.stopRetries < 5) {
        root.stopRetries += 1
        stopRetry.restart()
        return
      }
      root.stopRetries = 0
      if (!result.ok) {
        root.fail("Recording wasn't saved", result.message)
        return
      }
      root.recordingFile = result.file
      root.savedDuration = Number(result.duration) || 0
      root.savedSize = Number(result.size) || 0
      root.savedRecovered = result.recovered === true
      root.studioFile = ""
      if (root.studioOn && typeof result.events === "string" && result.events !== "") {
        root.startRender()
        return
      }
      root.phase = "saved"
      root.opened = true
      Qt.callLater(function() { keys.forceActiveFocus() })
      return
    }

    if (action === "edit") {
      if (!result.ok) root.notice = result.message
      else root.dismiss()
      return
    }

    if (action === "reveal") {
      if (!result.ok) root.notice = result.message
      else root.dismiss()
    }
  }

  Process {
    id: ctl
    stdout: StdioCollector { id: ctlOut; waitForEnd: true }
    onExited: function(exitCode) {
      var action = root.pendingAction
      root.pendingAction = ""
      root.handleResult(action, exitCode, root.parseResult(ctlOut.text))
      if (root.queued.length) {
        var next = root.queued[0]
        root.queued = root.queued.slice(1)
        root.run(next.action, next.args)
      }
    }
  }

  Process {
    id: renderProc
    property var result: null
    property bool cancelled: false
    stdout: SplitParser {
      onRead: function(line) {
        var msg = null
        try { msg = JSON.parse(line) } catch (e) { return }
        if (typeof msg.progress === "number") root.renderProgress = msg.progress
        else renderProc.result = msg
      }
    }
    onExited: function(exitCode) { root.finishRender(exitCode) }
  }

  Timer {
    id: countdownTimer
    interval: 1000
    repeat: true
    onTriggered: {
      if (root.count > 1) {
        root.count -= 1
      } else {
        stop()
        root.startRecording()
      }
    }
  }

  property int stopRetries: 0

  Timer {
    id: stopRetry
    interval: 1000
    onTriggered: root.run("stop", ["stop"])
  }

  Timer {
    id: startDelay
    interval: 250
    onTriggered: root.run("start", ["start", "--audio=" + root.audioMode, "--target=" + root.captureTarget,
                                     "--studio=" + (root.studioOn ? "on" : "off"), "--webcam=" + (root.webcamOn ? "on" : "off")])
  }

  Timer {
    id: pickDelay
    interval: 250
    onTriggered: root.run("pick", ["pick"])
  }

  Timer {
    interval: 200
    repeat: true
    running: root.phase === "recording"
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.phase === "recording" || (root.cardVisible && root.phase === "idle")
    onTriggered: if (!ctl.running) root.run("poll", ["status"])
  }

  Component.onCompleted: run("status", ["status"])

  // ------------------------------------------------------------- components

  component KeyAction: Item {
    id: action
    property string keyLabel: ""
    property string label: ""
    property bool primary: false
    signal activated()

    implicitWidth: row.implicitWidth + Style.space(20)
    implicitHeight: Math.max(Style.space(40), row.implicitHeight + Style.space(14))

    Rectangle {
      anchors.fill: parent
      radius: root.radius
      color: mouse.containsMouse
        ? Util.alpha(action.primary ? root.accent : root.text, 0.18)
        : Util.alpha(action.primary ? root.accent : root.text, action.primary ? 0.12 : 0.05)
      border.width: 1
      border.color: Util.alpha(action.primary ? root.accent : root.text, action.primary ? 0.7 : 0.22)
    }

    Row {
      id: row
      anchors.centerIn: parent
      spacing: Style.space(10)

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(Style.space(26), keyText.implicitWidth + Style.space(12))
        height: Style.space(24)
        radius: Math.max(2, root.radius / 2)
        color: Util.alpha(root.text, 0.1)
        border.width: 1
        border.color: Util.alpha(root.text, 0.3)
        Text {
          id: keyText
          anchors.centerIn: parent
          text: action.keyLabel
          color: root.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: action.label
        color: action.primary ? root.accent : root.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.activated()
    }
  }

  // ------------------------------------------------------------ main overlay

  PanelWindow {
    id: overlay
    visible: root.cardVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "creator-mode"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: if (root.phase !== "countdown" && root.phase !== "rendering") root.dismiss()
    }

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var k = event.key
        var s = root.phase
        var handled = true
        if (s === "countdown") {
          if (k === Qt.Key_Escape) root.cancelCountdown()
        } else if (s === "idle") {
          if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || k === Qt.Key_R) root.recordFullScreen()
          else if (k === Qt.Key_P) root.pickArea()
          else if (k === Qt.Key_A) root.audioIndex = (root.audioIndex + 1) % root.audioModes.length
          else if (k === Qt.Key_S) root.toggleStudio()
          else if (k === Qt.Key_B && root.studioOn) root.cycleBackground()
          else if (k === Qt.Key_F && root.studioOn) root.cycleFormat()
          else if (k === Qt.Key_W && root.studioOn) root.toggleWebcam()
          else if (k === Qt.Key_Escape || k === Qt.Key_Q) root.dismiss()
          else handled = false
        } else if (s === "rendering") {
          if (k === Qt.Key_Escape) root.cancelRender()
          else handled = false
        } else if (s === "saved") {
          if (k === Qt.Key_O) root.revealFolder()
          else if (k === Qt.Key_E && root.studioAvailable) root.openEditor()
          else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_R) { root.phase = "idle"; root.refreshReadiness() }
          else if (k === Qt.Key_Escape || k === Qt.Key_Q) root.dismiss()
          else handled = false
        } else if (s === "error") {
          if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_R) root.retry()
          else if (k === Qt.Key_Escape || k === Qt.Key_Q) root.dismiss()
          else handled = false
        } else {
          handled = false
        }
        event.accepted = handled
      }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(560), overlay.width - Style.gapsOut * 4)
      height: content.implicitHeight + contentTopInset + contentBottomInset
      radius: root.radius
      color: root.surface
      borderSpec: root.cardBorder
      padding: root.pad

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: content
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        spacing: Style.space(18)

        Row {
          spacing: Style.space(10)
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(10); height: width; radius: width / 2
            color: root.phase === "error" ? root.danger : root.accent
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "CREATOR MODE"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: Style.space(2)
            font.bold: true
          }
        }

        // ---- idle
        Column {
          visible: root.phase === "idle"
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "Ready to record"
            color: root.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Full screen, or pick an area, window or monitor · " + root.audioLabels[root.audioMode]
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.studioOn
              ? "Studio on · auto-zoom, smooth cursor, " + root.background + " background, " + (root.format === "source" ? "source size" : root.format) + (root.webcamOn ? ", webcam" : "")
              : (root.studioAvailable ? "Studio off · raw recording only" : "Studio unavailable (needs python3 + ffmpeg)")
            color: root.studioOn ? root.accent : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width
            visible: root.outputDir !== ""
            elide: Text.ElideMiddle
            text: "Saves to " + root.outputDir
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            visible: root.notice !== ""
            text: root.notice
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Flow {
          visible: root.phase === "idle"
          width: parent.width
          spacing: Style.space(10)
          KeyAction { keyLabel: "Enter"; label: "Full screen"; primary: true; onActivated: root.recordFullScreen() }
          KeyAction { keyLabel: "P"; label: "Pick area"; onActivated: root.pickArea() }
          KeyAction { keyLabel: "A"; label: "Audio"; onActivated: root.audioIndex = (root.audioIndex + 1) % root.audioModes.length }
          KeyAction { keyLabel: "S"; label: "Studio"; onActivated: root.toggleStudio() }
          KeyAction { keyLabel: "B"; label: "Background"; visible: root.studioOn; onActivated: root.cycleBackground() }
          KeyAction { keyLabel: "F"; label: "Format"; visible: root.studioOn; onActivated: root.cycleFormat() }
          KeyAction { keyLabel: "W"; label: root.webcamOn ? "Webcam on" : "Webcam"; visible: root.studioOn && root.webcamAvailable; onActivated: root.toggleWebcam() }
          KeyAction { keyLabel: "Esc"; label: "Close"; onActivated: root.dismiss() }
        }

        // ---- countdown
        Column {
          visible: root.phase === "countdown"
          width: parent.width
          spacing: Style.space(4)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Recording starts in"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }
          Item {
            width: parent.width
            height: Style.space(190)
            Text {
              id: countText
              anchors.centerIn: parent
              text: String(root.count)
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.space(170)
              font.bold: true
              onTextChanged: if (root.phase === "countdown") pop.restart()
              SequentialAnimation {
                id: pop
                ParallelAnimation {
                  NumberAnimation { target: countText; property: "scale"; from: 1.25; to: 1.0; duration: 320; easing.type: Easing.OutCubic }
                  NumberAnimation { target: countText; property: "opacity"; from: 0.2; to: 1.0; duration: 260 }
                }
              }
            }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.captureLabel + " · Esc to cancel"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }

        // ---- rendering
        Column {
          visible: root.phase === "rendering"
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "Rendering studio cut"
            color: root.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: Math.round(root.renderProgress * 100) + "% · auto-zoom, cursor and " + root.background + " background · the raw recording is already saved"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Rectangle {
            width: parent.width
            height: Style.space(8)
            radius: height / 2
            color: Util.alpha(root.text, 0.12)
            Rectangle {
              width: parent.width * Math.max(0, Math.min(1, root.renderProgress))
              height: parent.height
              radius: parent.radius
              color: root.accent
              Behavior on width { NumberAnimation { duration: 200 } }
            }
          }
        }

        Flow {
          visible: root.phase === "rendering"
          width: parent.width
          spacing: Style.space(10)
          KeyAction { keyLabel: "Esc"; label: "Skip studio cut"; onActivated: root.cancelRender() }
        }

        // ---- saved
        Column {
          visible: root.phase === "saved"
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: root.studioFile ? "Studio cut saved" : "Recording saved"
            color: root.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }
          Text {
            text: root.formatElapsed(root.savedDuration * 1000) + " · " + root.formatSize(root.savedSize)
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Text {
            visible: root.savedRecovered
            width: parent.width
            wrapMode: Text.Wrap
            text: "The recorder stopped on its own; this is what it saved."
            color: root.danger
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            visible: root.studioNotice !== ""
            width: parent.width
            wrapMode: Text.Wrap
            text: root.studioNotice
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Rectangle {
            width: parent.width
            height: pathText.implicitHeight + Style.space(20)
            radius: root.radius
            color: Util.alpha(root.text, 0.06)
            border.width: 1
            border.color: Util.alpha(root.text, 0.14)
            Text {
              id: pathText
              anchors.fill: parent
              anchors.margins: Style.space(10)
              verticalAlignment: Text.AlignVCenter
              wrapMode: Text.WrapAnywhere
              text: root.studioFile ? root.studioFile + "\nRaw: " + root.recordingFile : root.recordingFile
              color: root.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }
          }
          Text {
            visible: root.notice !== ""
            width: parent.width
            elide: Text.ElideMiddle
            text: root.notice
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Flow {
          visible: root.phase === "saved"
          width: parent.width
          spacing: Style.space(10)
          KeyAction { keyLabel: "O"; label: "Open folder"; primary: true; onActivated: root.revealFolder() }
          KeyAction { keyLabel: "E"; label: "Edit timeline"; visible: root.studioAvailable; onActivated: root.openEditor() }
          KeyAction { keyLabel: "Enter"; label: "New recording"; onActivated: { root.phase = "idle"; root.refreshReadiness() } }
          KeyAction { keyLabel: "Esc"; label: "Done"; onActivated: root.dismiss() }
        }

        // ---- error
        Column {
          visible: root.phase === "error"
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.errorTitle
            color: root.danger
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.errorMessage
            color: root.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            lineHeight: 1.15
          }
        }

        Flow {
          visible: root.phase === "error"
          width: parent.width
          spacing: Style.space(10)
          KeyAction { keyLabel: "Enter"; label: "Try again"; primary: true; onActivated: root.retry() }
          KeyAction { keyLabel: "Esc"; label: "Close"; onActivated: root.dismiss() }
        }
      }
    }
  }

  // --------------------------------------------------------- recording pill

  PanelWindow {
    id: pill
    visible: root.pillVisible
    anchors { top: true }
    margins { top: Style.gapsOut * 2 }
    implicitWidth: pillBody.width
    implicitHeight: pillBody.height
    color: "transparent"
    WlrLayershell.namespace: "creator-mode-indicator"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Normal

    BorderSurface {
      id: pillBody
      width: pillRow.implicitWidth + Style.space(32)
      height: pillRow.implicitHeight + Style.space(18)
      radius: root.radius
      color: root.surface
      borderSpec: Border.surfaceSpec("menu", "border",
        root.phase === "recording" ? root.danger : Color.menu.border, Math.max(1, Style.space(2)))

      Row {
        id: pillRow
        anchors.centerIn: parent
        spacing: Style.space(12)

        Rectangle {
          id: dot
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(14); height: width; radius: width / 2
          color: root.phase === "recording" ? root.danger : root.accent
          SequentialAnimation on opacity {
            running: root.pillVisible
            loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.phase === "recording" ? "REC" : (root.phase === "saving" ? "Saving…" : "Starting…")
          color: root.phase === "recording" ? root.danger : root.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.phase === "recording"
          text: root.formatElapsed(root.nowMs - root.startedAt)
          color: root.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.phase === "recording"
          text: root.hotkeyLabel + " to stop"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: root.phase === "recording" ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.stopRecording()
      }
    }
  }
}
