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

  readonly property bool perDisplay: setting("perDisplay", true) === true
  readonly property int intervalSec: Math.max(0, Number(setting("intervalSec", 0)) || 0)

  // ---------------------------------------------------- per-display config
  //
  // Each display can carry its own folder, mode and scaling, held under
  // displayConfig keyed by output name. With perDisplayConfig off every
  // display reads the shared "all" entry instead, so the two arrangements are
  // one lookup rather than two code paths.
  //
  // Nothing migrates anything. A settings file written before this existed has
  // folder and recursive at the top level, and the lookup falls back to them,
  // so an install that never opens the panel keeps working and one that does
  // is upgraded by the first edit.
  readonly property bool perDisplayConfig: setting("perDisplayConfig", false) === true
  readonly property var displayConfig: setting("displayConfig", null)

  readonly property var defaultDisplayConfig: ({
    folder: "", recursive: true, mode: "shuffle", pinned: "", scaling: "zoom"
  })

  function rawConfigFor(name) {
    var dc = displayConfig
    if (!dc || typeof dc !== "object") return null
    var key = (perDisplayConfig && name) ? String(name) : "all"
    if (dc[key] && typeof dc[key] === "object") return dc[key]
    // A display plugged in after the others has no entry of its own yet;
    // "all" is a better starting point than an empty folder.
    if (dc.all && typeof dc.all === "object") return dc.all
    return null
  }

  function configFor(name) {
    var c = rawConfigFor(name)
    var pick = function(key, legacy) {
      if (c && c[key] !== undefined && c[key] !== null) return c[key]
      return legacy
    }
    var mode = String(pick("mode", "shuffle"))
    var scaling = String(pick("scaling", "zoom"))
    return {
      folder: expandHome(String(pick("folder", setting("folder", ""))).trim()),
      recursive: pick("recursive", setting("recursive", true)) === true,
      mode: mode === "single" ? "single" : "shuffle",
      pinned: expandHome(String(pick("pinned", "")).trim()),
      scaling: ["zoom", "fitHeight", "fitWidth", "actual"].indexOf(scaling) !== -1 ? scaling : "zoom"
    }
  }

  // Displays sharing a folder share a pool and a deal queue: dealing them
  // independently would let the same image land on both at once and would
  // undo the guarantee that every image shows before any repeats.
  // JSON rather than a delimiter: a folder path may contain any character, so
  // there is no separator that could be split back out again safely.
  function poolKeyFor(name) {
    var c = configFor(name)
    return c.folder === "" ? "" : JSON.stringify([c.folder, c.recursive])
  }

  function poolKeyFolder(key) { try { return JSON.parse(key)[0] } catch (e) { return "" } }
  function poolKeyRecursive(key) { try { return JSON.parse(key)[1] === true } catch (e) { return true } }

  // ------------------------------------------------------------------ scaling
  //
  // Only "zoom" maps onto a QML fillMode. Fitting a single axis needs the
  // image's natural size, so the other three are resolved to an explicit size
  // here and drawn with fillMode Stretch -- exact dimensions, aspect already
  // correct. Before the image has loaded its natural size reads as 0, so the
  // box is returned and the picture simply fills until it knows better.
  function scaledW(mode, natW, natH, boxW, boxH) {
    if (natW <= 0 || natH <= 0) return boxW
    if (mode === "actual") return natW
    if (mode === "fitHeight") return natW * (boxH / natH)
    return boxW
  }

  function scaledH(mode, natW, natH, boxW, boxH) {
    if (natW <= 0 || natH <= 0) return boxH
    if (mode === "actual") return natH
    if (mode === "fitWidth") return natH * (boxW / natW)
    return boxH
  }

  function distinctPoolKeys() {
    var names = screenNames()
    var seen = ({})
    var keys = []
    for (var i = 0; i < names.length; i++) {
      var k = poolKeyFor(names[i])
      if (k === "" || seen[k]) continue
      seen[k] = true
      keys.push(k)
    }
    return keys
  }


  // Theme generation. autoTheme drives it from every shuffle; the IPC command
  // below runs it once regardless, so the palette can be refreshed by hand
  // while auto stays off.
  readonly property bool shuffleOnWake: setting("shuffleOnWake", false) === true
  readonly property bool autoTheme: setting("autoTheme", false) === true
  readonly property string primaryDisplay: String(setting("primaryDisplay", "")).trim()
  readonly property string themeMode: String(setting("themeMode", "dark")) === "light" ? "light" : "dark"

  // Stamped in by PluginRegistry; the generator script ships beside this file.
  readonly property string sourceDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""
  // For the paths that still speak of a single folder -- the status IPC and
  // the bar tooltip. The primary display's is the one a single-folder setup
  // has anyway.
  readonly property string folder: configFor(primaryScreenName()).folder

  // Bindings may use folderMode freely. Imperative code must not: when the
  // shell injects `shell` after construction this and its inputs all
  // re-evaluate, and QML gives no ordering guarantee between a dependent
  // binding and an onXChanged handler, so a handler reading it could still see
  // the pre-change value. hasFolder() reads the settings directly.
  readonly property bool folderMode: hasFolder()

  // True when omawall owns the wallpaper on any display, whether that display
  // shuffles a folder or is pinned to one image.
  function hasFolder() {
    var names = screenNames()
    for (var i = 0; i < names.length; i++) {
      var c = configFor(names[i])
      if (c.folder !== "" || c.pinned !== "") return true
    }
    return false
  }

  // True when at least one display would actually change. A display in single
  // mode keeps its pinned image, so on an all-single desktop there is no next
  // image to fetch and the bar hides the button rather than offering a no-op.
  function hasShuffling() {
    var names = screenNames()
    for (var i = 0; i < names.length; i++) {
      var c = configFor(names[i])
      if (c.mode === "shuffle" && c.folder !== "") return true
    }
    return false
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

  property bool poolLoaded: false

  // Paths Qt refused to decode, kept as a set so each is only diagnosed once.
  // A file can be in the folder and still be undecodable: larger than Qt's
  // image allocation limit, truncated, or renamed to an extension it is not.
  // The scan cannot tell -- only the decoder can -- so the pool is filtered
  // here as failures surface rather than up front.
  property var badImages: ({})

  // poolKey -> [paths]. One entry per distinct folder in use, so two displays
  // pointed at the same folder share both the pool and the deal queue below.
  property var pools: ({})

  function poolFor(key) { return pools[key] || [] }

  function usablePoolFor(key) {
    var bad = badImages
    return poolFor(key).filter(function(p) { return !bad[p] })
  }

  // Every usable image across every pool, for the status readout. Deduped:
  // shared folders would otherwise be counted once per display using them.
  function usablePool() {
    var seen = ({})
    var out = []
    for (var key in pools) {
      var list = usablePoolFor(key)
      for (var i = 0; i < list.length; i++) {
        if (seen[list[i]]) continue
        seen[list[i]] = true
        out.push(list[i])
      }
    }
    return out
  }

  // Scans run one at a time through a single Process rather than one Process
  // per folder: the count is driven by how many displays are configured
  // differently, and a queue keeps that from becoming a fork storm.
  property var scanQueue: []
  property string scanningKey: ""

  function rescan() {
    // Clearing the skip list here makes a rescan the way to retry a file that
    // has since been repaired or replaced. The cost of being wrong is one
    // failed decode, after which it is skipped again.
    badImages = ({})
    if (scanProc.running) scanProc.running = false
    pools = ({})
    dealQueues = ({})
    poolLoaded = false
    if (!hasFolder()) return
    scanQueue = distinctPoolKeys()
    drainScans()
  }

  function drainScans() {
    if (scanProc.running) return
    if (!scanQueue.length) {
      poolLoaded = true
      if (hasFolder()) shuffle(displayedIsEmpty())
      return
    }
    var key = scanQueue[0]
    scanQueue = scanQueue.slice(1)
    scanningKey = key
    // Newline-delimited, not -print0: StdioCollector hands the output over as
    // a string, and NUL separators do not survive that conversion.
    scanProc.command = ["bash", "-c",
      "find -L " + Util.shellQuote(poolKeyFolder(key)) +
      (poolKeyRecursive(key) ? "" : " -maxdepth 1") +
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
        var next = ({})
        for (var k in root.pools) next[k] = root.pools[k]
        next[root.scanningKey] = found
        root.pools = next
      }
    }
    // Chained on exit, not on stdout: stdout can finish before the process
    // does, and starting the next scan while this one is still running would
    // drop it.
    onExited: root.drainScans()
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
  // poolKey -> remaining paths. One pass per folder, so a display pointed at a
  // small folder wraps often without dragging a larger one round with it.
  property var dealQueues: ({})

  function setQueue(key, list) {
    var next = ({})
    for (var k in dealQueues) next[k] = dealQueues[k]
    next[key] = list
    dealQueues = next
  }

  // The one place a repeat can still show up is across the wrap: the tail of a
  // pass and the head of the next are drawn independently, so an image can
  // land on the same display twice running. `avoid` is every image currently
  // on screen -- not just the primary's -- because on a two-monitor setup the
  // second draw is just as visible as the first, and guarding only the head
  // leaves it free to repeat.
  function refillQueue(key, avoid) {
    var next = shuffled(usablePoolFor(key))
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
    setQueue(key, next)
  }

  // Take `count` images off a pool's queue, refilling as it runs dry. Returns
  // fewer than asked for only when that pool is empty, which is the caller's
  // cue that there is nothing to show on those displays.
  function dealNext(key, count, avoid) {
    var avoidList = Array.isArray(avoid) ? avoid.slice() : (avoid ? [avoid] : [])
    var out = []
    while (out.length < count) {
      var queue = dealQueues[key] || []
      if (!queue.length) {
        // Mid-deal refills must also avoid what this deal has already handed
        // out, or one shuffle could put the same image on two displays.
        refillQueue(key, avoidList.concat(out))
        queue = dealQueues[key] || []
        if (!queue.length) break
      }
      queue = queue.slice()
      out.push(String(queue.shift()))
      setQueue(key, queue)
    }
    return out
  }

  // Refill a queue that has just run dry rather than waiting for the next deal
  // to need it. The same refill happens either way and the deal order is
  // unchanged; doing it now means the head of the next pass is decided ahead
  // of time, which is what lets the bar say which image each display is about
  // to get.
  function topUpQueues(picks) {
    var avoid = []
    for (var n in picks) {
      var p = String(picks[n] || "")
      if (p && avoid.indexOf(p) === -1) avoid.push(p)
    }
    var keys = distinctPoolKeys()
    for (var i = 0; i < keys.length; i++) {
      if ((dealQueues[keys[i]] || []).length) continue
      refillQueue(keys[i], avoid)
    }
  }

  // What the next advance would put on each shuffling display, peeked rather
  // than dealt. The grouping mirrors pickForScreens, and the queues are topped
  // up after every deal, so these heads are the images that call will hand out
  // rather than a guess at them.
  function nextPicks() {
    var names = screenNames()
    var out = ({})
    var groups = ({})
    var order = []
    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      if (configFor(name).mode !== "shuffle") continue
      var key = poolKeyFor(name)
      if (key === "") continue
      if (!groups[key]) { groups[key] = []; order.push(key) }
      groups[key].push(name)
    }

    for (var g = 0; g < order.length; g++) {
      var members = groups[order[g]]
      var queue = dealQueues[order[g]] || []
      if (!queue.length) continue
      for (var m = 0; m < members.length; m++)
        out[members[m]] = String(perDisplay ? queue[m % queue.length] : queue[0])
    }
    return out
  }

  function dropFromQueue(path) {
    var next = ({})
    for (var k in dealQueues) {
      next[k] = dealQueues[k].filter(function(p) { return p !== path })
    }
    dealQueues = next
  }

  // Deal one image per screen. Displays are grouped by the folder they draw
  // from and dealt a group at a time, so displays sharing a folder never get
  // the same image at once while displays on different folders are unaffected
  // by each other's pool running short.
  //
  // A display in single mode keeps its pinned image and consumes nothing from
  // any queue: that is how one monitor stays put while another rotates.
  function pickForScreens() {
    var names = screenNames()
    var picks = ({})
    if (!names.length) return picks

    // What is on screen now, kept out of the head of a refilled queue.
    var avoid = []
    for (var a = 0; a < names.length; a++) {
      var showing = String(displayedMap[names[a]] || "")
      if (showing && avoid.indexOf(showing) === -1) avoid.push(showing)
    }

    // Group the shuffling displays by pool; pin the single ones as we go.
    var groups = ({})
    var order = []
    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      var cfg = configFor(name)
      if (cfg.mode === "single") {
        if (cfg.pinned !== "") picks[name] = cfg.pinned
        continue
      }
      var key = poolKeyFor(name)
      if (key === "") continue
      if (!groups[key]) { groups[key] = []; order.push(key) }
      groups[key].push(name)
    }

    for (var g = 0; g < order.length; g++) {
      var poolKey = order[g]
      var members = groups[poolKey]
      if (!usablePoolFor(poolKey).length) continue

      // perDisplay only has meaning within a group: it asks whether these
      // displays mirror one image or each get their own.
      if (!perDisplay) {
        var one = dealNext(poolKey, 1, avoid)[0] || ""
        if (!one) continue
        for (var m = 0; m < members.length; m++) picks[members[m]] = one
        continue
      }

      var dealt = dealNext(poolKey, members.length, avoid)
      if (!dealt.length) continue
      for (var d = 0; d < members.length; d++) picks[members[d]] = dealt[d % dealt.length]
    }
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
    topUpQueues(picks)
    if (autoTheme) requestTheme(primaryPick(picks))
  }

  // The user-facing "next image". Distinct from shuffle(), which is also how a
  // pinned image and a freshly scanned folder are applied and so must still run
  // when nothing is set to shuffle.
  function advance() {
    if (!hasShuffling()) return
    shuffle(false)
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
    if (!hasFolder()) return
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
      var key = poolKeyFor(affected[j])
      for (var attempt = 0; attempt < 8; attempt++) {
        drawn = dealNext(key, 1, path)[0] || ""
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
    topUpQueues(picks)
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
    if (!shuffleOnWake || !hasFolder()) return
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

    // Added by this clone. The queue is only reshuffled once it empties, so
    // this deals the following image rather than re-randomising anything --
    // hence "next".
    function next(): string {
      if (!root.hasFolder()) return "no folder configured"
      if (!root.hasShuffling()) return "no display is set to shuffle"
      root.advance()
      return "ok"
    }

    // The older name for the same thing, kept because it is in people's key
    // binds.
    function shuffle(): string {
      return next()
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
        recursive: configFor(root.primaryScreenName()).recursive,
        perDisplay: root.perDisplay,
        intervalSec: root.intervalSec,
        poolSize: root.usablePool().length,
        skipped: Object.keys(root.badImages).length,
        queued: (root.dealQueues[root.poolKeyFor(root.primaryScreenName())] || []).length,
        screens: root.displayedMap,
        // What each shuffling display would get next, for the bar's tooltip.
        next: root.nextPicks(),
        shuffling: root.hasShuffling(),
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

  // Anything that changes which images belong in which pool. Debounced into
  // one rebuild: editing a folder field emits a change per keystroke, and a
  // single panel action can write several keys in a row.
  onDisplayConfigChanged: configReload.restart()
  onPerDisplayConfigChanged: configReload.restart()
  onFolderChanged: configReload.restart()
  onPerDisplayChanged: if (hasFolder()) shuffle(false)

  Timer {
    id: configReload
    interval: 250
    repeat: false
    onTriggered: {
      root.poolLoaded = false
      if (root.hasFolder()) root.rescan()
      else root.refreshBackground()
    }
  }

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
      readonly property string scaling: root.configFor(screenKey).scaling

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      // Zoom covers the screen, so it keeps the transparency it always had.
      // The fitting modes deliberately do not cover it, and the bars they
      // leave should read as part of the theme rather than as a hole.
      color: panel.scaling === "zoom" ? "transparent" : Color.background
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

      // Centred with an explicit size rather than anchored to fill: three of
      // the four scaling modes need a size the box cannot express. Anything
      // larger than the screen is cropped by the layer surface, which is what
      // "zoom" and an oversized "actual" both want.
      Image {
        id: base
        anchors.centerIn: parent
        width: root.scaledW(panel.scaling, implicitWidth, implicitHeight, parent.width, parent.height)
        height: root.scaledH(panel.scaling, implicitWidth, implicitHeight, parent.width, parent.height)
        source: root.imageUrl(panel.dispPath)
        fillMode: panel.scaling === "zoom" ? Image.PreserveAspectCrop : Image.Stretch
        asynchronous: true
        cache: true
        smooth: true
        mipmap: true
        onStatusChanged: {
          if (status === Image.Ready) root.noteBaseReady(panel.screenKey)
          else if (status === Image.Error) root.noteBadImage(panel.dispPath)
        }
      }

      Image {
        id: oldFrame
        anchors.centerIn: parent
        width: root.scaledW(panel.scaling, implicitWidth, implicitHeight, parent.width, parent.height)
        height: root.scaledH(panel.scaling, implicitWidth, implicitHeight, parent.width, parent.height)
        source: root.imageUrl(panel.oldPath)
        fillMode: panel.scaling === "zoom" ? Image.PreserveAspectCrop : Image.Stretch
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
          anchors.centerIn: parent
          width: root.scaledW(panel.scaling, implicitWidth, implicitHeight, parent.width, parent.height)
          height: root.scaledH(panel.scaling, implicitWidth, implicitHeight, parent.width, parent.height)
          source: root.imageUrl(panel.incPath)
          fillMode: panel.scaling === "zoom" ? Image.PreserveAspectCrop : Image.Stretch
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
