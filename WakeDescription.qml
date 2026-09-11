import QtQml

QtObject {
  property bool backgroundStatusParsed: false
  property bool wakeSourcesReady: true

  readonly property string text: (!backgroundStatusParsed || wakeSourcesReady)
    ? "Change wallpaper on unlock or screensaver exit rather than on a timer."
    : "Unavailable with this Omarchy plugin API: unlock and screensaver events are not accessible."
}
