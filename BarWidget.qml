import QtQuick
import Quickshell
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "anavarre.apple-podcasts"

  // Loader.item is typed QObject, so qmllint cannot see Panel.qml's members
  // through it.
  // qmllint disable missing-property
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // The plugin's Service.qml singleton, shared by every monitor's widget.
  readonly property var service: root.bar && root.bar.shell
    && typeof root.bar.shell.serviceFor === "function"
    ? root.bar.shell.serviceFor(root.moduleName) : null

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open(payloadJson) { if (panelLoader.item) panelLoader.item.open(payloadJson) }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  // qmllint enable missing-property

  // Settings are injected into widgets, not services, so they are handed down
  // here, clamped, since shell.json is hand-editable.
  function injectService() {
    if (!root.service) return
    root.service.episodeLimit = Model.clampEpisodeLimit(root.setting("episodeLimit", 10))
    root.service.refreshMinutes = Model.snapRefreshMinutes(root.setting("refreshMinutes", 60))
    root.service.source = Model.knownSource(root.setting("source", "latest"))
    root.service.skipBackSeconds = Model.knownSkip(root.setting("skipBackSeconds", 15), 15)
    root.service.skipForwardSeconds = Model.knownSkip(root.setting("skipForwardSeconds", 30), 30)
    root.service.inProgressFirst = root.setting("inProgressFirst", true) === true
    root.service.sortOrder = Model.knownSortOrder(root.setting("sortOrder", "feed"))
    root.service.keepFinishedDays = Model.knownKeepDays(root.setting("keepFinishedDays", 1))
  }

  // The panel's Settings view writes back through here: the widget owns the
  // shell.json entry, so the whole entry is rewritten with the one key changed.
  function saveSetting(name, value) {
    if (!root.bar || !root.bar.shell
        || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[name] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function saveInProgressFirst(on) { root.saveSetting("inProgressFirst", on === true) }
  function saveSortOrder(order) { root.saveSetting("sortOrder", Model.knownSortOrder(order)) }
  function saveKeepFinishedDays(days) { root.saveSetting("keepFinishedDays", Model.knownKeepDays(days)) }
  function saveTextSize(size) { root.saveSetting("textSize", Model.knownTextSize(size)) }

  function injectPanel() {
    root.injectService()
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.service = root.service
    panelLoader.item.textSize = Model.knownTextSize(root.setting("textSize", "medium"))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-podcast (U+F2CE)
    text: "\uf2ce"
    tooltipText: (root.service && root.service.playbackActive
      ? (root.service.playerState === "paused" ? "Paused — " : "Playing — ") + root.service.nowPlaying.title
      : root.service && root.service.authenticated
      ? "Apple Podcasts — " + (root.setting("source", "latest") === "up-next" ? "Up Next" : "latest episodes")
      : "Apple Podcasts — sign in")
      + "\nClick: open · Middle-click: refresh"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.MiddleButton && root.service) root.service.refresh()
    }
  }
}
