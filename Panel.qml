pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "anavarre.apple-podcasts"
  manageIpc: false

  // Artwork that tries again when a load fails (a dropped connection, a CDN
  // hiccup) instead of leaving its slot blank until the panel is rebuilt.
  component ArtImage: Image {
    id: art
    property string url: ""
    property int attempts: 0
    property bool blank: false
    source: art.blank ? "" : art.url
    visible: art.url !== ""
    fillMode: Image.PreserveAspectCrop
    cache: true
    asynchronous: true
    onUrlChanged: art.attempts = 0
    onStatusChanged: if (art.status === Image.Error && art.attempts < 4) retryTimer.restart()
    Timer {
      id: retryTimer
      interval: 1500 * (art.attempts + 1)
      onTriggered: { art.attempts++; art.blank = true; Qt.callLater(function() { art.blank = false }) }
    }
  }

  property var anchorItem: null
  property var hostWidget: null

  // The plugin's Service.qml singleton, handed down by the bar widget. Until it
  // appears the panel reads an inert stand-in so every binding has something
  // to read.
  property var service: null
  readonly property var podcasts: root.service || inertService

  readonly property bool authenticated: root.podcasts.authenticated === true
  readonly property string authState: root.podcasts.authState
  readonly property bool loading: root.podcasts.loading === true
  readonly property bool saving: root.podcasts.saving === true
  readonly property string errorText: root.podcasts.errorText
  readonly property string signInError: root.podcasts.signInError
  readonly property var episodes: root.podcasts.episodes
  readonly property bool signedIn: root.authenticated || root.authState === "offline"

  // Player state, read off the service.
  readonly property var nowPlaying: root.podcasts.nowPlaying
  readonly property string playerState: root.podcasts.playerState
  readonly property real position: root.podcasts.position
  readonly property real duration: root.podcasts.duration
  readonly property string playError: root.podcasts.playError
  readonly property int skipBack: root.podcasts.skipBackSeconds
  readonly property int skipForward: root.podcasts.skipForwardSeconds
  readonly property real speed: root.podcasts.speed
  readonly property var speedChoices: Model.speedChoices
  property bool speedOpen: false
  readonly property bool isPlaying: root.playerState === "playing"
  // Playback controls live in the now playing card above the list.
  readonly property bool showPlayer: root.nowPlaying !== null
    && root.signedIn && !root.showAccount && !root.showSettings

  // The Settings view, reached from the footer or with ",". It replaces the
  // list while it is up and holds what is worth changing without leaving the
  // panel: how the list is ordered and the playback speed.
  property bool settingsOpen: false
  readonly property bool showSettings: root.settingsOpen && root.signedIn && !root.showAccount
  readonly property bool inProgressFirst: root.podcasts.inProgressFirst === true
  readonly property string sortOrder: Model.knownSortOrder(root.podcasts.sortOrder)
  readonly property var sortOrders: Model.sortOrders
  readonly property int keepFinishedDays: Model.knownKeepDays(root.podcasts.keepFinishedDays)
  readonly property var keepDaysChoices: Model.keepDaysChoices
  // The clock the "finished within N days" test reads, refreshed while the
  // panel is open so a row leaves the list without waiting for a refresh.
  property real now: Date.now()
  Timer {
    interval: 60000
    repeat: true
    running: root.opened
    onTriggered: root.now = Date.now()
  }

  // The account view is reached from the footer; signing in shows by itself
  // when nothing works yet.
  property bool accountOpen: false
  readonly property bool showSignIn: !root.signedIn && root.authState !== "unknown"
  readonly property bool showAccount: root.accountOpen && root.signedIn
  property int selected: 0

  // Finished episodes stay listed with a green check mark for the number of
  // days set in Settings, then leave the list and are only reached through the
  // Played view (p). The episode in the now playing card leaves it too, until
  // stopped.
  property bool showPlayed: false
  // Where an episode was left; every read of a position in the list goes here.
  function positionOf(e) {
    // TEMP-TEST: pretend the Moicano Nolan fight finished 12 hours ago.
    if (e && String(e.title).indexOf("Moicano") >= 0 && String(e.title).indexOf("Nolan") >= 0)
      return { ms: 0, completed: true, at: root.now - 0.5 * 86400000 }
    return root.podcasts.positions[e.id]
  }
  function finishedRecently(e) {
    return Model.recentlyFinished(root.positionOf(e), root.now, root.keepFinishedDays)
  }
  // Played ones are kept by the service, so they outlive the feed. The rest is
  // ordered as the settings say: started episodes on top, then by show or date.
  readonly property var listed: root.showPlayed ? root.podcasts.playedEpisodes
    : Model.sortEpisodes(root.episodes.filter(function(e) {
      if (root.nowPlaying !== null && root.playerState !== "ended" && root.podcasts.sameEpisode(root.nowPlaying, e)) return false
      var pos = root.positionOf(e)
      if (pos ? pos.completed === true : root.podcasts.playedSet[e.id] === true) return root.finishedRecently(e)
      return true
    }), root.podcasts.positions, { inProgressFirst: root.inProgressFirst, order: root.sortOrder,
      currentId: root.nowPlaying ? root.nowPlaying.id : "" })

  // Whether any listed episode was started and left, which the header mentions.
  readonly property bool hasInProgress: root.listed.some(function(e) {
    return Model.inProgress(root.podcasts.positions[e.id], e.durationMs)
  })

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Color.muted
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Text size is offered as named sizes; every font size in the panel is
  // scaled by the matching factor.
  property string textSize: "medium"
  readonly property var textSizes: [
    { value: "small", label: "Small", scale: 0.85 },
    { value: "medium", label: "Medium", scale: 1.0 },
    { value: "large", label: "Large", scale: 1.2 },
    { value: "xlarge", label: "Extra large", scale: 1.45 }
  ]
  readonly property int textSizeIndex: {
    for (var i = 0; i < root.textSizes.length; i++)
      if (root.textSizes[i].value === root.textSize) return i
    return 1
  }
  readonly property real textScale: root.textSizes[root.textSizeIndex].scale
  readonly property string textSizeLabel: root.textSizes[root.textSizeIndex].label

  // Every font size in this panel goes through here, so one setting moves all
  // of them together.
  function fs(size) { return Math.round(size * root.textScale) }

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property real cardWidth: panel.fittedContentWidth(Style.space(Math.round(460 * root.textScale)))

  QtObject {
    id: inertService
    readonly property bool authenticated: false
    readonly property string authState: "unknown"
    readonly property bool loading: false
    readonly property bool saving: false
    readonly property string errorText: ""
    readonly property string signInError: ""
    readonly property var episodes: []
    readonly property var positions: ({})
    readonly property var playedEpisodes: []
    readonly property var playedSet: ({})
    readonly property var nowPlaying: null
    readonly property string playerState: "idle"
    readonly property real position: 0
    readonly property real duration: 0
    readonly property string playError: ""
    readonly property int skipBackSeconds: 15
    readonly property int skipForwardSeconds: 30
    property bool inProgressFirst: true
    property string sortOrder: "feed"
    property int keepFinishedDays: 1
    property bool playerVisible: false
    readonly property real speed: 1
    function setSpeed(rate) {}
    function sameEpisode(a, b) { return false }
    function play(episode) {}
    function markPlayed(episode) {}
    function togglePlay() {}
    function skip(seconds) {}
    function seekTo(seconds) {}
    function stopPlayback() {}
    function refresh() {}
    function signIn(token) {}
    function forget() {}
    function openUrl(url) {}
  }

  onOpenedChanged: {
    if (root.opened) {
      root.accountOpen = false
      root.settingsOpen = false
      root.speedOpen = false
      root.showPlayed = false
      root.selected = 0
      if (root.signedIn) root.podcasts.refresh()
    }
  }

  // Tell the service when the player is on screen, so it polls mpv every
  // second only then.
  readonly property bool playerOnScreen: root.opened && root.nowPlaying !== null && root.signedIn
    && !root.showAccount && !root.showSettings
  onPlayerOnScreenChanged: { if (root.service) root.service.playerVisible = root.playerOnScreen }

  function moveSelection(dy) {
    if (root.listed.length === 0) return
    root.selected = Math.max(0, Math.min(root.listed.length - 1, root.selected + dy))
  }

  function openEpisode(index) {
    var e = root.listed[index]
    if (!e) return
    root.podcasts.play(e)
  }

  onListedChanged: root.selected = Math.max(0, Math.min(root.listed.length - 1, root.selected))

  // Settings take effect at once on the service and are written to shell.json
  // through the bar widget, which owns the entry; without a widget (or a shell
  // that cannot write) the change lasts for the session.
  function setInProgressFirst(on) {
    if (root.service) root.service.inProgressFirst = on === true
    if (root.hostWidget && typeof root.hostWidget.saveInProgressFirst === "function") root.hostWidget.saveInProgressFirst(on === true)
  }

  function setSortOrder(order) {
    var next = Model.knownSortOrder(order)
    if (root.service) root.service.sortOrder = next
    if (root.hostWidget && typeof root.hostWidget.saveSortOrder === "function") root.hostWidget.saveSortOrder(next)
  }

  function setKeepFinishedDays(days) {
    var next = Model.knownKeepDays(days)
    if (root.service) root.service.keepFinishedDays = next
    if (root.hostWidget && typeof root.hostWidget.saveKeepFinishedDays === "function") root.hostWidget.saveKeepFinishedDays(next)
  }

  function stepTextSize(delta) {
    var i = Math.max(0, Math.min(root.textSizes.length - 1, root.textSizeIndex + delta))
    var next = root.textSizes[i].value
    if (next === root.textSize) return
    root.textSize = next
    if (root.hostWidget && typeof root.hostWidget.saveTextSize === "function") root.hostWidget.saveTextSize(next)
  }

  function sortOrderLabel(order) { return order === "date" ? "Date" : "Feed" }

  function seekFromClick(x, width) {
    if (root.duration > 0 && width > 0) root.podcasts.seekTo(root.duration * Math.max(0, Math.min(1, x / width)))
  }

  function submitToken() {
    if (tokenField.text.trim() === "" || root.saving) return
    root.podcasts.signIn(tokenField.text)
    tokenField.text = ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: root.showSignIn ? tokenField : keys
    contentWidth: root.cardWidth
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      // The sign-in form owns the keyboard while it is up, so typing a token
      // doesn't drive the list underneath it.
      blocked: root.showSignIn
      onMoveRequested: function(dx, dy) {
        if (root.showPlayer && dy === 0) {
          if (dx < 0) root.podcasts.skip(-root.skipBack)
          else if (dx > 0) root.podcasts.skip(root.skipForward)
        }
        else if (!root.showAccount && !root.showSettings && dy !== 0) root.moveSelection(dy)
      }
      onActivateRequested: {
        if (root.showAccount) { root.podcasts.forget(); root.accountOpen = false }
        else if (root.showSettings) root.settingsOpen = false
        else if (root.showPlayer && root.podcasts.sameEpisode(root.nowPlaying, root.listed[root.selected])) root.podcasts.togglePlay()
        else root.openEpisode(root.selected)
      }
      onCloseRequested: {
        if (root.showAccount) root.accountOpen = false
        else if (root.showSettings) root.settingsOpen = false
        else if (root.showPlayer && root.speedOpen) root.speedOpen = false
        else if (root.showPlayed) { root.showPlayed = false; root.selected = 0 }
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.showPlayer && text === "o" && root.nowPlaying.url !== "") { root.podcasts.openUrl(root.nowPlaying.url); return }
        if (root.showPlayer && text === "s") { root.podcasts.stopPlayback(); return }
        if (text === "r") root.podcasts.refresh()
        else if (text === "p" && !root.showAccount && !root.showSettings) { root.showPlayed = !root.showPlayed; root.selected = 0 }
        else if (text === "m" && !root.showAccount && !root.showSettings && !root.showPlayed) {
          var ep = root.listed[root.selected]
          if (ep) root.podcasts.markPlayed(ep)
        }
        else if (text === "c") root.accountOpen = !root.accountOpen
        else if (text === ",") root.settingsOpen = !root.settingsOpen
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ------------------------------------------------------ sign-in form
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showSignIn

          Text {
            width: parent.width
            text: "Sign in to Apple Podcasts"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.subtitle)
            font.bold: true
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            text: "Apple has no sign-in for third-party apps, so this uses your session on the web player. "
              + "1. Press Open and sign in with your Apple Account. "
              + "2. In the browser's developer tools, open Storage/Application → Cookies → podcasts.apple.com "
              + "and copy the value of media-user-token. 3. Paste it here."
          }

          Text {
            width: parent.width
            visible: root.signInError !== ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.signInError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }

          TextField {
            id: tokenField
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.body)
            password: true
            placeholderText: "media-user-token"
            onAccepted: root.submitToken()
            Keys.onEscapePressed: root.close()
          }

          Row {
            spacing: Style.space(8)
            Button {
              text: "Open podcasts.apple.com"
              onClicked: root.podcasts.openUrl("https://podcasts.apple.com/us/library")
            }
            Button {
              text: root.saving ? "Checking…" : "Sign in"
              enabled: !root.saving
              onClicked: root.submitToken()
            }
          }
        }

        // ------------------------------------------------------------ account
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showAccount

          Text {
            width: parent.width
            text: "Signed in"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.subtitle)
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            text: "Enter forgets the stored token. It does not sign you out of Apple; do that on the web player."
          }
        }

        // ------------------------------------------------------------ settings
        Column {
          id: settingsColumn
          width: parent.width
          spacing: Style.space(10)
          visible: root.showSettings

          // The switch is sized like a button row, so the rows line up.
          readonly property real controlHeight: Math.max(Style.space(22), root.fs(Style.font.bodySmall) + Style.spacing.sm * 2)

          Text {
            width: parent.width
            text: "Settings"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.subtitle)
            font.bold: true
          }

          Item {
            width: parent.width
            height: Math.max(pinCaption.implicitHeight, settingsColumn.controlHeight)

            Column {
              id: pinCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - pinSwitch.width - Style.space(8)
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: "Started episodes first"
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "What you have started, and what is playing, stays on top, most recent first."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
              }
            }

            ToggleSwitch {
              id: pinSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.inProgressFirst
              cursorRing: false
              trackHeight: Math.round(settingsColumn.controlHeight)
              foreground: root.foreground
              accent: root.accent
              onToggled: root.setInProgressFirst(!root.inProgressFirst)
            }
          }

          Item {
            width: parent.width
            height: Math.max(orderCaption.implicitHeight, orderButtons.implicitHeight)

            Column {
              id: orderCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - orderButtons.width - Style.space(8)
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: root.inProgressFirst ? "Then order by" : "Order by"
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.sortOrder === "date" ? "Newest first, across shows." : "Grouped by show, newest first within each."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
              }
            }

            Row {
              id: orderButtons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              Repeater {
                model: root.sortOrders
                Button {
                  required property var modelData
                  text: root.sortOrderLabel(modelData)
                  selected: modelData === root.sortOrder
                  onClicked: root.setSortOrder(modelData)
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Math.max(keepCaption.implicitHeight, keepButtons.implicitHeight)

            Column {
              id: keepCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - keepButtons.width - Style.space(8)
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: "Keep finished episodes"
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "They stay listed with a check mark, then move to Played only."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
              }
            }

            Row {
              id: keepButtons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              Repeater {
                model: root.keepDaysChoices
                Button {
                  required property var modelData
                  text: modelData + (modelData === 1 ? " day" : " days")
                  selected: modelData === root.keepFinishedDays
                  onClicked: root.setKeepFinishedDays(modelData)
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Math.max(textSizeCaption.implicitHeight, textSizeControls.implicitHeight)

            Column {
              id: textSizeCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - textSizeControls.width - Style.space(8)
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: "Text size"
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Scales all text in the panel."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
              }
            }

            Row {
              id: textSizeControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-minus (U+F068)
                iconText: "\uf068"
                tooltipText: "Smaller"
                enabled: root.textSizeIndex > 0
                foreground: root.foreground
                hoverColor: root.foreground
                fontSize: root.fs(Style.font.bodySmall)
                onClicked: root.stepTextSize(-1)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(Style.space(Math.round(80 * root.textScale)), implicitWidth)
                horizontalAlignment: Text.AlignHCenter
                text: root.textSizeLabel
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-plus (U+F067)
                iconText: "\uf067"
                tooltipText: "Larger"
                enabled: root.textSizeIndex < root.textSizes.length - 1
                foreground: root.foreground
                hoverColor: root.foreground
                fontSize: root.fs(Style.font.bodySmall)
                onClicked: root.stepTextSize(1)
              }
            }
          }

          Item {
            width: parent.width
            height: Math.max(speedCaption.implicitHeight, speedButtons.implicitHeight)

            Column {
              id: speedCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - speedButtons.width - Style.space(8)
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: "Playback speed"
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Applies to what is playing and to every episode after it."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
              }
            }

            Row {
              id: speedButtons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              Repeater {
                model: root.speedChoices
                Button {
                  required property var modelData
                  text: Model.formatSpeed(modelData)
                  selected: modelData === root.speed
                  onClicked: root.podcasts.setSpeed(modelData)
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Math.max(webCaption.implicitHeight, settingsColumn.controlHeight)

            Column {
              id: webCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - webButton.width - Style.space(8)
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: "Apple Podcasts on the web"
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Opens podcasts.apple.com in your browser."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
              }
            }

            PanelActionButton {
              id: webButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // nf-fa-external_link (U+F08E)
              iconText: ""
              tooltipText: "Open podcasts.apple.com"
              foreground: root.foreground
              hoverColor: root.foreground
              fontSize: root.fs(Style.font.bodySmall)
              onClicked: root.podcasts.openUrl("https://podcasts.apple.com/us/library")
            }
          }
        }

        // ---------------------------------------------------------------- list
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.signedIn && !root.showAccount && !root.showSettings

          // What is playing: a card pinned above the list, with transport
          // controls so it can be paused or skipped without opening the player.
          Text {
            width: parent.width
            visible: root.nowPlaying !== null
            text: root.playerState === "paused" ? "PAUSED" : root.playerState === "ended" ? "FINISHED"
              : root.playerState === "buffering" ? "LOADING…" : "NOW PLAYING"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            font.bold: true
          }

          Rectangle {
            width: parent.width
            height: nowIcon.height + nowColumn.implicitHeight + Style.space(30)
            radius: Style.space(8)
            visible: root.nowPlaying !== null
            color: Qt.alpha(root.accent, 0.18)
            border.width: 1
            border.color: root.accent

            ArtImage {
              id: nowIcon
              anchors.top: parent.top
              anchors.topMargin: Style.space(10)
              anchors.horizontalCenter: parent.horizontalCenter
              width: visible ? Style.space(160) : 0
              height: width
              url: root.nowPlaying ? (root.nowPlaying.artworkLarge || root.nowPlaying.artwork) : ""
            }

            Column {
              id: nowColumn
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.top: nowIcon.bottom
              anchors.topMargin: Style.space(10)
              spacing: Style.space(6)

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.nowPlaying ? root.nowPlaying.title : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.subtitle)
                font.bold: true
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                visible: text !== ""
                text: root.nowPlaying ? root.nowPlaying.show : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
              }
              Rectangle {
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: Qt.alpha(root.foreground, 0.2)
                Rectangle {
                  width: root.duration > 0 ? parent.width * Math.min(1, root.position / root.duration) : 0
                  height: parent.height
                  radius: parent.radius
                  color: root.accent
                }
              }
              Row {
                spacing: Style.space(8)
                Button {
                  text: Model.formatSpeed(root.speed)
                  tooltipText: "Playback speed"
                  active: root.speedOpen
                  onClicked: root.speedOpen = !root.speedOpen
                }
                Button {
                  text: "−" + root.skipBack + "s"
                  tooltipText: "Back " + root.skipBack + " seconds"
                  enabled: root.playerState !== "ended"
                  onClicked: root.podcasts.skip(-root.skipBack)
                }
                Button {
                  iconText: root.playerState === "ended" ? "\uf01e" : root.isPlaying ? "\uf04c" : root.playerState === "buffering" ? "\uf110" : "\uf04b"
                  iconSpinning: root.playerState === "buffering"
                  tooltipText: root.playerState === "ended" ? "Replay" : root.isPlaying ? "Pause" : "Play"
                  onClicked: root.podcasts.togglePlay()
                }
                Button {
                  text: "+" + root.skipForward + "s"
                  tooltipText: "Forward " + root.skipForward + " seconds"
                  enabled: root.playerState !== "ended"
                  onClicked: root.podcasts.skip(root.skipForward)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.formatClock(root.position) + (root.duration > 0 ? " / " + Model.formatClock(root.duration) : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: root.fs(Style.font.bodySmall)
                }
              }
              Row {
                spacing: Style.space(6)
                visible: root.speedOpen
                Repeater {
                  model: root.speedChoices
                  Button {
                    required property var modelData
                    text: Model.formatSpeed(modelData)
                    selected: modelData === root.speed
                    onClicked: { root.podcasts.setSpeed(modelData); root.speedOpen = false }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(8)
            visible: root.nowPlaying !== null
          }

          Text {
            width: parent.width
            text: root.showPlayed ? "PLAYED" : root.hasInProgress ? "UNPLAYED & IN PROGRESS" : "UNPLAYED"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            font.bold: true
          }

          Text {
            width: parent.width
            visible: root.playError !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.playError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }

          Text {
            width: parent.width
            visible: root.errorText !== ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.authState === "offline" ? "Can't reach Apple Podcasts. Retrying…" : root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }

          Text {
            width: parent.width
            visible: root.listed.length === 0 && !root.loading && root.errorText === ""
            text: root.showPlayed ? "No played episodes." : "No episodes."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.body)
          }

          Repeater {
            model: root.listed

            Rectangle {
              id: row
              required property int index
              required property var modelData
              width: parent.width
              height: rowText.implicitHeight + Style.space(12)
              radius: Style.space(6)
              color: row.index === root.selected ? Qt.alpha(root.accent, 0.18) : "transparent"

              // Episodes of one show share the same artwork URL, and Image's pixmap
              // cache keeps the decoded bitmap in memory, so each icon is fetched
              // once however many rows use it.
              ArtImage {
                id: rowIcon
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                width: visible ? Style.space(32) : 0
                height: width
                url: row.modelData.artwork || row.modelData.artworkLarge
                sourceSize: Qt.size(Style.space(64), Style.space(64))
              }

              Column {
                id: rowText
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: rowIcon.right
                anchors.right: parent.right
                anchors.margins: Style.space(8)
                spacing: Style.space(2)

                // The selected row's title scrolls sideways when it doesn't fit.
                Item {
                  width: parent.width
                  height: titleBox.height

                Item {
                  id: titleBox
                  width: Math.min(rowTitle.implicitWidth, parent.width - (rowDone.visible ? rowDone.implicitWidth + Style.space(6) : 0))
                  height: rowTitle.implicitHeight
                  clip: true
                  readonly property real overflow: rowTitle.implicitWidth - width
                  readonly property bool scrolling: row.index === root.selected && overflow > 0

                  Text {
                    id: rowTitle
                    width: titleBox.scrolling ? implicitWidth : parent.width
                    elide: titleBox.scrolling ? Text.ElideNone : Text.ElideRight
                    wrapMode: Text.NoWrap
                    textFormat: Text.PlainText
                    text: row.modelData.title
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.fs(Style.font.body)
                  }

                  SequentialAnimation {
                    running: titleBox.scrolling
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) rowTitle.x = 0
                    PauseAnimation { duration: 1200 }
                    NumberAnimation {
                      target: rowTitle
                      property: "x"
                      from: 0
                      to: -titleBox.overflow
                      duration: Math.max(1000, titleBox.overflow * 25)
                      easing.type: Easing.InOutSine
                    }
                    PauseAnimation { duration: 1200 }
                    NumberAnimation {
                      target: rowTitle
                      property: "x"
                      to: 0
                      duration: Math.max(1000, titleBox.overflow * 25)
                      easing.type: Easing.InOutSine
                    }
                  }
                }

                // A finished episode that is still listed.
                Text {
                  id: rowDone
                  anchors.left: titleBox.right
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: titleBox.verticalCenter
                  visible: !root.showPlayed && root.finishedRecently(row.modelData)
                  text: "\u2713"
                  color: "#2ea043"
                  font.family: root.fontFamily
                  font.pixelSize: root.fs(Style.font.body)
                  font.bold: true
                }
                }
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: root.fs(Style.font.bodySmall)
                  text: [row.modelData.show, Model.relativeAge(row.modelData.published),
                    Model.formatDuration(row.modelData.durationMs),
                    Model.resumeLabel(root.positionOf(row.modelData), row.modelData.durationMs)].filter(function(s) { return s !== "" }).join(" · ")
                }
                Rectangle {
                  readonly property real fraction: Model.progressFraction(root.podcasts.positions[row.modelData.id], row.modelData.durationMs)
                  width: parent.width
                  height: Style.space(3)
                  radius: height / 2
                  visible: fraction > 0
                  color: Qt.alpha(root.foreground, 0.2)
                  Rectangle {
                    width: parent.width * parent.fraction
                    height: parent.height
                    radius: parent.radius
                    color: root.accent
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.selected = row.index
                onClicked: root.openEpisode(row.index)
              }

              // Play straight from the list: the icon turns into a button on hover.
              Rectangle {
                id: rowPlay
                anchors.fill: rowIcon
                visible: rowIconHover.containsMouse
                radius: Style.space(4)
                color: Qt.rgba(0, 0, 0, 0.55)
                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: "white"
                  font.family: root.fontFamily
                  font.pixelSize: root.fs(Style.font.body)
                }
              }
              MouseArea {
                id: rowIconHover
                anchors.fill: rowIcon
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selected = row.index
                onClicked: root.podcasts.play(root.listed[row.index])
              }
            }
          }
        }

        // -------------------------------------------------------------- footer
        Row {
          spacing: Style.space(14)
          visible: root.signedIn
          Text {
            text: root.loading ? "Refreshing…" : "r Refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }
          Text {
            visible: !root.showAccount && !root.showSettings
            text: root.showPlayed ? "p Unplayed" : "p Played"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }
          Text {
            visible: !root.showAccount && !root.showSettings && !root.showPlayed
            text: "m Mark played"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }
          Text {
            visible: !root.showAccount && !root.showSettings
            text: ", Settings"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }
          Text {
            visible: root.showAccount || root.showSettings || root.showPlayed
            text: "Esc Back"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }
          Text {
            visible: !root.showAccount
            text: "c Account"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
          }
        }
      }
    }
  }
}
