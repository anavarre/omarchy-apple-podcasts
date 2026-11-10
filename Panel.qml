pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "anavarre.apple-podcasts"
  manageIpc: false

  // Artwork. The image is never fetched by Image itself: the service downloads
  // it through bin/podcasts-api (size, time and redirect bounds, image types
  // only) and this loads the cached local file, decoded no larger than
  // sourceSize. A decode failure is retried, as the file may have been replaced.
  component ArtImage: Image {
    id: art
    property string url: ""
    property var service: null
    property int attempts: 0
    property bool blank: false
    readonly property string local: art.service && art.url !== "" ? (art.service.artPaths[art.url] || "") : ""
    source: art.blank ? "" : art.local
    visible: art.url !== ""
    sourceSize: Qt.size(512, 512)
    fillMode: Image.PreserveAspectCrop
    cache: true
    asynchronous: true
    onUrlChanged: { art.attempts = 0; art.want() }
    Component.onCompleted: art.want()
    function want() { if (art.service && art.url !== "") art.service.requestArt(art.url) }
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
  property string pasteError: ""
  readonly property string signInError: root.pasteError !== "" ? root.pasteError : root.podcasts.signInError
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

  // The shortcuts cheat sheet, opened with "?" or the footer's question mark.
  // It floats over whatever is up so you can read a binding without losing
  // your place in the list.
  property bool shortcutsOpen: false
  readonly property var shortcuts: [
    { keys: "↑ / ↓", what: "Move the selection" },
    { keys: "Space / Enter", what: "Play the selected episode, or pause / resume" },
    { keys: "← / →", what: "Skip back / forward" },
    { keys: "o", what: "Open the episode on Apple's site" },
    { keys: "n", what: "Queue the selected episode to play next" },
    { keys: "Drag \u283F", what: "Reorder the queue by dragging an episode by its handle" },
    { keys: "Shift + R", what: "Remove the selected episode from the queue" },
    { keys: "Enter", what: "On a section title, collapse or expand the section" },
    { keys: "s", what: "Stop" },
    { keys: "r", what: "Refresh now" },
    { keys: "p", what: "Switch between unplayed and played" },
    { keys: "m", what: "Mark the selected episode as played" },
    { keys: ",", what: "Settings" },
    { keys: "c", what: "Account" },
    { keys: "Tab", what: "Switch to the next panel" },
    { keys: "?", what: "Show or hide this list" },
    { keys: "Esc", what: "Close" }
  ]
  readonly property bool showSettings: root.settingsOpen && root.signedIn && !root.showAccount
  readonly property bool inProgressFirst: root.podcasts.inProgressFirst === true
  readonly property string sortOrder: Model.knownSortOrder(root.podcasts.sortOrder)
  readonly property bool groupByFeed: root.podcasts.groupByFeed !== false
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
  // Sections of the list that are folded away, by key ("queue", "main").
  property var collapsed: ({})
  function isCollapsed(key) { return root.collapsed[key] === true }
  function toggleSection(key) {
    var c = Object.assign({}, root.collapsed)
    c[key] = !c[key]
    root.collapsed = c
  }
  // Where an episode was left; every read of a position in the list goes here.
  function positionOf(e) {
    return root.podcasts.positions[e.id]
  }
  function isQueued(e) {
    return root.podcasts.queue.some(function(q) { return root.podcasts.sameEpisode(q, e) })
  }
  function finishedRecently(e) {
    return Model.recentlyFinished(root.positionOf(e), root.now, root.keepFinishedDays)
  }
  // Played ones are kept by the service, so they outlive the feed. The rest is
  // ordered as the settings say: started episodes on top, then by show or date.
  readonly property var queueEpisodes: root.showPlayed ? [] : root.podcasts.queue
  // What is listed under the queue: the played ones, or the unplayed ones that
  // are not queued (a queued episode is only shown in the queue).
  readonly property var mainEpisodes: root.showPlayed ? root.podcasts.playedEpisodes
    : Model.sortEpisodes(root.episodes.filter(function(e) {
      if (root.nowPlaying !== null && root.playerState !== "ended" && root.podcasts.sameEpisode(root.nowPlaying, e)) return false
      if (root.isQueued(e)) return false
      var pos = root.positionOf(e)
      if (pos ? pos.completed === true : root.podcasts.playedSet[e.id] === true) return root.finishedRecently(e)
      return true
    }), root.podcasts.positions, { inProgressFirst: root.inProgressFirst, groupByFeed: root.groupByFeed,
      currentId: root.nowPlaying ? root.nowPlaying.id : "" })

  // Whether any listed episode was started and left, which the header mentions.
  readonly property bool hasInProgress: root.mainEpisodes.some(function(e) {
    return Model.inProgress(root.podcasts.positions[e.id], e.durationMs)
  })

  function sectionHeader(key, title, count) {
    return { isHeader: true, section: key, title: title, count: count,
             id: "", show: "", published: "", durationMs: 0, artwork: "", artworkLarge: "", url: "" }
  }

  // The rows of the list, in order: each section's title (a row of its own, so
  // it can be selected and folded) followed by its episodes unless folded.
  readonly property var listed: {
    var out = []
    if (root.queueEpisodes.length > 0) {
      out.push(root.sectionHeader("queue", "QUEUE", root.queueEpisodes.length))
      if (!root.isCollapsed("queue")) out = out.concat(root.queueEpisodes)
    }
    if (root.mainEpisodes.length > 0) {
      var title = root.showPlayed ? "PLAYED" : root.hasInProgress ? "UNPLAYED & IN PROGRESS" : "UNPLAYED"
      out.push(root.sectionHeader("main", title, root.mainEpisodes.length))
      if (!root.isCollapsed("main")) out = out.concat(root.mainEpisodes.slice(0, root.visibleCount))
    }
    return out
  }

  // The unplayed list shows one page at a time; reaching its end (arrow keys or
  // a click on the arrow below it) reveals the next page. A page is 15
  // episodes, or 10 while one is playing (the now-playing card takes room).
  readonly property int pageSize: root.nowPlaying !== null ? 10 : 15
  property int visibleCount: root.pageSize
  readonly property var shown: root.listed
  readonly property bool hasMore: !root.isCollapsed("main") && root.mainEpisodes.length > root.visibleCount
  function showMore() {
    if (root.hasMore) root.visibleCount = Math.min(root.mainEpisodes.length, root.visibleCount + root.pageSize)
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  // Secondary text (author, date, duration). Themes' muted colour is often too
  // faint on the panel background, so it is pulled toward the foreground until
  // it reaches a WCAG-style contrast ratio, while keeping the theme's hue.
  readonly property color panelBackground: Color.popups.background
  readonly property color dim: root.readable(Color.muted, root.foreground, root.panelBackground, 5.5)

  function luminance(c) {
    function ch(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
  }
  function contrast(a, b) {
    var la = root.luminance(a), lb = root.luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }
  function readable(base, target, bg, minRatio) {
    for (var i = 0; i <= 10; i++) {
      var t = i / 10
      var c = Qt.rgba(base.r + (target.r - base.r) * t,
                      base.g + (target.g - base.g) * t,
                      base.b + (target.b - base.b) * t, 1)
      if (root.contrast(c, bg) >= minRatio) return c
    }
    return target
  }
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
    readonly property var queue: []
    readonly property int session: 0
    readonly property var artPaths: ({})
    function requestArt(url) {}
    readonly property var nowPlaying: null
    readonly property string playerState: "idle"
    readonly property real position: 0
    readonly property real duration: 0
    readonly property string playError: ""
    readonly property int skipBackSeconds: 15
    readonly property int skipForwardSeconds: 30
    property bool inProgressFirst: true
    property string sortOrder: "feed"
    property bool groupByFeed: true
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
      root.shortcutsOpen = false
      root.speedOpen = false
      root.showPlayed = false
      root.selected = 0
      root.visibleCount = root.pageSize
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
    if (dy > 0 && root.selected >= root.listed.length - 1) root.showMore()
    root.selected = Math.max(0, Math.min(root.listed.length - 1, root.selected + dy))
  }

  function openEpisode(index) {
    var e = root.listed[index]
    if (!e) return
    if (e.isHeader === true) { root.toggleSection(e.section); return }
    root.podcasts.play(e)
  }

  onListedChanged: root.selected = Math.max(0, Math.min(root.listed.length - 1, root.selected))
  onPageSizeChanged: root.visibleCount = root.pageSize
  onShowPlayedChanged: root.visibleCount = root.pageSize

  // Settings take effect at once on the service and are written to shell.json
  // through the bar widget, which owns the entry; without a widget (or a shell
  // that cannot write) the change lasts for the session.
  function setInProgressFirst(on) {
    if (root.service) root.service.inProgressFirst = on === true
    if (root.hostWidget && typeof root.hostWidget.saveInProgressFirst === "function") root.hostWidget.saveInProgressFirst(on === true)
  }

  function setGroupByFeed(on) {
    if (root.service) root.service.groupByFeed = on === true
    if (root.hostWidget && typeof root.hostWidget.saveGroupByFeed === "function") root.hostWidget.saveGroupByFeed(on === true)
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

  function seekFromClick(x, width) {
    if (root.duration > 0 && width > 0) root.podcasts.seekTo(root.duration * Math.max(0, Math.min(1, x / width)))
  }

  // The token is pasted through bin/podcasts-paste (byte cap, hard deadline),
  // never through Qt's own clipboard path, which reads without bounds.
  readonly property int maxTokenLength: 2048
  function pasteToken(primary) {
    if (pasteProcess.armed) return
    pasteProcess.born = root.pasteEpoch
    pasteProcess.command = ["/usr/bin/bash", Model.localPath(Qt.resolvedUrl("bin/podcasts-paste"))].concat(primary ? ["primary"] : [])
    pasteProcess.armed = true
    pasteProcess.running = true
  }

  // Bumped whenever a paste in flight stops being wanted (the form or panel
  // went away, or the account changed), so a late answer is dropped and a
  // cancelled sign-in is never repopulated.
  property int pasteEpoch: 0
  readonly property bool pasteWanted: root.opened && root.showSignIn
  readonly property int accountSession: root.podcasts.session
  function cancelPaste() {
    root.pasteEpoch++
    if (pasteProcess.armed) pasteProcess.running = false
  }
  onPasteWantedChanged: root.cancelPaste()
  onAccountSessionChanged: root.cancelPaste()

  Process {
    id: pasteProcess
    property bool armed: false
    property int born: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.pasteEnvironment
    stdout: StdioCollector { id: pasteOut; waitForEnd: true }
    onRunningChanged: if (running) pasteProcess.armed = true
    onExited: function(exitCode) {
      pasteProcess.armed = false
      if (pasteProcess.born !== root.pasteEpoch || !root.pasteWanted) return
      var t = pasteOut.text.replace(/[\r\n]/g, "").trim()
      if (exitCode !== 0 || t === "" || t.length > root.maxTokenLength || !/^[\x21-\x7e]+$/.test(t)) {
        root.pasteError = exitCode === 2 || t.length > root.maxTokenLength
          ? "The clipboard holds too much data to be a token." : "Nothing usable to paste from the clipboard."
        return
      }
      root.pasteError = ""
      tokenField.text = t
    }
  }

  function submitToken() {
    if (tokenField.text.trim() === "" || tokenField.text.length > root.maxTokenLength || root.saving) return
    root.pasteError = ""
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
    // The cheat sheet floats over the content, so the panel must be tall
    // enough to hold it.
    contentHeight: panel.fittedContentHeight(Math.max(content.implicitHeight,
      root.shortcutsOpen ? shortcutsSheet.implicitHeight : 0))

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
        if (root.shortcutsOpen) root.shortcutsOpen = false
        else if (root.showAccount) root.accountOpen = false
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
          if (ep && ep.isHeader !== true) root.podcasts.markPlayed(ep)
        }
        else if (text === "n" && !root.showAccount && !root.showSettings) {
          var qe = root.listed[root.selected]
          if (qe && qe.isHeader !== true && !root.showPlayed) root.podcasts.enqueue(qe)
        }
        else if (text === "R" && !root.showAccount && !root.showSettings) {
          var re = root.listed[root.selected]
          if (re && re.isHeader !== true && root.isQueued(re)) root.podcasts.dequeue(re)
        }
        else if (text === "c") root.accountOpen = !root.accountOpen
        else if (text === ",") root.settingsOpen = !root.settingsOpen
        else if (text === "?") root.shortcutsOpen = !root.shortcutsOpen
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
            // Every native paste route is swallowed and sent to pasteToken().
            Keys.onPressed: function(event) {
              if (event.matches(StandardKey.Paste)
                  || (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier))
                  || (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier))) {
                root.pasteToken(false)
                event.accepted = true
              }
            }
            // Middle click (primary selection) and the context menu would
            // otherwise reach Qt's unbounded paste.
            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.MiddleButton | Qt.RightButton
              onClicked: function(mouse) { root.pasteToken(mouse.button === Qt.MiddleButton) }
            }
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
            height: Math.max(groupCaption.implicitHeight, settingsColumn.controlHeight)

            Column {
              id: groupCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - groupSwitch.width - Style.space(8)
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: "Group by podcast feed"
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.groupByFeed ? "Grouped by show, newest first within each." : "Newest first, across shows."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
              }
            }

            ToggleSwitch {
              id: groupSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.groupByFeed
              cursorRing: false
              trackHeight: Math.round(settingsColumn.controlHeight)
              foreground: root.foreground
              accent: root.accent
              onToggled: root.setGroupByFeed(!root.groupByFeed)
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
              service: root.podcasts
              url: root.nowPlaying ? (root.nowPlaying.artworkLarge || root.nowPlaying.artwork) : ""
              sourceSize: Qt.size(Style.space(320), Style.space(320))
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

              // The title scrolls sideways, continuously, when it doesn't fit.
              Item {
                id: nowTitleBox
                width: parent.width
                height: nowTitle.implicitHeight
                clip: true
                readonly property real overflow: nowTitle.implicitWidth - width
                readonly property bool scrolling: overflow > 0

                Text {
                  id: nowTitle
                  width: nowTitleBox.scrolling ? implicitWidth : parent.width
                  elide: Text.ElideNone
                  wrapMode: Text.NoWrap
                  textFormat: Text.PlainText
                  text: root.nowPlaying ? root.nowPlaying.title : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.fs(Style.font.subtitle)
                  font.bold: true
                }

                SequentialAnimation {
                  running: nowTitleBox.scrolling
                  loops: Animation.Infinite
                  onRunningChanged: if (!running) nowTitle.x = 0
                  PauseAnimation { duration: 1200 }
                  NumberAnimation {
                    target: nowTitle
                    property: "x"
                    from: 0
                    to: -nowTitleBox.overflow
                    duration: Math.max(1000, nowTitleBox.overflow * 25)
                    easing.type: Easing.InOutSine
                  }
                  PauseAnimation { duration: 1200 }
                  NumberAnimation {
                    target: nowTitle
                    property: "x"
                    to: 0
                    duration: Math.max(1000, nowTitleBox.overflow * 25)
                    easing.type: Easing.InOutSine
                  }
                }
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
                MouseArea {
                  anchors.fill: parent
                  anchors.topMargin: -Style.space(6)
                  anchors.bottomMargin: -Style.space(6)
                  enabled: root.duration > 0
                  cursorShape: Qt.PointingHandCursor
                  onClicked: function(mouse) { root.seekFromClick(mouse.x, width) }
                }
              }
              // The play/pause button sits at the exact center; the others hang off it.
              Item {
                width: parent.width
                height: playButton.height
                Row {
                  anchors.right: playButton.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
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
                }
                Button {
                  id: playButton
                  anchors.horizontalCenter: parent.horizontalCenter
                  iconText: root.playerState === "ended" ? "\uf01e" : root.isPlaying ? "\uf04c" : root.playerState === "buffering" ? "\uf110" : "\uf04b"
                  iconSpinning: root.playerState === "buffering"
                  tooltipText: root.playerState === "ended" ? "Replay" : root.isPlaying ? "Pause" : "Play"
                  onClicked: root.podcasts.togglePlay()
                }
                Button {
                  anchors.left: playButton.right
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "+" + root.skipForward + "s"
                  tooltipText: "Forward " + root.skipForward + " seconds"
                  enabled: root.playerState !== "ended"
                  onClicked: root.podcasts.skip(root.skipForward)
                }
              }
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(8)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.formatClock(root.position) + (root.duration > 0 ? " / " + Model.formatClock(root.duration) : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: root.fs(Style.font.bodySmall)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.playerState === "ended"
                  text: "✓"
                  color: "#2ea043"
                  font.family: root.fontFamily
                  font.pixelSize: root.fs(Style.font.body)
                  font.bold: true
                }
              }
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
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

          // The list keeps a fixed height: more episodes extend what scrolls
          // inside it (wheel, drag or arrow keys) instead of growing the panel.
          Flickable {
            id: listView
            width: parent.width
            height: Math.max(listView.listPeak, Math.min(listColumn.implicitHeight, listView.maxHeight))
            contentHeight: listColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: root.listed.length > 0

            // Tallest the list has been since the panel opened, so loading
            // another page never resizes the window.
            property real listPeak: 0

            // Room for the list: whatever the screen leaves after the rest of
            // the panel (player card, headers, footer). chrome is sampled
            // rather than bound, because content.implicitHeight includes this
            // list and a binding would loop.
            property real chrome: 0
            readonly property real maxHeight: Math.max(Style.space(120),
              panel.availableCardHeight - panel.verticalContentInset - listView.chrome)
            Connections {
              target: content
              function onImplicitHeightChanged() { listView.chrome = content.implicitHeight - listView.height }
            }
            onMaxHeightChanged: listPeak = Math.min(listPeak, maxHeight)
            onContentHeightChanged: listPeak = Math.max(listPeak, Math.min(contentHeight, maxHeight))
            Connections {
              target: root
              function onOpenedChanged() { if (root.opened) listView.listPeak = 0 }
              function onShowPlayedChanged() { listView.listPeak = 0 }
            }

            function revealSelected() {
              var item = rows.itemAt(root.selected)
              if (!item) return
              if (item.y < contentY) contentY = item.y
              else if (item.y + item.height > contentY + height) contentY = item.y + item.height - height
            }
            Connections {
              target: root
              function onSelectedChanged() { listView.revealSelected() }
            }
            onAtYEndChanged: if (atYEnd && moving) root.showMore()

            Column {
              id: listColumn
              width: listView.width
              spacing: Style.space(4)

              Repeater {
                id: rows
                model: root.shown

                Rectangle {
                  id: row
                  required property int index
                  required property var modelData
                  width: parent.width
                  readonly property bool isHeader: row.modelData.isHeader === true
                  // Queue rows follow the QUEUE title and can be dragged to reorder.
                  readonly property bool isQueueRow: !row.isHeader && root.queueEpisodes.length > 0
                    && row.index >= 1 && row.index <= root.queueEpisodes.length
                  property bool dragging: false
                  property real dragOffset: 0
                  readonly property real stride: row.height + listColumn.spacing
                  readonly property int dragFrom: row.index - 1
                  readonly property int dragTo: Math.max(0, Math.min(root.queueEpisodes.length - 1,
                    row.dragFrom + Math.round(row.dragOffset / row.stride)))
                  z: row.dragging ? 10 : 0
                  transform: Translate { y: row.dragOffset }
                  height: row.isHeader ? sectionTitle.implicitHeight + Style.space(10) : rowText.implicitHeight + Style.space(12)
                  radius: Style.space(6)
                  color: row.index === root.selected ? Qt.alpha(root.accent, 0.18) : "transparent"
                  opacity: 0
                  Component.onCompleted: opacity = 1
                  Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

                  // Episodes of one show share the same artwork URL, and Image's pixmap
                  // cache keeps the decoded bitmap in memory, so each icon is fetched
                  // once however many rows use it.
                  // A section's title: folds or unfolds the section.
                  Text {
                    id: sectionTitle
                    visible: row.isHeader
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    text: (root.isCollapsed(row.modelData.section) ? "\u25B8  " : "\u25BE  ") + row.modelData.title
                      + (root.isCollapsed(row.modelData.section) ? "  \u00B7  " + row.modelData.count : "")
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: root.fs(Style.font.bodySmall)
                    font.bold: true
                  }

                  ArtImage {
                    id: rowIcon
                    visible: !row.isHeader && url !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    width: visible ? Style.space(32) : 0
                    height: width
                    service: root.podcasts
                    url: row.modelData.artwork || row.modelData.artworkLarge
                    sourceSize: Qt.size(Style.space(64), Style.space(64))
                  }

                  Column {
                    id: rowText
                    visible: !row.isHeader
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: rowIcon.right
                    anchors.right: parent.right
                    anchors.margins: Style.space(8)
                    anchors.rightMargin: row.isQueueRow ? Style.space(30) : Style.space(8)
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
                      visible: !row.isHeader && !root.showPlayed && root.finishedRecently(row.modelData)
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

                  // Drag handle: reorder the queue by dragging the row up or down.
                  Text {
                    visible: row.isQueueRow
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    text: "\u283F"
                    color: row.dragging || dragArea.containsMouse ? root.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: root.fs(Style.font.body)
                  }
                  MouseArea {
                    id: dragArea
                    visible: row.isQueueRow
                    enabled: row.isQueueRow
                    width: Style.space(30)
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    property real startY: 0
                    function columnY(mouse) { return mapToItem(listColumn, mouse.x, mouse.y).y }
                    onPressed: function(mouse) {
                      startY = columnY(mouse) - row.dragOffset
                      row.dragging = true
                      root.selected = row.index
                    }
                    onPositionChanged: function(mouse) {
                      if (!pressed) return
                      var lo = -row.dragFrom * row.stride
                      var hi = (root.queueEpisodes.length - 1 - row.dragFrom) * row.stride
                      row.dragOffset = Math.max(lo, Math.min(hi, columnY(mouse) - startY))
                    }
                    onReleased: {
                      var to = row.dragTo
                      row.dragging = false
                      row.dragOffset = 0
                      if (to !== row.dragFrom) {
                        root.podcasts.moveInQueue(row.dragFrom, to)
                        root.selected = to + 1
                      }
                    }
                    onCanceled: { row.dragging = false; row.dragOffset = 0 }
                  }
                  // Where the dragged row will land.
                  Rectangle {
                    visible: row.dragging && row.dragTo !== row.dragFrom
                    width: parent.width
                    height: Style.space(2)
                    radius: height / 2
                    color: root.accent
                    y: -row.dragOffset + (row.dragTo - row.dragFrom) * row.stride
                       + (row.dragTo > row.dragFrom ? row.height + listColumn.spacing / 2 : -listColumn.spacing / 2) - height / 2
                  }

                  // Play straight from the list: the icon turns into a button on hover.
                  Rectangle {
                    id: rowPlay
                    anchors.fill: rowIcon
                    visible: !row.isHeader && rowIconHover.containsMouse
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
                    enabled: !row.isHeader
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selected = row.index
                    onClicked: root.podcasts.play(root.listed[row.index])
                  }
                }
              }
            }
          }
        }

        // A quiet arrow that breathes under the list while more is waiting.
        Item {
          width: parent.width
          height: moreText.implicitHeight + Style.space(10)
          visible: root.hasMore
          Text {
            id: moreText
            anchors.centerIn: parent
            anchors.verticalCenterOffset: moreHover.containsMouse ? 0 : bob
            property real bob: 0
            text: "\u25BE  " + Math.min(root.pageSize, root.listed.length - root.visibleCount) + " more"
            color: moreHover.containsMouse ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            SequentialAnimation on opacity {
              running: root.hasMore && root.opened
              loops: Animation.Infinite
              NumberAnimation { from: 0.45; to: 1; duration: 1100; easing.type: Easing.InOutSine }
              NumberAnimation { from: 1; to: 0.45; duration: 1100; easing.type: Easing.InOutSine }
            }
            SequentialAnimation on bob {
              running: root.hasMore && root.opened
              loops: Animation.Infinite
              NumberAnimation { from: 0; to: 2; duration: 1100; easing.type: Easing.InOutSine }
              NumberAnimation { from: 2; to: 0; duration: 1100; easing.type: Easing.InOutSine }
            }
          }
          MouseArea {
            id: moreHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.showMore()
            onWheel: function(wheel) { if (wheel.angleDelta.y < 0) root.showMore(); wheel.accepted = false }
          }
        }

        // -------------------------------------------------------------- footer
        Item {
          width: parent.width
          height: Math.max(footerRow.height, helpButton.implicitHeight)
          visible: root.signedIn

          PanelActionButton {
            id: helpButton
            anchors.right: parent.right
            anchors.verticalCenter: footerRow.verticalCenter
            // nf-fa-question_circle (U+F059)
            iconText: "\uf059"
            tooltipText: "Keyboard shortcuts (?)"
            foreground: root.shortcutsOpen ? root.foreground : root.dim
            hoverColor: root.foreground
            fontSize: root.fs(Style.font.body)
            onClicked: root.shortcutsOpen = !root.shortcutsOpen
          }

        Row {
          id: footerRow
          spacing: Style.space(14)
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

      // ------------------------------------------------ shortcuts cheat sheet
      // Sits over the content instead of in the layout, so opening it never
      // resizes the panel or scrolls the list out from under you.
      Rectangle {
        id: shortcutsSheet
        anchors.fill: parent
        z: 10
        visible: root.shortcutsOpen
        implicitHeight: shortcutsColumn.implicitHeight
        color: Color.popups.background
        radius: Style.space(4)

        HoverHandler {}
        TapHandler { onTapped: root.shortcutsOpen = false }

        Column {
          id: shortcutsColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(6)

          Item {
            width: parent.width
            height: Math.max(shortcutsHeading.implicitHeight, shortcutsClose.implicitHeight)

            Text {
              id: shortcutsHeading
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Keyboard shortcuts"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fs(Style.font.subtitle)
              font.bold: true
            }

            PanelActionButton {
              id: shortcutsClose
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // nf-fa-times (U+F00D)
              iconText: "\uf00d"
              tooltipText: "Close"
              foreground: root.dim
              hoverColor: root.foreground
              fontSize: root.fs(Style.font.bodySmall)
              onClicked: root.shortcutsOpen = false
            }
          }

          Repeater {
            model: root.shortcuts

            Item {
              id: shortcutRow
              required property var modelData

              width: parent.width
              height: Math.max(keyLabel.implicitHeight, whatLabel.implicitHeight)

              Text {
                id: keyLabel
                anchors.left: parent.left
                width: Style.space(Math.round(100 * root.textScale))
                text: shortcutRow.modelData.keys
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
                font.bold: true
              }

              Text {
                id: whatLabel
                anchors.left: keyLabel.right
                anchors.right: parent.right
                text: shortcutRow.modelData.what
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }
}
