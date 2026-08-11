import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon + settings panel for the folder-backed background service.
//
// The widget exists mainly so the settings have somewhere to live: shell.json
// plugin settings can only be persisted through `setBarWidget`, which targets
// entries in bar.layout.*. Everything here writes through that IPC rather than
// touching shell.json, so the shell stays the only writer.
//
// The service reads the same entry back out of shell.shellConfig, so a saved
// change reaches the wallpaper without a restart.
Panel {
  id: root
  moduleName: "matjam.omawall"
  ipcTarget: "matjam.omawall"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string folder: String(setting("folder", ""))
  readonly property bool recursive: setting("recursive", true) === true
  readonly property bool perDisplay: setting("perDisplay", true) === true
  readonly property int intervalSec: Math.max(0, Number(setting("intervalSec", 0)) || 0)
  readonly property bool autoTheme: setting("autoTheme", false) === true
  readonly property string primaryDisplay: String(setting("primaryDisplay", "")).trim()
  readonly property string themeMode: String(setting("themeMode", "dark")) === "light" ? "light" : "dark"

  readonly property string autoDisplayLabel: "Automatic (first display)"

  // Reported by the service, so the picker lists the outputs it will actually
  // choose between rather than the bar's own view of them.
  property var displays: []
  property string resolvedPrimary: ""

  // -1 until the check has run, so the warning below is not shown in the moment
  // before we know either way.
  property int matugenPresent: -1

  function displayOptions() {
    var out = [autoDisplayLabel]
    for (var i = 0; i < displays.length; i++) out.push(String(displays[i]))
    return out
  }

  function displayValue() {
    return primaryDisplay === "" ? autoDisplayLabel : primaryDisplay
  }

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: Style.font.family

  property int poolSize: -1
  property var screenPicks: ({})

  readonly property string statusLine: {
    if (folder === "") return "No folder set — using the current theme's backgrounds."
    if (poolSize < 0) return "Scanning…"
    if (poolSize === 0) return "No images found in that folder."
    return poolSize + (poolSize === 1 ? " image" : " images") + " found."
  }

  // ------------------------------------------------------------- persistence

  property var _saveQueue: []

  function persist(key, value) {
    _saveQueue = _saveQueue.concat([[key, value]])
    drainSaves()
  }

  function drainSaves() {
    if (saveProc.running || !_saveQueue.length) return
    var job = _saveQueue[0]
    _saveQueue = _saveQueue.slice(1)
    saveProc.command = ["omarchy-shell", "shell", "setBarWidget",
      root.moduleName, String(job[0]), JSON.stringify(job[1]), "{}"]
    saveProc.running = true
  }

  Process {
    id: saveProc
    onExited: {
      root.drainSaves()
      if (!root._saveQueue.length) refreshTimer.restart()
    }
  }

  // ------------------------------------------------------------------ status

  function refreshStatus() {
    if (statusProc.running) return
    root.poolSize = -1
    statusProc.running = true
  }

  // No -q here: the omarchy-shell wrapper's quiet mode suppresses stdout
  // entirely, so the reply would arrive as an empty string and parse into a
  // poolSize of 0 — the panel would report "no images found" for a folder
  // that had just scanned hundreds. Quiet mode is only right for the
  // fire-and-forget calls below, whose output nobody reads.
  Process {
    id: statusProc
    command: ["omarchy-shell", "background", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        var data = null
        try { data = JSON.parse(raw) } catch (e) { return }
        if (!data || data.poolSize === undefined) return
        root.poolSize = Number(data.poolSize)
        root.screenPicks = data.screens || ({})
        root.displays = Array.isArray(data.displays) ? data.displays : []
        root.resolvedPrimary = String(data.primaryDisplay || "")
      }
    }
  }

  // Settings land asynchronously (write -> shell.json -> service rescan), so
  // give the service a beat before asking it what it found.
  Timer {
    id: refreshTimer
    interval: 400
    repeat: false
    onTriggered: root.refreshStatus()
  }

  // ----------------------------------------------------------------- actions

  function browse() {
    if (browseProc.running) return
    var cmd = ["zenity", "--file-selection", "--directory",
      "--title=Choose a wallpaper folder"]
    if (root.folder !== "") cmd.push("--filename=" + root.folder + "/")
    browseProc.command = cmd
    browseProc.running = true
  }

  // Cancelling zenity exits nonzero with no stdout, which lands here as an
  // empty string — treated the same as "no change".
  Process {
    id: browseProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var picked = String(text || "").trim()
        if (picked !== "") root.persist("folder", picked)
      }
    }
  }

  // Quickshell.execDetached with an argv array, NOT Util.execDetached: that
  // helper takes a command *string* and wraps it in `bash -lc`, so an array
  // silently stringifies to "omarchy-shell,-q,background,shuffle" and the
  // button does nothing.
  function shuffleNow() {
    Quickshell.execDetached(["omarchy-shell", "-q", "background", "shuffle"])
    refreshTimer.restart()
  }

  function rescanNow() {
    Quickshell.execDetached(["omarchy-shell", "-q", "background", "rescan"])
    refreshTimer.restart()
  }

  function generateThemeNow() {
    Quickshell.execDetached(["omarchy-shell", "-q", "background", "generateTheme"])
  }

  // The generator is useless without matugen, and its absence is the one
  // failure a user can actually fix, so surface it in the panel rather than
  // only in the shell log when a run fails.
  Process {
    id: matugenProbe
    command: ["bash", "-c", "command -v matugen >/dev/null && echo yes || echo no"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.matugenPresent = String(text || "").trim() === "yes" ? 1 : 0
    }
  }

  onOpenedChanged: if (opened) {
    folderField.text = root.folder
    refreshStatus()
    if (!matugenProbe.running) matugenProbe.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The bar is instantiated once per screen, so on a multi-monitor setup this
  // registers twice and Quickshell logs "another handler is registered for
  // target matjam.omawall". First one wins, the panel still opens, and the
  // stock omarchy.power / omarchy.dropbox widgets emit the same warning — it
  // is the house pattern, not a fault here.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function shuffle(): string { root.shuffleNow(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰸉"
    tooltipText: root.folder === "" ? "Wallpapers" : "Wallpapers — " + root.folder
    active: root.opened
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.shuffleNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // No cap. The cap is a maximum, not a scroll viewport, so content taller
    // than it spills past the panel's border rather than becoming reachable --
    // which is what the old 620 did once the theme section was added. The stock
    // panels whose content is a fixed set of controls (clock, weather) also
    // pass no cap and let fittedContentHeight clamp to the screen instead;
    // the ones that do cap are those listing an unbounded number of devices.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Typing in the folder field must reach the field, not the panel's
      // single-key shortcuts.
      blocked: folderField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.shuffleNow()
        else if (t === "r" || t === "R") root.rescanNow()
        else if (t === "b" || t === "B") root.browse()
        else if (t === "t" || t === "T") root.generateThemeNow()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelSectionHeader {
          text: "WALLPAPER FOLDER"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: folderField
            width: parent.width - browseButton.implicitWidth - parent.spacing
            foreground: root.fg
            placeholderText: "~/Pictures/wallpapers"
            onAccepted: root.persist("folder", text.trim())
            onEditingFinished: if (text.trim() !== root.folder) root.persist("folder", text.trim())
          }

          Button {
            id: browseButton
            text: "Browse…"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.browse()
          }
        }

        Text {
          width: parent.width
          text: root.statusLine
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Button {
          visible: root.folder !== ""
          text: "Clear folder (use theme backgrounds)"
          bordered: true
          leftAlign: true
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.persist("folder", "")
        }

        PanelSeparator {}

        Toggle {
          width: parent.width
          label: "Search subfolders"
          description: "Include images nested below the chosen folder."
          checked: root.recursive
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.persist("recursive", !root.recursive)
        }

        Toggle {
          width: parent.width
          label: "Different image per display"
          description: "Deal each monitor its own random pick instead of mirroring one image."
          checked: root.perDisplay
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.persist("perDisplay", !root.perDisplay)
        }

        PanelSeparator {}

        NumberField {
          label: "Auto-shuffle every (seconds, 0 = off)"
          value: root.intervalSec
          from: 0
          to: 86400
          stepSize: 60
          foreground: root.fg
          fontFamily: root.fontFamily
          onModified: function(v) { root.persist("intervalSec", v) }
        }

        PanelSeparator {}

        PanelSectionHeader {
          text: "THEME FROM WALLPAPER"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Toggle {
          width: parent.width
          label: "Generate theme from wallpaper"
          description: "Build an 'omawall' theme from the primary display's image and switch to it."
          checked: root.autoTheme
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.persist("autoTheme", !root.autoTheme)
        }

        Text {
          visible: root.matugenPresent === 0
          width: parent.width
          text: "matugen is not installed — run: sudo pacman -S matugen"
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Dropdown {
          width: parent.width
          label: "Primary display"
          options: root.displayOptions()
          value: root.displayValue()
          foreground: root.fg
          fontFamily: root.fontFamily
          onChanged: function(v) {
            root.persist("primaryDisplay", v === root.autoDisplayLabel ? "" : String(v))
          }
        }

        Toggle {
          width: parent.width
          label: "Light theme"
          description: "Generate a light palette instead of a dark one."
          checked: root.themeMode === "light"
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.persist("themeMode", root.themeMode === "light" ? "dark" : "light")
        }

        PanelSeparator {}

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: "Generate theme now"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.generateThemeNow()
          }
        }

        PanelSeparator {}

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: "Shuffle now"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.shuffleNow()
          }

          Button {
            text: "Rescan folder"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.rescanNow()
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.folder !== ""

          Repeater {
            model: {
              var out = []
              for (var name in root.screenPicks) {
                var p = String(root.screenPicks[name] || "")
                out.push({ screen: name, file: p.substring(p.lastIndexOf("/") + 1) })
              }
              return out
            }
            Text {
              required property var modelData
              width: column.width
              text: modelData.screen + "  ·  " + modelData.file
              color: Qt.darker(root.fg, 1.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }
        }
      }
    }
  }
}
