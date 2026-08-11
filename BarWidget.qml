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

  readonly property bool perDisplay: setting("perDisplay", true) === true
  readonly property int intervalSec: Math.max(0, Number(setting("intervalSec", 0)) || 0)
  readonly property bool shuffleOnWake: setting("shuffleOnWake", false) === true
  readonly property bool autoTheme: setting("autoTheme", false) === true
  readonly property string primaryDisplay: String(setting("primaryDisplay", "")).trim()
  readonly property string themeMode: String(setting("themeMode", "dark")) === "light" ? "light" : "dark"

  readonly property string autoDisplayLabel: "Automatic (first display)"

  // ---------------------------------------------------- per-display config

  readonly property bool perDisplayConfig: setting("perDisplayConfig", false) === true
  readonly property var displayConfig: setting("displayConfig", null)

  // Which display's settings the panel is showing. Empty means the shared
  // "all" entry, which is also what every display reads when the per-display
  // toggle is off.
  property string editing: ""

  // Must resolve exactly as editingTabLabel() does. `editing` stays empty until
  // a display tab is actually clicked, and falling back to "all" here while the
  // tab row already highlights the first display meant that a change made
  // before any click landed on the shared entry rather than on the display
  // shown as selected: the setting saved, the panel updated to match, and
  // nothing happened on screen.
  readonly property string editingKey: {
    if (!perDisplayConfig) return "all"
    var tabs = displayTabs()
    if (editing !== "" && tabs.indexOf(editing) !== -1) return editing
    return tabs.length ? tabs[0] : "all"
  }

  // The same resolution the service performs, so the panel shows what is
  // actually in effect rather than what was last typed. Legacy top-level
  // folder/recursive are the fallback, which is what makes an older settings
  // file open correctly instead of looking empty.
  function configFor(key) {
    var dc = displayConfig
    var c = (dc && typeof dc === "object" && dc[key] && typeof dc[key] === "object") ? dc[key] : null
    if (!c && dc && dc.all && typeof dc.all === "object") c = dc.all
    var pick = function(k, legacy) {
      return (c && c[k] !== undefined && c[k] !== null) ? c[k] : legacy
    }
    var mode = String(pick("mode", "shuffle"))
    var scaling = String(pick("scaling", "zoom"))
    return {
      folder: String(pick("folder", setting("folder", ""))),
      recursive: pick("recursive", setting("recursive", true)) === true,
      mode: mode === "single" ? "single" : "shuffle",
      pinned: String(pick("pinned", "")),
      scaling: ["zoom", "fitHeight", "fitWidth", "actual"].indexOf(scaling) !== -1 ? scaling : "zoom"
    }
  }

  readonly property var current: configFor(editingKey)

  // Writes the whole displayConfig back, because setBarWidget replaces a key
  // rather than merging into it. Seeding from the resolved config also folds
  // any legacy top-level settings into the new shape on the first edit, which
  // is the only migration this needs.
  function persistDisplay(key, value) {
    var dc = ({})
    var existing = displayConfig
    if (existing && typeof existing === "object") {
      for (var k in existing) {
        if (existing[k] && typeof existing[k] === "object") {
          var copy = ({})
          for (var f in existing[k]) copy[f] = existing[k][f]
          dc[k] = copy
        }
      }
    }
    if (!dc[editingKey]) dc[editingKey] = configFor(editingKey)
    dc[editingKey][key] = value
    persist("displayConfig", dc)
  }

  readonly property var scalingOptions: [
    { key: "zoom", label: "Zoom" },
    { key: "fitHeight", label: "Fit ↕" },
    { key: "fitWidth", label: "Fit ↔" },
    { key: "actual", label: "Actual" }
  ]

  function scalingLabels() {
    var out = []
    for (var i = 0; i < scalingOptions.length; i++) out.push(scalingOptions[i].label)
    return out
  }

  function scalingLabelFor(key) {
    for (var i = 0; i < scalingOptions.length; i++)
      if (scalingOptions[i].key === key) return scalingOptions[i].label
    return "Zoom"
  }

  function scalingKeyFor(label) {
    for (var i = 0; i < scalingOptions.length; i++)
      if (scalingOptions[i].label === label) return scalingOptions[i].key
    return "zoom"
  }

  // Primary first, so the display driving the theme reads as the default.
  function displayTabs() {
    var out = []
    var primary = resolvedPrimary
    if (primary !== "" && displays.indexOf(primary) !== -1) out.push(primary)
    for (var i = 0; i < displays.length; i++)
      if (String(displays[i]) !== primary) out.push(String(displays[i]))
    return out
  }

  function displayTabLabels() {
    var tabs = displayTabs()
    var out = []
    for (var i = 0; i < tabs.length; i++)
      out.push(tabs[i] === resolvedPrimary ? "★ " + tabs[i] : tabs[i])
    return out
  }

  function tabLabelToDisplay(label) {
    return String(label).replace(/^★ /, "")
  }

  // Which group of settings is on show.
  property string tab: "displays"

  function tabLabel() {
    if (tab === "shuffling") return "Shuffling"
    if (tab === "theme") return "Theme"
    return "Displays"
  }

  function editingTabLabel() {
    var tabs = displayTabs()
    var name = editing !== "" && tabs.indexOf(editing) !== -1 ? editing : (tabs.length ? tabs[0] : "")
    return name === resolvedPrimary ? "★ " + name : name
  }

  // ------------------------------------------------------------- the picker

  property var pickerImages: []

  // Listed by the widget rather than taken from the service's pool: the pool
  // holds only what the *service* is configured to use, and the picker has to
  // show the folder being edited, which may be a different display's.
  function loadPicker() {
    var folder = String(current.folder || "").trim()
    if (folder === "" || pickerProc.running) { pickerImages = []; return }
    pickerProc.command = ["bash", "-c",
      "find -L " + Util.shellQuote(folder) + (current.recursive ? "" : " -maxdepth 1") +
      " -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif'" +
      " -o -iname '*.bmp' -o -iname '*.webp' \\) 2>/dev/null | sort | head -500"]
    pickerProc.running = true
  }

  Process {
    id: pickerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pickerImages = String(text || "").split("\n").filter(function(p) { return p !== "" })
      }
    }
  }

  // The picker shows the folder of whichever display is being edited, so it
  // has to reload when either changes -- not only when single mode is chosen.
  // Guarded: both fire while the component is still being built, before the
  // `current` binding has produced anything to read.
  onEditingChanged: if (current && current.mode === "single") loadPicker()
  onDisplayConfigChanged: if (current && current.mode === "single") loadPicker()

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

  property int skipped: 0

  readonly property string statusLine: {
    if (current.folder === "") return "No folder set — using the current theme's backgrounds."
    if (poolSize < 0) return "Scanning…"
    if (poolSize === 0)
      return skipped > 0
        ? "No usable images — " + skipped + (skipped === 1 ? " file" : " files")
          + " could not be decoded."
        : "No images found in that folder."
    var line = poolSize + (poolSize === 1 ? " image" : " images") + " found."
    if (skipped > 0)
      line += " " + skipped + (skipped === 1 ? " image was" : " images were")
        + " skipped as undecodable; rescan to retry."
    return line
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
    onExited: function(code, status) {
      if (code !== 0) console.warn("omawall: failed to save setting (exit " + code + ")")
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
        root.skipped = Number(data.skipped || 0)
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
    // Choosing the dialog supersedes anything half-typed in the field.
    root.folderEdited = false

    // Close before launching, not because the dialog needs it but because the
    // panel holds exclusive keyboard focus while it is open. zenity maps behind
    // that and comes up unfocused; the click needed to focus it then lands
    // outside the panel's card and dismisses it anyway. Standing aside first
    // lets the dialog take focus normally and turns a panel that gets knocked
    // over into one that hands off deliberately. It comes back in onExited.
    root.close()

    var cmd = ["zenity", "--file-selection", "--directory",
      "--title=Choose a wallpaper folder"]
    if (root.current.folder !== "") cmd.push("--filename=" + root.current.folder + "/")
    browseProc.command = cmd
    browseProc.running = true
  }

  // Cancelling zenity exits nonzero with no stdout, which lands here as an
  // empty string — treated the same as "no change".
  Process {
    id: browseProc
    // Come back whether a folder was chosen or the dialog was cancelled: the
    // dialog is an excursion from the panel, so returning to it is what the
    // gesture implies either way. stdout is delivered before exit, so by now
    // any chosen path has already been persisted and the panel reopens showing
    // it rather than the path it replaced.
    onExited: if (!root.opened) root.open()

    // Without this, a zenity that fails to start says so into a void and the
    // button just looks inert.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") console.warn("omawall: zenity: " + err)
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var picked = String(text || "").trim()
        if (picked === "") return
        root.folderEdited = false
        root.persistDisplay("folder", picked)
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

  // True only while the user has typed something not yet committed. Guards the
  // field's write-back so it can never resurrect a stale path.
  property bool folderEdited: false

  // The setting changes from more places than this field: the file dialog, the
  // CLI, or this same panel on another monitor. Mirror it back unless the user
  // is part-way through typing something else.
  // The folder can change from the file dialog, the CLI, or by switching to
  // another display's tab. Mirror it back unless the user is mid-edit.
  onCurrentChanged: if (!folderEdited && folderField) folderField.text = current.folder

  onOpenedChanged: if (opened) {
    folderEdited = false
    folderField.text = root.current.folder
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
    tooltipText: root.current.folder === "" ? "Wallpapers" : "Wallpapers — " + root.current.folder
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

        // Three groups of settings, one visible at a time. The panel outgrew a
        // single scroll of controls once displays could be configured
        // individually, and the cap on its height is a clamp rather than a
        // viewport -- content past it spills outside the border instead of
        // becoming reachable.
        ButtonGroup {
          width: parent.width
          options: ["Displays", "Shuffling", "Theme"]
          value: root.tabLabel()
          foreground: root.fg
          fontFamily: root.fontFamily
          onChanged: function(v) { root.tab = String(v).toLowerCase() }
        }

        // ═══════════════════════════════════════════════════════ displays

        Column {
          visible: root.tab === "displays"
          width: parent.width
          spacing: Style.space(12)

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
            label: "Configure each display separately"
            description: "Off: one configuration shared by every display."
            checked: root.perDisplayConfig
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.persist("perDisplayConfig", !root.perDisplayConfig)
          }

          ButtonGroup {
            visible: root.perDisplayConfig && root.displays.length > 0
            width: parent.width
            options: root.displayTabLabels()
            value: root.editingTabLabel()
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(v) { root.editing = root.tabLabelToDisplay(v) }
          }

          Text {
            visible: !root.perDisplayConfig
            width: parent.width
            text: "All displays"
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSectionHeader {
            text: "FOLDER"
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
              // Only a keystroke counts as an edit. Assigning text from the
              // setting must not arm the write-back.
              onTextChanged: if (activeFocus) root.folderEdited = true
              onAccepted: {
                root.folderEdited = false
                root.persistDisplay("folder", text.trim())
              }
              // editingFinished fires on any focus loss, including the panel
              // being dismissed because the file dialog took focus. Writing
              // back unconditionally there is what made Browse… look broken:
              // the field still held the old path and overwrote the one just
              // chosen.
              onEditingFinished: {
                if (!root.folderEdited) return
                root.folderEdited = false
                if (text.trim() !== root.current.folder) root.persistDisplay("folder", text.trim())
              }
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
            visible: root.current.folder !== ""
            text: "Clear folder (use theme backgrounds)"
            bordered: true
            leftAlign: true
            width: parent.width
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.persistDisplay("folder", "")
          }

          Toggle {
            width: parent.width
            label: "Search subfolders"
            description: "Include images nested below the chosen folder."
            checked: root.current.recursive
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.persistDisplay("recursive", !root.current.recursive)
          }

          PanelSectionHeader {
            text: "MODE"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            width: parent.width
            options: ["Shuffle", "Single"]
            value: root.current.mode === "single" ? "Single" : "Shuffle"
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(v) {
              var mode = String(v).toLowerCase()
              root.persistDisplay("mode", mode)
              if (mode === "single") root.loadPicker()
            }
          }

          // The picker. Thumbnails come straight off disk, and GridView only
          // instantiates the delegates in view, so a folder of hundreds costs
          // a screenful of decodes rather than hundreds.
          Rectangle {
            visible: root.current.mode === "single"
            width: parent.width
            height: Style.space(220)
            color: "transparent"
            border.width: Style.normalBorderWidth
            border.color: Qt.darker(root.fg, 2.0)

            GridView {
              id: picker
              anchors.fill: parent
              anchors.margins: Style.space(4)
              clip: true
              cellWidth: Math.floor((width - 1) / 3)
              cellHeight: Math.round(cellWidth * 9 / 16)
              model: root.pickerImages

              delegate: Item {
                required property var modelData
                width: picker.cellWidth
                height: picker.cellHeight

                Image {
                  anchors.fill: parent
                  anchors.margins: Style.space(3)
                  source: "file://" + modelData
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  // Decode at thumbnail size rather than full resolution:
                  // without this a grid of 4K wallpapers would decode hundreds
                  // of megabytes to draw a few hundred pixels.
                  sourceSize.width: 320
                  clip: true

                  Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: Style.normalBorderWidth * 2
                    border.color: Color.accent
                    visible: root.current.pinned === modelData
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.persistDisplay("pinned", String(modelData))
                }
              }
            }
          }

          Text {
            visible: root.current.mode === "single"
            width: parent.width
            text: root.current.pinned === ""
              ? "No image chosen yet."
              : root.current.pinned.substring(root.current.pinned.lastIndexOf("/") + 1)
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          PanelSectionHeader {
            text: "SCALING"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            width: parent.width
            options: root.scalingLabels()
            value: root.scalingLabelFor(root.current.scaling)
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(v) { root.persistDisplay("scaling", root.scalingKeyFor(v)) }
          }
        }

        // ══════════════════════════════════════════════════════ shuffling

        Column {
          visible: root.tab === "shuffling"
          width: parent.width
          spacing: Style.space(12)

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

          Toggle {
            width: parent.width
            label: "Shuffle on unlock or wake"
            description: "Change wallpaper on unlock or screensaver exit rather than on a timer."
            checked: root.shuffleOnWake
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.persist("shuffleOnWake", !root.shuffleOnWake)
          }

          Toggle {
            // With each display configured separately this has no meaning:
            // every display already draws from its own folder.
            visible: !root.perDisplayConfig
            width: parent.width
            label: "Different image per display"
            description: "Off mirrors one image across every display."
            checked: root.perDisplay
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.persist("perDisplay", !root.perDisplay)
          }

          Text {
            width: parent.width
            text: "Displays set to Single keep their image and are left alone."
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ══════════════════════════════════════════════════════════ theme

        Column {
          visible: root.tab === "theme"
          width: parent.width
          spacing: Style.space(12)

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

          Toggle {
            width: parent.width
            label: "Light theme"
            description: "Generate a light palette instead of a dark one."
            checked: root.themeMode === "light"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.persist("themeMode", root.themeMode === "light" ? "dark" : "light")
          }

          Text {
            width: parent.width
            text: root.resolvedPrimary === ""
              ? "Built from your primary display."
              : "Built from " + root.resolvedPrimary + ", your primary display."
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ════════════════════════════════════════════ always visible

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
            text: "Rescan"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.rescanNow()
          }

          Button {
            text: "Generate theme"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.generateThemeNow()
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)

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
