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

  // Where the image pool comes from: a local folder, or a cached Pixabay
  // search. Both end up as a list of local paths, so everything downstream --
  // the deal queue, per-display picks, theme generation, skipping images that
  // will not decode -- is shared rather than duplicated per source.
  readonly property string imageSource: String(setting("imageSource", "folder")) === "pixabay" ? "pixabay" : "folder"

  readonly property string folder: expandHome(String(setting("folder", "")).trim())
  readonly property bool recursive: setting("recursive", true) === true
  readonly property bool perDisplay: setting("perDisplay", true) === true
  readonly property int intervalSec: Math.max(0, Number(setting("intervalSec", 0)) || 0)

  readonly property string pxQuery: String(setting("pixabayQuery", "")).trim()
  readonly property string pxImageType: String(setting("pixabayImageType", "photo"))
  readonly property string pxOrientation: String(setting("pixabayOrientation", "horizontal"))
  readonly property string pxCategory: String(setting("pixabayCategory", "")).trim()
  readonly property int pxMinWidth: Math.max(0, Number(setting("pixabayMinWidth", 1920)) || 0)
  readonly property int pxMinHeight: Math.max(0, Number(setting("pixabayMinHeight", 1080)) || 0)
  readonly property bool pxEditorsChoice: setting("pixabayEditorsChoice", false) === true
  readonly property bool pxSafeSearch: setting("pixabaySafeSearch", true) === true
  readonly property string pxOrder: String(setting("pixabayOrder", "popular")) === "latest" ? "latest" : "popular"
  readonly property int pxCacheMB: Math.max(64, Number(setting("pixabayCacheMB", 512)) || 512)

  // The flags every omawall-pixabay call needs. Kept in one place because the
  // search they describe is also what the cache is keyed on -- a caller that
  // passed a different set would silently address a different cache entry.
  // Pixabay's min_width filters on the *original* image, but the API only ever
  // serves a downscaled copy -- 1280px on the longest edge for an ordinary
  // key, 1920px with full API access. Asking for originals wider than that
  // narrows the results without improving a single delivered pixel. Below the
  // cap the filter still earns its place by excluding originals too small to
  // fill even that.
  readonly property int maxServedWidth: 1920

  function widestScreen() {
    var screens = Quickshell.screens || []
    var w = 0
    for (var i = 0; i < screens.length; i++) w = Math.max(w, Number(screens[i].width) || 0)
    return w
  }

  function autoMinWidth() {
    return Math.min(widestScreen() || 1920, maxServedWidth)
  }

  function autoMinHeight() {
    var screens = Quickshell.screens || []
    var h = 0
    for (var i = 0; i < screens.length; i++) h = Math.max(h, Number(screens[i].height) || 0)
    return Math.min(h || 1080, Math.round(maxServedWidth * 9 / 16))
  }

  function pixabayArgs() {
    return ["--query", pxQuery,
            "--image-type", pxImageType,
            "--orientation", pxOrientation,
            "--category", pxCategory,
            "--min-width", String(pxMinWidth > 0 ? pxMinWidth : autoMinWidth()),
            "--min-height", String(pxMinHeight > 0 ? pxMinHeight : autoMinHeight()),
            "--editors-choice", pxEditorsChoice ? "true" : "false",
            "--safesearch", pxSafeSearch ? "true" : "false",
            "--order", pxOrder,
            "--budget-mb", String(pxCacheMB)]
  }

  function pixabayTool() { return sourceDir + "/bin/omawall-pixabay" }

  // Theme generation. autoTheme drives it from every shuffle; the IPC command
  // below runs it once regardless, so the palette can be refreshed by hand
  // while auto stays off.
  readonly property bool shuffleOnWake: setting("shuffleOnWake", false) === true
  readonly property bool autoTheme: setting("autoTheme", false) === true
  readonly property string primaryDisplay: String(setting("primaryDisplay", "")).trim()
  readonly property string themeMode: String(setting("themeMode", "dark")) === "light" ? "light" : "dark"

  // Stamped in by PluginRegistry; the generator script ships beside this file.
  readonly property string sourceDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""
  // True when omawall owns the wallpaper rather than deferring to Omarchy's
  // theme backgrounds. Bindings may use it freely. Imperative code must not:
  // when the shell injects `shell` after construction this and its inputs all
  // re-evaluate, and QML gives no ordering guarantee between a dependent
  // binding and an onXChanged handler, so a handler reading it could still see
  // the pre-change value. hasSource() reads the settings directly.
  readonly property bool folderMode: imageSource === "pixabay" || folder !== ""

  function hasSource() {
    if (String(setting("imageSource", "folder")) === "pixabay") return true
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

  // Paths Qt refused to decode, kept as a set so each is only diagnosed once.
  // A file can be in the folder and still be undecodable: larger than Qt's
  // image allocation limit, truncated, or renamed to an extension it is not.
  // The scan cannot tell -- only the decoder can -- so the pool is filtered
  // here as failures surface rather than up front.
  property var badImages: ({})

  function usablePool() {
    var bad = badImages
    return pool.filter(function(p) { return !bad[p] })
  }

  function rescan() {
    // Clearing the skip list here makes a rescan the way to retry a file that
    // has since been repaired or replaced. The cost of being wrong is one
    // failed decode, after which it is skipped again.
    badImages = ({})
    if (!hasSource()) {
      pool = []
      poolLoaded = false
      return
    }
    if (scanProc.running) scanProc.running = false

    if (imageSource === "pixabay") {
      if (!sourceDir) return
      // sync is cheap and idempotent: it honours Pixabay's 24-hour caching
      // requirement itself and returns immediately from cache, so this can run
      // on every rescan without turning into request traffic.
      // sync first so its report is available, then the pool. Its stdout is
      // captured rather than discarded: it carries the resolution Pixabay
      // actually served, which the panel needs to warn about upscaling.
      pixabaySyncProc.command = [pixabayTool(), "sync"].concat(pixabayArgs())
      pixabaySyncProc.running = true
      return
    }

    // Newline-delimited, not -print0: StdioCollector hands the output over as
    // a string, and NUL separators do not survive that conversion.
    scanProc.command = ["bash", "-c",
      "find -L " + Util.shellQuote(folder) + (recursive ? "" : " -maxdepth 1") +
      " -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif'" +
      " -o -iname '*.bmp' -o -iname '*.webp' \\) 2>/dev/null"]
    scanProc.running = true
  }

  // The longest edge Pixabay served for this search, 0 until a sync reports
  // it. Compared against the displays to warn about upscaling.
  property int pixabayServedWidth: 0
  property string pixabayError: ""

  Process {
    id: pixabaySyncProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") {
          try {
            var data = JSON.parse(raw)
            root.pixabayServedWidth = Number(data.servedWidth || 0)
          } catch (e) { /* the pool step below reports the real problem */ }
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        root.pixabayError = err.replace(/^omawall-pixabay:\s*/, "")
        if (err !== "") console.warn("omawall: " + err)
      }
    }
    // Whatever sync managed, list what is cached: a failed refresh should
    // still leave yesterday's results usable rather than an empty desktop.
    onExited: {
      scanProc.command = [root.pixabayTool(), "pool"].concat(root.pixabayArgs())
      scanProc.running = true
    }
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = String(text || "").split("\n").filter(function(p) { return p !== "" })
        root.pool = found
        root.poolLoaded = true
        // The queue describes a pass over the previous pool; a new scan may
        // have added or removed files, so start the pass again rather than
        // deal paths that are no longer there.
        root.dealQueue = []
        if (root.imageSource === "pixabay") root.loadCredits()
        if (root.hasSource()) root.shuffle(root.displayedIsEmpty())
      }
    }
  }

  // path -> { user, pageURL }. Pixabay's terms require showing where an image
  // came from, so the panel needs the photographer for whatever is on screen.
  property var credits: ({})

  function loadCredits() {
    if (imageSource !== "pixabay" || !sourceDir) { credits = ({}); return }
    if (creditsProc.running) return
    creditsProc.command = [pixabayTool(), "credits"].concat(pixabayArgs())
    creditsProc.running = true
  }

  Process {
    id: creditsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try { root.credits = JSON.parse(raw) } catch (e) { root.credits = ({}) }
      }
    }
  }

  function creditFor(path) {
    var c = credits[String(path || "")]
    return c ? c : null
  }

  // screenName -> credit, for what is on screen right now.
  function creditsForDisplayed() {
    var out = ({})
    if (imageSource !== "pixabay") return out
    var names = screenNames()
    for (var i = 0; i < names.length; i++) {
      var c = creditFor(displayedMap[names[i]])
      if (c) out[names[i]] = c
    }
    return out
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

  // ------------------------------------------------------------- deal order

  // What is left of the current pass through the pool. Images are dealt off
  // the front and the queue is reshuffled only once it empties, so a folder of
  // 500 wallpapers shows all 500 before any of them comes round again.
  //
  // Re-randomising the whole pool on every shuffle -- which is what this used
  // to do -- is sampling with replacement: over 500 shuffles you would expect
  // to see roughly a third of the folder not at all, and some images three or
  // four times. The randomness feels worse than it is, because a repeat two
  // wallpapers apart is much more noticeable than an even rotation.
  property var dealQueue: []

  // The one place a repeat can still show up is across the wrap: the tail of a
  // pass and the head of the next are drawn independently, so an image can
  // land on the same display twice running. `avoid` is every image currently
  // on screen -- not just the primary's -- because on a two-monitor setup the
  // second draw is just as visible as the first, and guarding only the head
  // leaves it free to repeat.
  function refillQueue(avoid) {
    var next = shuffled(usablePool())
    var avoidList = Array.isArray(avoid) ? avoid : (avoid ? [avoid] : [])

    // Guard the leading positions a deal will consume, and only as far as the
    // pool can actually supply alternatives. A pool no larger than the number
    // of displays has nothing to swap in, and must repeat.
    var guard = Math.min(avoidList.length, Math.max(0, next.length - avoidList.length))
    for (var i = 0; i < guard; i++) {
      if (avoidList.indexOf(next[i]) === -1) continue
      for (var j = guard; j < next.length; j++) {
        if (avoidList.indexOf(next[j]) !== -1) continue
        var tmp = next[i]; next[i] = next[j]; next[j] = tmp
        break
      }
    }
    dealQueue = next
  }

  // Take `count` images off the queue, refilling as it runs dry. Returns fewer
  // than asked for only when the pool is empty, which is the caller's cue that
  // there is nothing to show.
  function dealNext(count, avoid) {
    var avoidList = Array.isArray(avoid) ? avoid.slice() : (avoid ? [avoid] : [])
    var out = []
    while (out.length < count) {
      if (!dealQueue.length) {
        // Mid-deal refills must also avoid what this deal has already handed
        // out, or one shuffle could put the same image on two displays.
        refillQueue(avoidList.concat(out))
        if (!dealQueue.length) break
      }
      var queue = dealQueue.slice()
      out.push(String(queue.shift()))
      dealQueue = queue
    }
    return out
  }

  // Any of these changes the set of images the pool should contain, so the
  // pool is rebuilt rather than left describing the previous search. Debounced
  // because editing a query field emits one change per keystroke, and each
  // rebuild would otherwise be a sync call.
  onImageSourceChanged: sourceReload.restart()
  onPxQueryChanged: sourceReload.restart()
  onPxImageTypeChanged: sourceReload.restart()
  onPxOrientationChanged: sourceReload.restart()
  onPxCategoryChanged: sourceReload.restart()
  onPxMinWidthChanged: sourceReload.restart()
  onPxMinHeightChanged: sourceReload.restart()
  onPxEditorsChoiceChanged: sourceReload.restart()
  onPxSafeSearchChanged: sourceReload.restart()
  onPxOrderChanged: sourceReload.restart()

  Timer {
    id: sourceReload
    interval: 700
    repeat: false
    onTriggered: {
      root.poolLoaded = false
      root.rescan()
    }
  }

  function dropFromQueue(path) {
    if (!dealQueue.length) return
    dealQueue = dealQueue.filter(function(p) { return p !== path })
  }

  // Deal one image per screen. With more images than screens every display
  // gets a distinct one; with fewer, the queue wraps mid-deal and picks repeat
  // rather than leaving a display black.
  function pickForScreens() {
    var names = screenNames()
    var picks = ({})
    if (!names.length || !usablePool().length) return picks

    var avoid = []
    for (var a = 0; a < names.length; a++) {
      var showing = String(displayedMap[names[a]] || "")
      if (showing && avoid.indexOf(showing) === -1) avoid.push(showing)
    }

    if (!perDisplay) {
      var one = dealNext(1, avoid)[0] || ""
      if (!one) return picks
      for (var i = 0; i < names.length; i++) picks[names[i]] = one
      return picks
    }

    var dealt = dealNext(names.length, avoid)
    if (!dealt.length) return picks
    for (var j = 0; j < names.length; j++) picks[names[j]] = dealt[j % dealt.length]
    return picks
  }

  function shuffle(instant) {
    if (!hasSource()) return
    if (!poolLoaded) { rescan(); return }
    var picks = pickForScreens()
    var empty = true
    for (var k in picks) { empty = false; break }
    if (empty) return

    // A Pixabay pool names files that may not be downloaded yet -- the whole
    // point of caching metadata rather than half a gigabyte of images. Ensure
    // the chosen ones exist before showing them, since an absent file would
    // otherwise reach the Image as a decode failure and get marked bad.
    if (imageSource === "pixabay" && sourceDir) {
      fetchThenApply(picks, instant === true)
      return
    }
    applyPicks(picks, instant === true)
  }

  function applyPicks(picks, instant) {
    applyPerScreen(picks, instant === true)
    syncCurrentLink(picks)
    if (autoTheme) requestTheme(primaryPick(picks))
  }

  property var pendingPicks: null
  property bool pendingPicksInstant: false

  function fetchThenApply(picks, instant) {
    // A shuffle that lands while a download is in flight replaces it: the
    // newer intent is the one the user is waiting on, and the older picks are
    // about to be superseded on screen anyway.
    pendingPicks = picks
    pendingPicksInstant = instant === true
    if (fetchProc.running) fetchProc.running = false

    var paths = []
    for (var name in picks) if (picks[name]) paths.push(String(picks[name]))
    if (!paths.length) return

    fetchProc.command = [pixabayTool(), "fetch"].concat(paths).concat(pixabayArgs())
    fetchProc.running = true
  }

  Process {
    id: fetchProc
    // Apply regardless of exit code. A download that failed leaves the file
    // missing, which the decode-failure path already handles by skipping that
    // image and re-dealing the display -- one mechanism, not two.
    onExited: {
      if (!root.pendingPicks) return
      var picks = root.pendingPicks
      root.pendingPicks = null
      root.applyPicks(picks, root.pendingPicksInstant)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") console.warn("omawall: " + err)
      }
    }
  }

  function primaryPick(picks) {
    var name = primaryScreenName()
    return name ? String(picks[name] || "") : ""
  }

  // ------------------------------------------------------- undecodable images

  function noteBadImage(path) {
    path = String(path || "")
    if (!path || badImages[path]) return
    var next = ({})
    for (var k in badImages) next[k] = badImages[k]
    next[path] = true
    badImages = next
    dropFromQueue(path)
    console.warn("omawall: skipping image that could not be decoded: " + path)
    replaceBadImage(path)
  }

  // Re-deal only the displays holding the bad image. Reshuffling everything
  // would punish the other monitors for one unreadable file, and the swap is
  // instant because there is nothing worth animating away from -- the failed
  // image was never visible.
  function replaceBadImage(path) {
    if (!hasSource()) return
    var usable = usablePool()
    if (!usable.length) return

    var names = screenNames()
    var picks = ({})
    var inUse = ({})
    var affected = []

    for (var i = 0; i < names.length; i++) {
      var n = names[i]
      var cur = String(incomingMap[n] || displayedMap[n] || "")
      if (!cur || cur === path || badImages[cur]) affected.push(n)
      else { picks[n] = cur; inUse[cur] = true }
    }
    if (!affected.length) return

    for (var j = 0; j < affected.length; j++) {
      // Drawn from the same queue as an ordinary deal, so a decode failure
      // costs the pass one position rather than reaching outside the rotation.
      var chosen = ""
      var drawn = ""
      for (var attempt = 0; attempt < 8; attempt++) {
        drawn = dealNext(1, path)[0] || ""
        if (!drawn) break
        if (!perDisplay || !inUse[drawn]) { chosen = drawn; break }
      }
      // Fewer usable images than displays: repeating one beats a black screen.
      if (!chosen) chosen = drawn
      if (!chosen) return
      picks[affected[j]] = chosen
      inUse[chosen] = true
    }

    // A replacement that also fails to decode lands back here, but each pass
    // removes one path from the pool, so the retries are bounded by its size.
    applyPerScreen(picks, true)
    syncCurrentLink(picks)
    if (autoTheme) requestTheme(primaryPick(picks))
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

  // ------------------------------------------------------------ wake shuffle

  // Shuffling on a timer is the wrong shape when autoTheme is on: applying a
  // theme retints every app Omarchy themes, which stalls the compositor for a
  // moment. Mid-sentence or mid-game that reads as a freeze. Tying the shuffle
  // to unlock and screensaver dismissal instead puts the stall where the user
  // is already waiting to resume, and where a new wallpaper is what they
  // expect to see anyway.
  //
  // These are bindings rather than one-shot lookups: services are created
  // lazily, and the shell reassigns its whole service map when one lands, so
  // they re-evaluate as soon as omarchy.lock and omarchy.idle exist.
  readonly property var lockService: (shell && shell.serviceFor) ? shell.serviceFor("omarchy.lock") : null
  readonly property var idleService: (shell && shell.serviceFor) ? shell.serviceFor("omarchy.idle") : null

  readonly property bool sessionLocked: lockService ? lockService.locked === true : false
  readonly property bool screensaverShowing: idleService ? Number(idleService.screensaverWindowCount) > 0 : false

  onSessionLockedChanged: if (!sessionLocked) wakeShuffle()
  onScreensaverShowingChanged: if (!screensaverShowing) wakeShuffle()

  function wakeShuffle() {
    if (!shuffleOnWake || !hasSource()) return
    wakeDebounce.restart()
  }

  // Dismissing a screensaver that had already escalated to a lock clears both
  // flags a moment apart, which is one wake but two signals.
  Timer {
    id: wakeDebounce
    interval: 400
    repeat: false
    onTriggered: root.shuffle(false)
  }

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
    if (hasSource()) { shuffle(false); return }
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function setBackground(path, instant) {
    if (hasSource()) { shuffle(instant); return }
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
    if (hasSource()) {
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
    if (hasSource()) { rescan(); return }
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
        if (root.hasSource()) return
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
      if (root.hasSource()) { root.shuffle(false); return }
      root.applyGlobal(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }

    // Added by this clone.
    function shuffle(): string {
      if (!root.hasSource()) return "no folder configured"
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
        imageSource: root.imageSource,
        pixabayServedWidth: root.pixabayServedWidth,
        widestScreen: root.widestScreen(),
        pixabayError: root.pixabayError,
        folder: root.folder,
        recursive: root.recursive,
        perDisplay: root.perDisplay,
        intervalSec: root.intervalSec,
        poolSize: root.usablePool().length,
        skipped: Object.keys(root.badImages).length,
        queued: root.dealQueue.length,
        credits: root.creditsForDisplayed(),
        screens: root.displayedMap,
        shuffleOnWake: root.shuffleOnWake,
        // Whether the lock and idle services were found. Without them the wake
        // shuffle silently never fires, which is otherwise indistinguishable
        // from the setting not working.
        wakeSourcesReady: !!root.lockService && !!root.idleService,
        sessionLocked: root.sessionLocked,
        screensaverShowing: root.screensaverShowing,
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
    if (hasSource()) rescan()
    else refreshBackground()
  }
  onRecursiveChanged: if (hasSource()) rescan()
  onPerDisplayChanged: if (hasSource()) shuffle(false)

  Connections {
    target: Quickshell
    // A newly-plugged display has no pick yet; deal it one.
    function onScreensChanged() {
      if (root.hasSource()) root.shuffle(true)
      else root.refreshBackground()
    }
  }

  Component.onCompleted: {
    if (hasSource()) rescan()
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
        onStatusChanged: {
          if (status === Image.Ready) root.noteBaseReady(panel.screenKey)
          else if (status === Image.Error) root.noteBadImage(panel.dispPath)
        }
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
          // An incoming image that errors never reports ready, so the reveal
          // would sit armed until its timeout and then commit a blank layer.
          // Swap the path out instead.
          onStatusChanged: {
            if (status === Image.Error) root.noteBadImage(panel.incPath)
            else panel.reportIncomingReady()
          }
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
