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

  readonly property string imageSource: String(setting("imageSource", "folder")) === "pixabay" ? "pixabay" : "folder"
  readonly property string folder: String(setting("folder", ""))
  readonly property bool recursive: setting("recursive", true) === true

  readonly property string pxQuery: String(setting("pixabayQuery", ""))
  readonly property string pxOrientation: String(setting("pixabayOrientation", "horizontal"))
  readonly property string pxCategory: String(setting("pixabayCategory", ""))
  readonly property string pxOrder: String(setting("pixabayOrder", "popular"))
  readonly property bool pxEditorsChoice: setting("pixabayEditorsChoice", false) === true
  readonly property bool pxSafeSearch: setting("pixabaySafeSearch", true) === true

  readonly property string anyCategoryLabel: "Any category"
  readonly property var pixabayCategories: [
    "backgrounds", "nature", "places", "travel", "buildings", "computer",
    "science", "animals", "food", "music", "sports", "transportation",
    "business", "industry", "health", "people", "feelings", "education",
    "religion", "fashion"
  ]

  function categoryOptions() { return [anyCategoryLabel].concat(pixabayCategories) }
  function categoryValue() { return pxCategory === "" ? anyCategoryLabel : pxCategory }

  // -1 unknown, 0 missing, 1 stored. Same three-state treatment as matugen:
  // do not accuse the user of a missing key before the check has run.
  property int keyPresent: -1
  property string keyDraft: ""
  property var credits: ({})
  property string pixabayNote: ""

  // Pixabay serves a downscaled copy, not the original. Without full API
  // access that is 1280px on the longest edge, which on a wide display means
  // visible upscaling — worth saying outright rather than leaving someone to
  // wonder why their wallpaper looks soft.
  property int servedWidth: 0
  property int widestScreen: 0
  readonly property bool upscaling: servedWidth > 0 && widestScreen > servedWidth
  readonly property bool perDisplay: setting("perDisplay", true) === true
  readonly property int intervalSec: Math.max(0, Number(setting("intervalSec", 0)) || 0)
  readonly property bool shuffleOnWake: setting("shuffleOnWake", false) === true
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

  property int skipped: 0

  readonly property string statusLine: {
    if (imageSource === "pixabay") {
      if (keyPresent === 0) return "Add your API key to search Pixabay."
      if (poolSize < 0) return "Searching Pixabay…"
      if (poolSize === 0) return "No images matched that search."
      return poolSize + " image" + (poolSize === 1 ? "" : "s")
        + " available. Downloaded as they come up."
    }
    if (folder === "") return "No folder set — using the current theme's backgrounds."
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
        root.credits = data.credits || ({})
        root.servedWidth = Number(data.pixabayServedWidth || 0)
        root.widestScreen = Number(data.widestScreen || 0)
        var err = String(data.pixabayError || "")
        if (err !== "") root.pixabayNote = err
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
    if (root.folder !== "") cmd.push("--filename=" + root.folder + "/")
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
        root.persist("folder", picked)
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

  // ------------------------------------------------------------- pixabay

  // The shell stamps __sourceDir onto a service's manifest, but a bar widget
  // is handed no manifest at all, so the plugin directory has to come from
  // where this component was loaded from.
  readonly property string pixabayTool: {
    var dir = String(Qt.resolvedUrl("."))
    if (dir.indexOf("file://") === 0) dir = dir.substring(7)
    while (dir.length > 1 && dir.charAt(dir.length - 1) === "/") dir = dir.substring(0, dir.length - 1)
    return dir === "" ? "" : dir + "/bin/omawall-pixabay"
  }

  function openApiDocs() {
    Quickshell.execDetached(["xdg-open", "https://pixabay.com/api/docs/"])
  }

  function checkKey() {
    if (pixabayTool === "" || keyProbe.running) return
    keyProbe.command = [pixabayTool, "key-status"]
    keyProbe.running = true
  }

  Process {
    id: keyProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.keyPresent = String(text || "").trim() === "set" ? 1 : 0
    }
  }

  // Written through the tool rather than persisted with the other settings:
  // shell.json gets pasted into issues and forum posts when people ask for
  // help with their bar, and a key in there leaks by accident. The tool
  // stores it 0600 in ~/.config/omawall instead.
  function saveKey() {
    var key = String(keyDraft || "").trim()
    if (key === "" || pixabayTool === "" || keySaveProc.running) return
    keySaveProc.command = ["bash", "-c",
      "printf '%s' \"$OMAWALL_KEY\" | " + Util.shellQuote(pixabayTool) + " set-key"]
    keySaveProc.environment = ({ "OMAWALL_KEY": key })
    keySaveProc.running = true
  }

  Process {
    id: keySaveProc
    // The key goes through the environment, not argv, so it never appears in
    // another user's `ps` output.
    onExited: function(code, status) {
      root.keyDraft = ""
      keyField.text = ""
      root.checkKey()
      if (code === 0) {
        root.pixabayNote = "API key saved."
        root.syncNow()
      } else {
        root.pixabayNote = "Could not save the API key."
      }
    }
  }

  function syncNow() {
    if (pixabayTool === "" || syncProc.running) return
    root.pixabayNote = "Searching Pixabay…"
    syncProc.command = ["omarchy-shell", "-q", "background", "rescan"]
    syncProc.running = true
    refreshTimer.restart()
  }

  Process { id: syncProc }

  function clearPixabayCache() {
    if (pixabayTool === "" || clearProc.running) return
    clearProc.command = [pixabayTool, "clear"]
    clearProc.running = true
  }

  Process {
    id: clearProc
    onExited: {
      root.pixabayNote = "Cache cleared."
      root.syncNow()
    }
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
  onFolderChanged: if (!folderEdited && folderField) folderField.text = folder

  onOpenedChanged: if (opened) {
    folderEdited = false
    folderField.text = root.folder
    pixabayNote = ""
    refreshStatus()
    checkKey()
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
          text: "WALLPAPER SOURCE"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        ButtonGroup {
          width: parent.width
          options: ["Folder", "Pixabay"]
          value: root.imageSource === "pixabay" ? "Pixabay" : "Folder"
          foreground: root.fg
          fontFamily: root.fontFamily
          onChanged: function(v) {
            root.persist("imageSource", String(v).toLowerCase())
            root.pixabayNote = ""
          }
        }

        // ------------------------------------------------------------ folder

        Row {
          visible: root.imageSource === "folder"
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: folderField
            width: parent.width - browseButton.implicitWidth - parent.spacing
            foreground: root.fg
            placeholderText: "~/Pictures/wallpapers"
            // Only a keystroke counts as an edit. Assigning text from the
            // setting below must not arm the write-back.
            onTextChanged: if (activeFocus) root.folderEdited = true
            onAccepted: {
              root.folderEdited = false
              root.persist("folder", text.trim())
            }
            // editingFinished fires on any focus loss, including the panel
            // being dismissed because the file dialog took focus. Writing back
            // unconditionally there is what made Browse… look broken: the field
            // still held the old path and overwrote the one just chosen.
            onEditingFinished: {
              if (!root.folderEdited) return
              root.folderEdited = false
              if (text.trim() !== root.folder) root.persist("folder", text.trim())
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
          visible: root.imageSource === "folder" && root.folder !== ""
          text: "Clear folder (use theme backgrounds)"
          bordered: true
          leftAlign: true
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.persist("folder", "")
        }

        Toggle {
          visible: root.imageSource === "folder"
          width: parent.width
          label: "Search subfolders"
          description: "Include images nested below the chosen folder."
          checked: root.recursive
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.persist("recursive", !root.recursive)
        }

        // ----------------------------------------------------------- pixabay

        Column {
          visible: root.imageSource === "pixabay"
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: keyField
              width: parent.width - saveKeyButton.implicitWidth - parent.spacing
              foreground: root.fg
              password: true
              placeholderText: root.keyPresent === 1 ? "API key stored — type to replace" : "Your Pixabay API key"
              onTextChanged: root.keyDraft = text
              onAccepted: root.saveKey()
            }

            Button {
              id: saveKeyButton
              text: "Save"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.saveKey()
            }
          }

          Button {
            width: parent.width
            leftAlign: true
            bordered: true
            text: "Get a free API key at pixabay.com/api/docs"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.openApiDocs()
          }

          TextField {
            width: parent.width
            foreground: root.fg
            text: root.pxQuery
            placeholderText: "Search term — empty for most popular"
            onAccepted: root.persist("pixabayQuery", text.trim())
            onEditingFinished: if (text.trim() !== root.pxQuery) root.persist("pixabayQuery", text.trim())
          }

          Dropdown {
            width: parent.width
            label: "Category"
            options: root.categoryOptions()
            value: root.categoryValue()
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(v) {
              root.persist("pixabayCategory", v === root.anyCategoryLabel ? "" : String(v))
            }
          }

          Dropdown {
            width: parent.width
            label: "Orientation"
            options: ["horizontal", "vertical", "all"]
            value: root.pxOrientation
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(v) { root.persist("pixabayOrientation", String(v)) }
          }

          Dropdown {
            width: parent.width
            label: "Order"
            options: ["popular", "latest"]
            value: root.pxOrder
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(v) { root.persist("pixabayOrder", String(v)) }
          }

          Toggle {
            width: parent.width
            label: "Editor's Choice only"
            description: "Restrict to images Pixabay has picked out."
            checked: root.pxEditorsChoice
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.persist("pixabayEditorsChoice", !root.pxEditorsChoice)
          }

          Toggle {
            width: parent.width
            label: "Safe search"
            description: "Exclude results unsuitable for all ages."
            checked: root.pxSafeSearch
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.persist("pixabaySafeSearch", !root.pxSafeSearch)
          }

          Text {
            visible: root.upscaling
            width: parent.width
            text: "Pixabay serves at most " + root.servedWidth + "px wide; your "
              + "widest display is " + root.widestScreen + "px, so these will "
              + "be upscaled. Full API access raises it to 1920px."
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.pixabayNote !== ""
            width: parent.width
            text: root.pixabayNote
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "Search now"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.syncNow()
            }

            Button {
              text: "Clear cache"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.clearPixabayCache()
            }
          }

          // Pixabay's terms require showing users where images came from, so
          // this is attribution rather than decoration.
          Text {
            width: parent.width
            text: "Images from Pixabay. Only the minimum size your largest "
              + "display needs is requested, and each is downloaded when it "
              + "first comes up rather than in bulk."
            color: Qt.darker(root.fg, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator {}

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

        Toggle {
          width: parent.width
          // Kept short deliberately: the Toggle label elides rather than wraps,
          // and the longer wording was cut off mid-word at panel width.
          label: "Shuffle on unlock or wake"
          description: "Change wallpaper on unlock or screensaver exit rather than on a timer."
          checked: root.shuffleOnWake
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.persist("shuffleOnWake", !root.shuffleOnWake)
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
                // A Pixabay file is named after its numeric id, which tells a
                // reader nothing. Credit the photographer instead, which their
                // terms ask for anyway.
                var credit = root.credits ? root.credits[p] : null
                out.push({
                  screen: name,
                  file: credit && credit.user
                    ? credit.user + " · Pixabay"
                    : p.substring(p.lastIndexOf("/") + 1)
                })
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
