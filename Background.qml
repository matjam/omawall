import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// Cloned from omarchy.background and extended with folder mode.
//
// With no folder configured this behaves exactly like the stock plugin: one
// image for every display, driven by the ~/.local/state/omarchy/current/background
// symlink and the theme-transition IPC.
//
// With a folder configured, the image pool comes from that folder instead and
// every display is dealt its own random pick. Theme switches still apply their
// color payload — only the image choice is taken over — so `omarchy theme set`
// keeps recoloring the bar correctly.
//
// All transition state is per-screen (keyed by screen name) in both modes; the
// global mode simply fills every key with the same value. That keeps one code
// path for the reveal animation.
Item {
  id: root

  // Injected by the shell's service loader (see shell.qml ensureService).
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  // ------------------------------------------------------------- settings

  readonly property string pluginId: (manifest && manifest.id) || "matjam.omawall"
  readonly property var settings: lookupSettings(shell ? shell.shellConfig : null, pluginId)

  readonly property string folder: expandHome(String(setting("folder", "")).trim())
  readonly property bool recursive: setting("recursive", true) === true
  readonly property bool perDisplay: setting("perDisplay", true) === true
  readonly property int intervalSec: Math.max(0, Number(setting("intervalSec", 0)) || 0)

  // Theme generation. autoTheme drives it from every shuffle; the IPC command
  // below runs it once regardless, so the palette can be refreshed by hand
  // while auto stays off.
  readonly property bool autoTheme: setting("autoTheme", false) === true
  readonly property string primaryDisplay: String(setting("primaryDisplay", "")).trim()
  readonly property string themeMode: String(setting("themeMode", "dark")) === "light" ? "light" : "dark"

  // Stamped in by PluginRegistry; the generator script ships beside this file.
  readonly property string sourceDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""
  // Bindings may use folderMode freely. Imperative code must not: when the
  // shell injects `shell` after construction, `folder` and `folderMode` both
  // re-evaluate, and QML gives no ordering guarantee between a dependent
  // binding and an onXChanged handler. A handler that read folderMode could
  // therefore still see the pre-change value. hasFolder() reads the source.
  readonly property bool folderMode: folder !== ""

  function hasFolder() {
    return String(folder || "") !== ""
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // This plugin owns both a service and a bar widget, so its shell.json entry
  // can live in either bar.layout.* (where the settings panel writes it, via
  // setBarWidget) or plugins[] (where the clone originally enabled it). The
  // bar entry wins so the panel's edits are what take effect.
  function lookupSettings(config, id) {
    if (!config || !id) return ({})
    var sections = ["left", "center", "right"]
    if (config.bar && config.bar.layout) {
      for (var s = 0; s < sections.length; s++) {
        var list = config.bar.layout[sections[s]]
        if (!Array.isArray(list)) continue
        for (var i = 0; i < list.length; i++) {
          if (list[i] && String(list[i].id) === id) return list[i]
        }
      }
    }
    if (Array.isArray(config.plugins)) {
      for (var j = 0; j < config.plugins.length; j++) {
        if (config.plugins[j] && String(config.plugins[j].id) === id) return config.plugins[j]
      }
    }
    return ({})
  }

  function expandHome(path) {
    if (!path) return ""
    if (path === "~") return home
    if (path.indexOf("~/") === 0) return home + path.substring(1)
    return path
  }

  // ------------------------------------------------------- transition state

  // screenName -> path. Reassigned wholesale (never mutated) so the delegate
  // bindings below actually re-evaluate.
  property var displayedMap: ({})
  property var incomingMap: ({})
  property var oldMap: ({})

  // Global-mode bookkeeping, kept so the stock symlink/theme paths behave
  // identically to upstream.
  property string currentBackground: ""

  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1

  // Screen names whose base Image has finished loading the post-transition
  // picture. The incoming layer is only torn down once every screen is done,
  // otherwise a fast display drops back to the old image while a slow one is
  // still decoding.
  property var baseReady: ({})

  // Screen names whose *incoming* image has decoded, plus the gate that lets
  // every screen's incoming layer become visible at the same moment.
  property var incomingReady: ({})
  property bool revealArmed: false

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function screenNames() {
    var screens = Quickshell.screens || []
    var names = []
    for (var i = 0; i < screens.length; i++) names.push(String(screens[i].name))
    return names
  }

  // The display whose image stands for the whole desktop: it feeds the state
  // symlink the lock screen reads, and the palette the theme is built from. An
  // unset or disconnected primaryDisplay falls back to the first screen rather
  // than to nothing, so unplugging a monitor cannot leave either without a
  // source.
  function primaryScreenName() {
    var names = screenNames()
    if (!names.length) return ""
    if (primaryDisplay && names.indexOf(primaryDisplay) !== -1) return primaryDisplay
    // Sorted, not names[0]: Quickshell.screens comes back in a different order
    // between restarts, and an unsorted fallback would silently change which
    // display the theme is derived from. Alphabetical is arbitrary but stable,
    // which is the property that matters.
    return names.slice().sort()[0]
  }

  // ------------------------------------------------------------- image pool

  property var pool: []
  property bool poolLoaded: false

  function rescan() {
    if (!hasFolder()) {
      pool = []
      poolLoaded = false
      return
    }
    if (scanProc.running) scanProc.running = false
    // Newline-delimited, not -print0: StdioCollector hands the output over as
    // a string, and NUL separators do not survive that conversion.
    scanProc.command = ["bash", "-c",
      "find -L " + Util.shellQuote(folder) + (recursive ? "" : " -maxdepth 1") +
      " -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif'" +
      " -o -iname '*.bmp' -o -iname '*.webp' \\) 2>/dev/null"]
    scanProc.running = true
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = String(text || "").split("\n").filter(function(p) { return p !== "" })
        root.pool = found
        root.poolLoaded = true
        if (root.hasFolder()) root.shuffle(root.displayedIsEmpty())
      }
    }
  }

  function displayedIsEmpty() {
    for (var k in displayedMap) if (displayedMap[k]) return false
    return true
  }

  // Fisher-Yates over a copy, so a reshuffle never reorders `pool` itself.
  function shuffled(list) {
    var out = list.slice()
    for (var i = out.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var tmp = out[i]; out[i] = out[j]; out[j] = tmp
    }
    return out
  }

  // Deal one image per screen. With more images than screens every display
  // gets a distinct one; with fewer, picks repeat rather than leaving a
  // display black.
  function pickForScreens() {
    var names = screenNames()
    var picks = ({})
    if (!pool.length || !names.length) return picks
    if (!perDisplay) {
      var one = pool[Math.floor(Math.random() * pool.length)]
      for (var i = 0; i < names.length; i++) picks[names[i]] = one
      return picks
    }
    var bag = shuffled(pool)
    for (var j = 0; j < names.length; j++) picks[names[j]] = bag[j % bag.length]
    return picks
  }

  function shuffle(instant) {
    if (!hasFolder()) return
    if (!poolLoaded) { rescan(); return }
    var picks = pickForScreens()
    var empty = true
    for (var k in picks) { empty = false; break }
    if (empty) return
    applyPerScreen(picks, instant === true)
    syncCurrentLink(picks)
    if (autoTheme) requestTheme(primaryPick(picks))
  }

  function primaryPick(picks) {
    var name = primaryScreenName()
    return name ? String(picks[name] || "") : ""
  }

  // The lock screen and `omarchy theme bg current` both read the state
  // symlink, so keep it pointed at something we are actually showing.
  function syncCurrentLink(picks) {
    var primary = primaryPick(picks)
    if (!primary) return
    linkProc.command = ["ln", "-nsf", primary, currentBackgroundLink]
    linkProc.running = true
  }

  Process { id: linkProc }

  // ------------------------------------------------------ theme generation

  // The image the applied palette was built from, so a reshuffle that happens
  // to redeal the same picture does not re-run the generator.
  property string themedFrom: ""
  property string pendingThemeImage: ""

  function currentPrimaryImage() {
    var name = primaryScreenName()
    if (!name) return ""
    return String(incomingMap[name] || displayedMap[name] || "")
  }

  function requestTheme(image) {
    image = String(image || "")
    if (!image) return
    pendingThemeImage = image
    themeDebounce.restart()
  }

  // A shuffle reassigns several maps in a row and a settings edit can land as
  // two writes; both would otherwise start a generator run per change. Coalesce
  // into one run once the dust settles.
  Timer {
    id: themeDebounce
    interval: 300
    repeat: false
    onTriggered: root.runThemeGeneration(false)
  }

  function runThemeGeneration(force) {
    var image = pendingThemeImage || currentPrimaryImage()
    if (!image || !sourceDir) return
    if (!force && image === themedFrom) return
    // matugen plus the theme hooks take about a second. Re-arming instead of
    // queueing means a burst of shuffles ends in one run against the latest
    // image rather than a backlog of runs against stale ones.
    if (themeProc.running) { themeDebounce.restart(); return }
    themedFrom = image
    themeProc.command = [sourceDir + "/bin/omawall-generate-theme",
      "--image", image, "--mode", themeMode]
    themeProc.running = true
  }

  Process { id: themeProc }

  // Turning the toggle on, or changing what the palette is derived from, should
  // take effect immediately rather than at the next shuffle. force, because the
  // image has not changed -- only the instructions for reading it have.
  onAutoThemeChanged: if (autoTheme) { pendingThemeImage = ""; runThemeGeneration(true) }
  onThemeModeChanged: if (autoTheme) { pendingThemeImage = ""; runThemeGeneration(true) }
  onPrimaryDisplayChanged: if (autoTheme) { pendingThemeImage = ""; runThemeGeneration(true) }

  // --------------------------------------------------------- transitioning

  function beginTransition(nextDisplayed, nextIncoming, nextOld, instant) {
    backgroundVersion += 1
    revealStartedVersion = -1
    baseReady = ({})
    incomingReady = ({})
    revealArmed = false
    revealAnimation.stop()
    revealArmTimeout.stop()
    finishingTransition = false

    if (instant) {
      displayedMap = nextIncoming
      incomingMap = ({})
      oldMap = ({})
      revealProgress = 1
      return
    }

    displayedMap = nextDisplayed
    oldMap = nextOld
    incomingMap = nextIncoming
    revealProgress = 0
    revealArmTimeout.restart()
  }

  function applyPerScreen(picks, instant) {
    var names = screenNames()
    var nextOld = ({})
    var changed = false
    for (var i = 0; i < names.length; i++) {
      var n = names[i]
      nextOld[n] = displayedMap[n] || ""
      if (picks[n] !== displayedMap[n]) changed = true
    }
    if (!changed && !instant) return
    beginTransition(displayedMap, picks, nextOld, instant === true || displayedIsEmpty())
  }

  // Stock single-image path: fill every screen with the same value.
  function applyGlobal(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    currentBackground = finalPath

    var names = screenNames()
    var nextIncoming = ({})
    var nextOld = ({})
    var nextDisplayed = ({})
    for (var i = 0; i < names.length; i++) {
      var n = names[i]
      nextIncoming[n] = path
      nextOld[n] = fromPath || displayedMap[n] || ""
      nextDisplayed[n] = displayedMap[n] || ""
    }
    beginTransition(nextDisplayed, nextIncoming, nextOld, instant === true || displayedIsEmpty())
  }

  function refreshBackground() {
    if (hasFolder()) { shuffle(false); return }
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function setBackground(path, instant) {
    if (hasFolder()) { shuffle(instant); return }
    applyGlobal("", path, path, instant, false)
  }

  // ----------------------------------------------------------- theme colors

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Color.loadColors(pendingColorsRaw)
    Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  // In folder mode the theme's image is ignored but its palette is not: a
  // theme switch must still recolor the bar, so the payload is applied
  // immediately rather than being carried by a reveal that never starts.
  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    if (hasFolder()) {
      setPendingTheme(colorsB64, shellB64)
      applyPendingTheme()
      return
    }
    applyGlobal(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (revealProgress >= 1) applyPendingTheme()
  }

  // One shared revealProgress drives every screen, so the wipe may only start
  // once all of them have decoded their incoming image. Arming on the first
  // screen instead leaves the slower one hidden for the whole animation (its
  // layer is gated on revealArmed) and popping in at the end — a wipe on one
  // monitor and a hard cut on the other.
  function noteIncomingReady(name) {
    if (incomingReady[name]) return
    var next = ({})
    for (var k in incomingReady) next[k] = incomingReady[k]
    next[name] = true
    incomingReady = next
    armRevealIfReady()
  }

  function armRevealIfReady() {
    if (revealStartedVersion === backgroundVersion) return
    var names = screenNames()
    if (!names.length) return
    for (var i = 0; i < names.length; i++) if (!incomingReady[names[i]]) return
    armReveal()
  }

  function armReveal() {
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    revealArmTimeout.stop()
    revealArmed = true
    applyPendingTheme()
    revealAnimation.restart()
  }

  // A screen whose image fails to decode would otherwise hold the reveal
  // forever, leaving the old wallpaper up. Arm anyway after a grace period.
  Timer {
    id: revealArmTimeout
    interval: 1500
    repeat: false
    onTriggered: root.armReveal()
  }

  function noteBaseReady(name) {
    if (!finishingTransition) return
    if (baseReady[name]) return
    var next = ({})
    for (var k in baseReady) next[k] = baseReady[k]
    next[name] = true
    baseReady = next

    var names = screenNames()
    for (var i = 0; i < names.length; i++) if (!next[names[i]]) return
    incomingMap = ({})
    oldMap = ({})
    finishingTransition = false
  }

  // --------------------------------------------------------------- actions

  function openSelector() {
    // In folder mode the theme background switcher would list images we are
    // not using, so the desktop gesture reshuffles instead.
    if (hasFolder()) { rescan(); return }
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.hasFolder()) return
        root.applyGlobal("", String(text || "").trim(), String(text || "").trim(), false, false)
      }
    }
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function transition(fromPath: string, path: string): void {
      if (root.hasFolder()) { root.shuffle(false); return }
      root.applyGlobal(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }

    // Added by this clone.
    function shuffle(): string {
      if (!root.hasFolder()) return "no folder configured"
      root.shuffle(false)
      return "ok"
    }

    function rescan(): string {
      root.rescan()
      return "ok"
    }

    // Deliberately not gated on autoTheme: this is the manual path, for a
    // one-off palette refresh with the automatic toggle left off.
    function generateTheme(): string {
      if (!root.sourceDir) return "plugin source directory is unknown"
      var image = root.currentPrimaryImage()
      if (!image) return "no wallpaper is displayed yet"
      root.pendingThemeImage = image
      root.runThemeGeneration(true)
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        folder: root.folder,
        recursive: root.recursive,
        perDisplay: root.perDisplay,
        intervalSec: root.intervalSec,
        poolSize: root.pool.length,
        screens: root.displayedMap,
        autoTheme: root.autoTheme,
        themeMode: root.themeMode,
        primaryDisplay: root.primaryScreenName(),
        displays: root.screenNames()
      })
    }
  }

  // Poll the symlink so out-of-band changes (a theme switch that raced the
  // IPC, another tool writing the link) still land. Idle in folder mode.
  Timer {
    interval: 2000
    running: !root.folderMode
    repeat: true
    onTriggered: root.refreshBackground()
  }

  Timer {
    id: autoShuffleTimer
    interval: Math.max(1, root.intervalSec) * 1000
    running: root.folderMode && root.intervalSec > 0
    repeat: true
    onTriggered: root.shuffle(false)
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      var names = root.screenNames()
      var next = ({})
      for (var i = 0; i < names.length; i++) {
        var n = names[i]
        next[n] = root.incomingMap[n] || root.displayedMap[n] || ""
      }
      root.displayedMap = next
      root.baseReady = ({})
      root.finishingTransition = true
      root.revealProgress = 1
    }
  }

  onFolderChanged: {
    poolLoaded = false
    if (hasFolder()) rescan()
    else refreshBackground()
  }
  onRecursiveChanged: if (hasFolder()) rescan()
  onPerDisplayChanged: if (hasFolder()) shuffle(false)

  Connections {
    target: Quickshell
    // A newly-plugged display has no pick yet; deal it one.
    function onScreensChanged() {
      if (root.hasFolder()) root.shuffle(true)
      else root.refreshBackground()
    }
  }

  Component.onCompleted: {
    if (hasFolder()) rescan()
    else refreshBackground()
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      readonly property string screenKey: String(modelData.name)
      readonly property string dispPath: root.displayedMap[screenKey] || ""
      readonly property string incPath: root.incomingMap[screenKey] || ""
      readonly property string oldPath: root.oldMap[screenKey] || ""

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted.
      updatesEnabled: true

      // Report readiness unconditionally — not gated on revealProgress, which
      // is what previously starved the second monitor of its reveal.
      function reportIncomingReady() {
        if (!panel.incPath) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!panel.incPath || incomingFrame.status !== Image.Ready) return
          root.noteIncomingReady(panel.screenKey)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Image {
        id: base
        anchors.fill: parent
        source: root.imageUrl(panel.dispPath)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        onStatusChanged: if (status === Image.Ready) root.noteBaseReady(panel.screenKey)
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        source: root.imageUrl(panel.oldPath)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: panel.oldPath !== "" && root.revealProgress < 1
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: panel.incPath !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || root.revealArmed)
        layer.enabled: panel.incPath !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          source: root.imageUrl(panel.incPath)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.reportIncomingReady()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: panel
        function onIncPathChanged() {
          panel.reportIncomingReady()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
