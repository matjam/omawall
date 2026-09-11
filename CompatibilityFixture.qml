import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property int step: 0
  property bool activeReadUpdateIssued: false
  property bool finished: false
  property string home: Quickshell.env("HOME")
  property string configPath: home + "/.config/omarchy/shell.json"
  property string resultPath: home + "/result"

  ShellSettings {
    id: settings
    pluginId: "matjam.omawall"
  }

  LocalPath { id: localPath }
  ServiceVersion { id: serviceVersion }
  WakeDescription { id: wakeDescription }
  QtObject {
    id: shellStub
    property var service: null
    property string requestedModule: ""

    function serviceFor(moduleName) {
      requestedModule = moduleName
      return service
    }
  }

  Process { id: writer }
  Process {
    id: terminator
    command: ["/bin/sh", "-c", "kill -TERM \"$PPID\""]
  }

  Timer {
    id: timeout
    interval: 10000
    onTriggered: fail("timed out at step " + root.step + ", source=" + root.source()
      + ", active-read-update=" + root.activeReadUpdateIssued)
  }

  function write(command) {
    writer.command = ["/bin/sh", "-c", command]
    writer.running = true
  }

  function source() {
    return settings.settings.source === undefined ? "" : String(settings.settings.source)
  }

  function advance(loadFailed) {
    if (finished || writer.running) return
    if (step === 0 && source() === "bar") {
      step = 1
      write("printf '%s' '{\"version\":1,\"plugins\":[{\"id\":\"matjam.omawall\",\"source\":\"service\"}]}' > '" + configPath + "'")
    } else if (step === 1 && source() === "service") {
      step = 2
      write("printf '{' > '" + configPath + "'")
    } else if (step === 2 && source() === "service") {
      step = 3
      write("rm -f '" + configPath + "'")
    } else if (step === 3 && loadFailed && source() === "service") {
      step = 4
      write("printf '%s' '{\"version\":1,\"plugins\":[{\"id\":\"matjam.omawall\",\"source\":\"atomic\"}]}' > '" + configPath + ".next' && mv '" + configPath + ".next' '" + configPath + "'")
    } else if (step === 4 && source() === "atomic") {
      step = 5
      write("rm -f '" + configPath + "'")
    } else if (step === 5 && loadFailed && source() === "atomic") {
      step = 6
      write("printf '%s' '{\"version\":1,\"plugins\":[{\"id\":\"matjam.omawall\",\"source\":\"recreated\"}]}' > '" + configPath + "'")
    } else if (step === 6 && source() === "recreated") {
      step = 7
      write("printf '%s' '{\"version\":1,\"plugins\":[{\"id\":\"matjam.omawall\",\"source\":\"one\"}]}' > '" + configPath + "'")
    } else if (step === 8 && source() === "two") {
      step = 9
      write("printf '%s' '{\"version\":1,\"plugins\":[]}' > '" + configPath + "'")
    } else if (step === 9 && source() === "") {
      step = 10
      write("printf '%s' '{\"version\":1,\"plugins\":[{\"id\":\"matjam.omawall\",\"source\":\"retained\"}]}' > '" + configPath + "'")
    } else if (step === 10 && source() === "retained") {
      step = 11
      write("printf '%s' '{\"version\":1,\"plugins\":[{\"id\":\"matjam.omawall\",\"source\":\"unreadable\"}]}' > '" + configPath + ".next' && chmod 000 '" + configPath + ".next' && mv '" + configPath + ".next' '" + configPath + "'")
    } else if (step === 11 && loadFailed) {
      if (source() !== "retained") {
        fail("settings changed after an unreadable replacement")
      } else if (verifyValues()) {
        pass()
      }
    }
  }

  function verifyValues() {
    if (!localPath.fromUrl(Qt.resolvedUrl("a%20b%25%23c")).endsWith("/a b%#c"))
      { fail("local QUrl was not decoded"); return false }
    if (localPath.fromUrl("https://example.test/a%20b") !== "https://example.test/a%20b")
      { fail("non-file URL changed"); return false }
    shellStub.service = null
    shellStub.requestedModule = ""
    serviceVersion.shell = shellStub
    serviceVersion.moduleName = "matjam.omawall"
    if (serviceVersion.version !== "")
      { fail("service version was present before the service was available"); return false }
    if (shellStub.requestedModule !== "matjam.omawall")
      { fail("service version did not use shell.serviceFor"); return false }
    shellStub.service = { manifest: { version: "9.8.7" } }
    if (serviceVersion.version !== "9.8.7")
      { fail("service version did not appear when the service became available"); return false }
    shellStub.service = { manifest: { version: "9.8.8" } }
    if (serviceVersion.version !== "9.8.8")
      { fail("service version did not update after manifest replacement"); return false }
    if (wakeDescription.text !== "Change wallpaper on unlock or screensaver exit rather than on a timer.")
      { fail("wake description changed before status"); return false }
    wakeDescription.backgroundStatusParsed = true
    if (wakeDescription.text !== "Change wallpaper on unlock or screensaver exit rather than on a timer.")
      { fail("wake description changed for ready wake sources"); return false }
    wakeDescription.wakeSourcesReady = false
    if (wakeDescription.text !== "Unavailable with this Omarchy plugin API: unlock and screensaver events are not accessible.")
      { fail("wake unavailable description changed"); return false }
    return true
  }

  function pass() {
    finished = true
    writer.command = ["/bin/sh", "-c", "printf PASS > '" + resultPath + "'"]
    writer.running = true
  }

  function fail(message) {
    if (finished) return
    finished = true
    console.error(message)
    writer.command = ["/bin/sh", "-c", "printf '%s' 'FAIL: " + message + "' > '" + resultPath + "'"]
    writer.running = true
  }

  Connections {
    target: writer
    function onExited() {
      if (root.finished) terminator.running = true
    }
  }

  Connections {
    target: settings
    function onLoaded() { root.advance(false) }
    function onLoadFailed() { root.advance(true) }
    function onReadingChanged() {
      if (settings.reading && root.step === 7 && !root.activeReadUpdateIssued) {
        root.activeReadUpdateIssued = true
        root.step = 8
        root.write("printf '%s' '{\"version\":1,\"plugins\":[{\"id\":\"matjam.omawall\",\"source\":\"two\"}]}' > '" + root.configPath + "'")
      }
    }
  }

  Component.onCompleted: timeout.start()
}
