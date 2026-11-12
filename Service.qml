import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The one process-wide owner of everything fetched from Apple Podcasts: sign-in
// state, the episode list and the refresh timer. The bar widget exists once per
// monitor; they all read this instead of polling on their own.
Item {
  id: root

  // Injected by the host after load.
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  // A finite helper run. Beyond Process: start() stamps the session it began
  // under (stale: the account changed since, so its result must be dropped) and
  // arms a deadline. A helper still running at the deadline is stopped in
  // bounded steps: terminate, then SIGKILL to it and its whole process group
  // (it runs under setsid, so curl, mpv and the like go with it), then, if even
  // that is not acknowledged, the kill is repeated and the slot stays held until
  // the real exit. One that never reported a start (FailedToStart) gets a
  // synthetic exit. Either way each handler's
  // normal failure path runs, restoring its flags and draining its queue.
  //
  // One child at a time: start() while a run is still winding down queues the
  // new launch, which happens only after the old child's exit was delivered, with
  // a fresh deadline and a fresh session stamp. cancel() winds a run down and
  // drops any queued launch.
  component Op: Process {
    id: op
    property int born: -1
    property int deadlineMs: 120000
    property int graceMs: 2000
    property bool armed: false
    property bool queued: false
    // 0: running normally, 1: terminate sent, 2: killed
    property int phase: 0
    // Set once a signalled run reads as not running without its exit delivered.
    property bool lost: false
    readonly property bool stale: op.born !== root.session
    function start() {
      if (op.armed) { op.queued = true; op.wind(); return }
      op.launch()
    }
    function launch() {
      op.queued = false
      op.born = root.session
      op.armed = true
      op.phase = 0
      op.lost = false
      var c = op.command
      if (c.length > 0 && c[0] !== "/usr/bin/setsid") op.command = ["/usr/bin/setsid", "-w"].concat(c)
      op.watchdog.interval = op.deadlineMs
      op.watchdog.restart()
      op.running = true
    }
    function cancel() {
      op.queued = false
      if (op.armed) op.wind()
    }
    // Moves a live run one step toward being gone and re-arms the timer for the next.
    // A child that is still running is never declared finished: the slot stays
    // occupied (so no replacement starts and forget keeps waiting) and the kill
    // is repeated until the real exit is delivered. A synthetic exit is only for
    // a run with no live child: one that never started, or that is gone but whose
    // exit was not seen within one more grace period.
    function wind() {
      if (!op.armed) return
      if (!op.running) {
        if (op.phase === 0 || op.lost) { op.finish(); return }
        op.lost = true
      } else if (op.phase === 0) { op.phase = 1; op.running = false }
      else {
        op.phase = 2
        if (op.processId > 0) Quickshell.execDetached(["/usr/bin/kill", "-KILL", "--", "-" + op.processId])
        op.signal(9)
      }
      op.watchdog.interval = op.graceMs
      op.watchdog.restart()
    }
    // Completes a run that has no live child, for the caller's failure path.
    function finish() {
      op.watchdog.stop()
      op.exited(-1, 0)
    }
    Component.onCompleted: op.exited.connect(function() {
      var wasArmed = op.armed
      op.armed = false
      op.watchdog.stop()
      Qt.callLater(root.maybeForget)
      // Not before the handlers have run, and only for the child that exited.
      if (wasArmed) Qt.callLater(function() { if (op.queued && !op.armed) op.launch() })
    })
    property Timer watchdog: Timer {
      repeat: false
      onTriggered: op.wind()
    }
  }

  readonly property string api: Model.localPath(Qt.resolvedUrl("bin/podcasts-api"))
  readonly property string player: Model.localPath(Qt.resolvedUrl("bin/podcasts-player"))

  // Pushed in by the bar widget, the only side the shell injects settings into.
  // How many episodes the panel shows at a time; all of them are fetched.
  property int episodeLimit: 10
  property int refreshMinutes: 60
  property string source: "latest"
  // Seconds the skip buttons jump, from the lengths Apple's clients offer.
  property int skipBackSeconds: 15
  property int skipForwardSeconds: 30
  // How the panel orders the list (Model.sortEpisodes): started episodes on
  // top, then by show or by date.
  property bool inProgressFirst: true
  property string sortOrder: "feed"
  property bool groupByFeed: true
  property int keepFinishedDays: 1

  // "unknown" until the first check, then "ok" or "signedOut". "offline" means
  // the request never got through: that keeps the list up rather than asking
  // for a sign-in nothing rejected.
  property string authState: "unknown"
  property bool hasToken: false
  property string storeDir: ""
  property bool loading: false
  property bool saving: false
  property string errorText: ""
  property string signInError: ""
  property var episodes: []
  // Where each listed episode was left, on any device: { id: { ms, completed } }
  // (Model.parsePositions). Playing an episode asks Apple again, so this only
  // has to be good enough to label the list.
  property var positions: ({})
  // Episodes finished on any device, newest first, kept on this machine too
  // (played.json) so they stay listed after the feed moves on. Apple's saved
  // position decides whether one is still played.
  property var playedEpisodes: []
  readonly property int playedLimit: 10
  readonly property var playedSet: {
    var s = ({})
    for (var i = 0; i < root.playedEpisodes.length; i++) s[root.playedEpisodes[i].id] = true
    return s
  }
  readonly property bool authenticated: authState === "ok"

  // Bumped on sign-in and forget so a result fetched under old credentials
  // never lands after them.
  property int session: 0
  property bool refreshQueued: false
  property bool playedDirty: false

  onSourceChanged: refreshSoon()
  onRefreshMinutesChanged: timer.restart()

  onEpisodesChanged: { root.syncPlayed(); root.restoreNowPlaying() }
  onPlayedEpisodesChanged: root.restoreNowPlaying()
  onPositionsChanged: root.syncPlayed()

  // mpv only remembers an episode's title (cut to what the player script
  // keeps), so an episode adopted after a shell reload is matched back to the
  // known ones by it to recover its artwork, show and id.
  function knownEpisodeByTitle(title) {
    var t = String(title).replace(/[\x00-\x1F\x7F]/g, "").slice(0, 200)
    var all = root.episodes.concat(root.playedEpisodes)
    for (var i = 0; i < all.length; i++)
      if (all[i].title.replace(/[\x00-\x1F\x7F]/g, "").slice(0, 200) === t) return all[i]
    return null
  }

  function restoreNowPlaying() {
    var e = root.nowPlaying
    if (!e || e.id !== "" || e.title === "") return
    var known = root.knownEpisodeByTitle(e.title)
    if (known) { root.nowPlaying = known; return }
    // Not in any loaded list: fall back to the episode kept on disk.
    var kept = root.keptNowPlaying
    if (kept && kept.title.replace(/[\x00-\x1F\x7F]/g, "").slice(0, 200) === e.title) root.nowPlaying = kept
  }

  property var keptNowPlaying: null

  onNowPlayingChanged: {
    var e = root.nowPlaying
    if (!root.hasToken || !e || e.id === "") return
    nowSaveProcess.payload = JSON.stringify(e)
    if (root.forgetting) return
    nowSaveProcess.stdinEnabled = true
    nowSaveProcess.command = ["/usr/bin/bash", root.api, "saveplayed", "now"]
    nowSaveProcess.start()
  }

  // Played: episodes Apple reports as completed (from the feed or the one
  // playing), then those already kept that Apple has not marked unfinished.
  function syncPlayed() {
    var cands = root.episodes.concat(root.nowPlaying ? [root.nowPlaying] : [])
    var seen = ({}), next = []
    cands.forEach(function(e) {
      var pos = root.positions[e.id]
      if (e.id && pos && pos.completed === true && !seen[e.id]) { seen[e.id] = true; next.push(e) }
    })
    root.playedEpisodes.forEach(function(e) {
      var pos = root.positions[e.id]
      if (seen[e.id] || (pos && pos.completed === false)) return
      seen[e.id] = true
      next.push(e)
    })
    // Most recently finished first (the position's timestamp), at most playedLimit.
    var when = function(e) { var pos = root.positions[e.id]; return pos && pos.at > 0 ? pos.at : 0 }
    next = next.map(function(e, i) { return { e: e, i: i } })
      .sort(function(a, b) { return when(b.e) - when(a.e) || a.i - b.i })
      .slice(0, root.playedLimit).map(function(x) { return x.e })
    var same = next.length === root.playedEpisodes.length && next.every(function(e, i) { return e.id === root.playedEpisodes[i].id })
    if (same) return
    root.playedEpisodes = next
    root.savePlayed()
  }

  function savePlayed() {
    if (!root.hasToken || root.forgetting) return
    if (playedSaveProcess.running) { root.playedDirty = true; return }
    playedSaveProcess.payload = JSON.stringify(root.playedEpisodes)
    playedSaveProcess.command = ["/usr/bin/bash", root.api, "saveplayed"]
    playedSaveProcess.stdinEnabled = true
    playedSaveProcess.start()
  }

  // ---------------------------------------------------------------- artwork
  // Artwork is fetched one image at a time by `podcasts-api art` (bounded in
  // bytes, time and redirects) and shown from its cached local file; the UI's
  // image loader never touches the network. url -> file:// path.
  property var artPaths: ({})
  property var artQueue: []
  property var artFailed: ({})
  readonly property int artQueueMax: 40
  // Matches the 100 images bin/podcasts-api keeps on disk: a path that fell out
  // of that cache is forgotten here too, and fetched again if it is shown again.
  readonly property int artKeep: 100

  // A copy of the map plus one entry, oldest entries dropped past max.
  function withArt(map, key, value, max) {
    var next = Object.assign({}, map)
    delete next[key]
    next[key] = value
    var keys = Object.keys(next)
    for (var i = 0; i < keys.length - max; i++) delete next[keys[i]]
    return next
  }

  function requestArt(url) {
    var u = Model.httpUrl(url)
    if (u === "" || root.artPaths[u] !== undefined || root.artFailed[u] === true) return
    if (root.artQueue.indexOf(u) >= 0 || (artProcess.armed && artProcess.url === u)) return
    if (root.artQueue.length >= root.artQueueMax) return
    root.artQueue = root.artQueue.concat([u])
    root.nextArt()
  }

  function nextArt() {
    if (root.forgetting || artProcess.armed || root.artQueue.length === 0) return
    var u = root.artQueue[0]
    root.artQueue = root.artQueue.slice(1)
    artProcess.url = u
    artProcess.command = ["/usr/bin/bash", root.api, "art", u]
    artProcess.start()
  }

  function refreshSoon() { if (authState === "ok") Qt.callLater(refresh) }

  function checkConfig() {
    if (configProcess.running) return
    configProcess.command = ["/usr/bin/bash", root.api, "config"]
    configProcess.start()
  }

  function refresh() {
    if (!root.hasToken) { root.checkConfig(); return }
    if (episodesProcess.running) { root.refreshQueued = true; return }
    root.loading = true
    episodesProcess.session = root.session
    episodesProcess.command = ["/usr/bin/bash", root.api, "episodes",
      String(Model.episodeLimitMax), Model.knownSource(root.source)]
    episodesProcess.start()
  }

  // Stores the pasted media-user-token, then loads the list with it.
  function signIn(token) {
    if (saveProcess.running) return
    if (root.forgetting) { root.signInError = "Still signing out; try again in a moment."; return }
    root.saving = true
    root.signInError = ""
    saveProcess.session = ++root.session
    saveProcess.payload = String(token || "").replace(/[\r\n]/g, "").trim() + "\n"
    saveProcess.command = ["/usr/bin/bash", root.api, "save"]
    saveProcess.stdinEnabled = true
    saveProcess.start()
  }

  // Forget, in a defined order: the session is bumped (so every result still in
  // flight is stale), all work of the old session is cancelled, and only once
  // no writer is left running does the script delete the store. Nothing queued
  // under the old session survives, and nothing may start a write until the
  // deletion has finished (forgetting).
  property bool forgetting: false

  function forget() {
    root.session++
    root.forgetting = true
    root.hasToken = false
    root.authState = "signedOut"
    root.saving = false
    root.loading = false
    root.playedDirty = false
    root.queueDirty = false
    root.refreshQueued = false
    root.pendingPush = []
    root.localQueue = []
    root.localKey = ""
    root.playedEpisodes = []
    root.episodes = []
    root.positions = ({})
    root.pushedKey = ""
    root.queue = []
    root.keptNowPlaying = null
    root.artPaths = ({})
    root.artQueue = []
    root.artFailed = ({})
    root.errorText = ""
    var cancel = [saveProcess, nowSaveProcess, queueSaveProcess, playedSaveProcess, localSaveProcess, putProcess,
      episodesProcess, positionsProcess, localLoadProcess, playedGetProcess, nowGetProcess, configProcess, artProcess]
    for (var i = 0; i < cancel.length; i++) cancel[i].cancel()
    root.maybeForget()
  }

  function maybeForget() {
    if (!root.forgetting || forgetProcess.armed) return
    var writers = [saveProcess, nowSaveProcess, queueSaveProcess, playedSaveProcess, localSaveProcess, putProcess, artProcess]
    for (var i = 0; i < writers.length; i++) if (writers[i].armed) return
    forgetProcess.command = ["/usr/bin/bash", root.api, "forget"]
    forgetProcess.start()
  }

  function setPositions(next) { root.positions = Model.capPositions(next) }

  // Merges positions by whichever record is newer, so neither Apple's answer nor
  // this machine's file wipes out the other.
  function mergePositions(found) {
    var next = Object.assign({}, root.positions)
    for (var id in found) next[id] = Model.newerPosition(found[id], next[id] || null)
    root.setPositions(next)
  }

  function refreshPositions() {
    if (root.episodes.length === 0) return
    var ids = root.episodes.slice(0, Model.episodeLimitMax).map(function(e) { return e.id }).filter(function(id) { return /^[0-9]+$/.test(id) })
    if (ids.length === 0) return
    // This machine's own record first: it needs no network or sign-in.
    if (!localLoadProcess.running) {
      localLoadProcess.session = root.session
      localLoadProcess.command = ["/usr/bin/bash", root.api, "getposall", ids.join(",")]
      localLoadProcess.start()
    }
    if (!root.hasToken || positionsProcess.running) return
    positionsProcess.session = root.session
    positionsProcess.command = ["/usr/bin/bash", root.api, "positions", ids.join(",")]
    positionsProcess.start()
  }

  // Only web URLs reach the browser: the feed must not be able to launch
  // whatever handler the desktop has for some other scheme.
  function openUrl(url) {
    var u = Model.httpUrl(url)
    if (u) Qt.openUrlExternally(u)
  }

  // ---------------------------------------------------------------- playback
  // The episode being played, or null. "idle" until something is started, then
  // "buffering", "playing", "paused" or "ended" (mpv exited: the episode ran
  // out, or was stopped).
  property var nowPlaying: null
  property string playerState: "idle"
  property real position: 0
  property real duration: 0
  property string playError: ""
  // Kept across episodes and restarts (the player script stores it), so a
  // chosen speed sticks until it is changed.
  property real speed: 1
  // Whether a panel is showing the player, which is when a once-a-second
  // clock is worth the process it costs.
  property bool playerVisible: false
  readonly property bool playbackActive: nowPlaying !== null
    && (playerState === "playing" || playerState === "paused" || playerState === "buffering")

  // Control commands (toggle, seek, stop) run one after another, so a quick
  // second press of a skip button is queued instead of dropped.
  property var controlQueue: []

  // True from the click on an episode until mpv is up: Apple is asked where you
  // left off first, and the old audio's clock must not be read as the new one's.
  property bool starting: false
  // The last position Apple accepted ("id:ms:done"), when it was sent, and one
  // waiting for the request in flight to finish.
  property string pushedKey: ""
  property real lastPushAt: 0
  property var pendingPush: []
  // Positions are also kept on this machine (podcasts-api savepos), written the
  // moment they are known, so a slow or refused PUT never costs the place.
  property var localQueue: []
  property string localKey: ""
  readonly property int pushEveryMs: 15000

  function sameEpisode(a, b) { return a && b && a.id !== "" && a.id === b.id }

  // Episodes lined up to start by themselves, in order, once the one playing
  // has ended. Saved to queue.json so it survives a shell restart.
  property var queue: []
  property bool queueDirty: false

  // Kept in queue.json so the queue survives a shell restart.
  onQueueChanged: root.saveQueue()

  function saveQueue() {
    if (root.forgetting) return
    if (queueSaveProcess.running) { root.queueDirty = true; return }
    queueSaveProcess.payload = JSON.stringify(root.queue)
    queueSaveProcess.command = ["/usr/bin/bash", root.api, "saveplayed", "queue"]
    queueSaveProcess.stdinEnabled = true
    queueSaveProcess.start()
  }

  // Adds an episode to the end of the queue. With nothing playing there is
  // nothing to wait for, so it starts right away.
  function enqueue(episode) {
    if (!episode) return
    if (!root.playbackActive || root.playerState === "ended") { root.queue = root.queue.filter(function(q) { return !root.sameEpisode(q, episode) }); root.play(episode); return }
    if (root.sameEpisode(root.nowPlaying, episode)) return
    if (root.queue.some(function(q) { return root.sameEpisode(q, episode) })) return
    root.queue = root.queue.concat([episode])
  }

  // Takes an episode out of the queue.
  function dequeue(episode) {
    if (!episode) return
    root.queue = root.queue.filter(function(q) { return !root.sameEpisode(q, episode) })
  }

  // Moves a queued episode to another place in the queue (0-based positions).
  function moveInQueue(from, to) {
    if (from === to || from < 0 || from >= root.queue.length) return
    to = Math.max(0, Math.min(root.queue.length - 1, to))
    var q = root.queue.slice()
    q.splice(to, 0, q.splice(from, 1)[0])
    root.queue = q
  }

  function playNext() {
    while (root.queue.length > 0) {
      var next = root.queue[0]
      root.queue = root.queue.slice(1)
      if (Model.httpUrl(next.assetUrl)) { root.nowPlaying = null; root.play(next); return }
    }
  }

  function play(episode) {
    if (!episode) return
    if (root.sameEpisode(root.nowPlaying, episode) && root.playbackActive) return
    if (!Model.httpUrl(episode.assetUrl)) {
      root.playError = "Apple lists no audio file for this episode (it may be subscriber-only)."
      return
    }
    root.playError = ""
    // Leave the episode being replaced where it got to, and silence it now
    // rather than after the lookup below.
    if (root.playbackActive && !root.sameEpisode(root.nowPlaying, episode)) {
      root.pushPosition()
      root.control(["stop"])
    }
    root.nowPlaying = episode
    root.playerState = "buffering"
    root.position = 0
    root.duration = Number(episode.durationMs) / 1000 || 0
    root.starting = true
    root.fetchResume()
  }

  // Asks Apple where the episode being started was left (on the phone, say) and
  // starts it there. Any failure just means starting from the top.
  function fetchResume() {
    var e = root.nowPlaying
    if (!e || resumeProcess.running) return
    resumeProcess.episode = e
    if (!/^[0-9]+$/.test(e.id)) { root.launch(e, 0); return }
    if (!root.hasToken) { root.resolveResume(e, null); return }
    resumeProcess.command = ["/usr/bin/bash", root.api, "positions", e.id]
    resumeProcess.start()
  }

  // Apple's answer and this machine's record, whichever is newer, then start.
  function resolveResume(e, apple) {
    resumeProcess.apple = apple
    localGetProcess.episode = e
    localGetProcess.command = ["/usr/bin/bash", root.api, "getpos", e.id]
    localGetProcess.start()
  }

  function launch(episode, seconds) {
    root.position = seconds
    playProcess.command = ["/usr/bin/bash", root.player, "play", episode.assetUrl, episode.title, String(seconds)]
    playProcess.start()
  }

  // Tells Apple how far the current episode has got, so that the phone and any
  // other device resume from here. An episode adopted after a shell reload has no
  // id and is not reported. Skips what Apple already has.
  function pushPosition() {
    var e = root.nowPlaying
    if (!e || !/^[0-9]+$/.test(e.id) || root.starting) return
    if (root.playerState !== "playing" && root.playerState !== "paused" && root.playerState !== "ended") return
    var done = Model.isFinished(root.position, root.duration)
    var ms = Math.round((done ? root.duration : root.position) * 1000)
    if (ms <= 0) return
    var key = e.id + ":" + ms + ":" + done
    if (key === root.pushedKey) return
    root.saveLocal(e.id, ms, done)
    if (!root.hasToken) return
    // One slot per episode: switching episodes must not lose the old one's.
    root.pendingPush = root.pendingPush.filter(function(p) { return p.id !== e.id })
      .concat([{ id: e.id, ms: ms, done: done, key: key }]).slice(-50)
    root.flushPush()
  }

  // Marks an episode finished without playing it, here and on Apple. Without a
  // known duration the position is a nominal second, which Apple still treats as
  // completed.
  function markPlayed(e) {
    if (!e || !/^[0-9]+$/.test(e.id)) return
    var ms = e.durationMs > 0 ? Math.round(e.durationMs) : 1000
    root.saveLocal(e.id, ms, true)
    if (!root.hasToken) return
    root.pendingPush = root.pendingPush.filter(function(p) { return p.id !== e.id })
      .concat([{ id: e.id, ms: ms, done: true, key: e.id + ":" + ms + ":true" }]).slice(-50)
    root.flushPush()
  }

  function saveLocal(id, ms, done) {
    var key = id + ":" + ms + ":" + done
    if (key === root.localKey) return
    root.localKey = key
    var next = Object.assign({}, root.positions)
    next[id] = { ms: ms, completed: done, at: Date.now() }
    root.setPositions(next)
    root.localQueue = root.localQueue.filter(function(q) { return q[0] !== id })
      .concat([[id, String(ms), done ? "true" : "false"]]).slice(-50)
    root.nextLocal()
  }

  function nextLocal() {
    if (root.forgetting || localSaveProcess.running || root.localQueue.length === 0) return
    var q = root.localQueue[0]
    root.localQueue = root.localQueue.slice(1)
    localSaveProcess.command = ["/usr/bin/bash", root.api, "savepos"].concat(q)
    localSaveProcess.start()
  }

  function flushPush() {
    if (putProcess.running || root.pendingPush.length === 0) return
    putProcess.sent = root.pendingPush[0]
    root.pendingPush = root.pendingPush.slice(1)
    root.lastPushAt = Date.now()
    putProcess.command = ["/usr/bin/bash", root.api, "setposition", putProcess.sent.id,
      String(putProcess.sent.ms), putProcess.sent.done ? "true" : "false"]
    putProcess.start()
  }

  function togglePlay() {
    if (!root.nowPlaying) return
    if (root.playerState === "ended") { root.replay(); return }
    root.playerState = root.playerState === "paused" ? "playing" : "paused"
    root.control(["toggle"])
  }

  // Seconds relative to now; negative goes back. The clock moves at once and
  // the next status poll corrects it.
  function skip(seconds) {
    if (!root.playbackActive) return
    root.position = Math.max(0, Math.min(root.duration > 0 ? root.duration : 1e9, root.position + seconds))
    root.control(["seek", String(Math.round(seconds))])
  }

  function seekTo(seconds) {
    if (!root.playbackActive) return
    root.position = Math.max(0, seconds)
    root.control(["seekto", String(Math.round(Math.max(0, seconds)))])
  }

  function setSpeed(rate) {
    root.speed = Model.knownSpeed(rate)
    root.control(["speed", String(root.speed)])
  }

  function replay() {
    var e = root.nowPlaying
    if (!e || !e.assetUrl) return
    root.nowPlaying = null
    root.play(e)
  }

  function stopPlayback() {
    if (root.playbackActive) root.pushPosition()
    root.starting = false
    root.controlQueue = []
    root.queue = []
    controlProcess.command = ["/usr/bin/bash", root.player, "stop"]
    controlProcess.start()
    root.nowPlaying = null
    root.playerState = "idle"
    root.position = 0
    root.duration = 0
  }

  function control(args) {
    // Bounded: a stuck helper must not let key-repeat grow this without end.
    root.controlQueue = root.controlQueue.concat([args]).slice(-16)
    root.nextControl()
  }

  function nextControl() {
    if (controlProcess.running || root.controlQueue.length === 0) return
    var args = root.controlQueue[0]
    root.controlQueue = root.controlQueue.slice(1)
    controlProcess.command = ["/usr/bin/bash", root.player].concat(args)
    controlProcess.start()
  }

  function pollPlayer() {
    if (statusProcess.running || playProcess.running || root.starting) return
    statusProcess.command = ["/usr/bin/bash", root.player, "status"]
    statusProcess.start()
  }

  // On load, also look for audio still running from before a shell reload:
  // mpv is detached, so it outlives us.
  Component.onCompleted: {
    queueGetProcess.command = ["/usr/bin/bash", root.api, "getplayed", "queue"]
    queueGetProcess.start()
    root.checkConfig(); root.loadSpeed(); root.pollPlayer() }

  function loadSpeed() {
    speedProcess.command = ["/usr/bin/bash", root.player, "getspeed"]
    speedProcess.start()
  }

  Timer {
    id: timer
    interval: Model.snapRefreshMinutes(root.refreshMinutes) * 60000
    repeat: true
    running: root.authState === "ok" || root.authState === "offline"
    onTriggered: root.refresh()
  }

  // While offline, retries on a growing delay (5s up to the refresh interval)
  // instead of waiting out the whole refresh timer with an error on screen.
  property int retryAttempt: 0
  onAuthStateChanged: { if (authState !== "offline") retryAttempt = 0 }

  Timer {
    id: retryTimer
    interval: Math.min(5000 * Math.pow(2, root.retryAttempt), 300000)
    running: root.authState === "offline" && !root.loading
    onTriggered: { root.retryAttempt++; root.refresh() }
  }

  // Polls mpv while there is something to show: every second with the player
  // up, every few seconds otherwise, so playback ending is still noticed.
  Timer {
    interval: root.playerVisible ? 1000 : 5000
    repeat: true
    running: root.nowPlaying !== null && root.playerState !== "ended"
    onTriggered: root.pollPlayer()
  }

  Op {
    id: playProcess
    deadlineMs: 15000
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stderr: StdioCollector { id: playErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.starting = false
      if (exitCode !== 0) {
        root.playError = Model.playMessage(playErr.text, exitCode)
        root.nowPlaying = null
        root.playerState = "idle"
        return
      }
      // mpv was started at the remembered speed; this keeps it in step.
      root.control(["speed", String(root.speed)])
      root.pollPlayer()
    }
  }

  Op {
    id: speedProcess
    deadlineMs: 15000
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: speedOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && !root.nowPlaying) root.speed = Model.knownSpeed(speedOut.text.trim())
    }
  }

  Op {
    id: controlProcess
    deadlineMs: 15000
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    onExited: function(exitCode) {
      if (root.controlQueue.length > 0) Qt.callLater(root.nextControl)
      else Qt.callLater(root.pollPlayer)
    }
  }

  Op {
    id: statusProcess
    deadlineMs: 15000
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      var st = exitCode === 0 ? Model.parseStatus(statusOut.text) : null
      if (!st) {
        // mpv is gone. If we were playing, the episode is over (or was
        // stopped from outside); keep it on screen so it can be replayed.
        if (root.nowPlaying && root.playerState !== "idle" && root.playerState !== "buffering") {
          root.playerState = "ended"
          root.pushPosition()
          root.playNext()
        }
        return
      }
      var adopted = !root.nowPlaying
      if (adopted)
        // Adopted after a shell reload: all that is known is the title.
        root.nowPlaying = { id: "", title: st.title, show: "", published: "", url: "",
          artwork: "", artworkLarge: "", assetUrl: "", durationMs: 0 }
        root.restoreNowPlaying()
      root.position = st.position
      // Our speed is the setting; mpv's only wins for audio adopted after a reload.
      if (adopted) root.speed = st.speed
      if (st.duration > 0) root.duration = st.duration
      root.playerState = st.buffering ? "buffering" : st.paused ? "paused" : "playing"
      if (root.playerState === "paused" || (root.playerState === "playing" && Date.now() - root.lastPushAt >= root.pushEveryMs))
        root.pushPosition()
    }
  }

  Op {
    id: configProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (configProcess.stale) return
      var info = {}
      try { info = JSON.parse(configOut.text) } catch (e) { info = {} }
      root.hasToken = info.hasToken === true
      root.storeDir = Model.text(info.store)
      if (root.hasToken) { root.refresh(); playedGetProcess.command = ["/usr/bin/bash", root.api, "getplayed"]; playedGetProcess.start(); nowGetProcess.command = ["/usr/bin/bash", root.api, "getplayed", "now"]; nowGetProcess.start() }
      else root.authState = "signedOut"
    }
  }

  Op {
    id: playedGetProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: playedGetOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (playedGetProcess.stale) return
      var kept = []
      try { kept = JSON.parse(playedGetOut.text) } catch (e) { kept = [] }
      if (!Array.isArray(kept)) return
      var have = root.playedSet
      // The file is this plugin's own, but it is checked like the feed: a
      // stored URL is only used if it is still a web URL.
      var extra = kept.map(Model.sanitizeEpisode).filter(function(e) { return e.id !== "" && !have[e.id] })
      if (extra.length === 0) return
      root.playedEpisodes = root.playedEpisodes.concat(extra).slice(0, root.playedLimit)
      root.refreshPositions()
    }
  }

  Op {
    id: nowSaveProcess
    property string payload: ""
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdinEnabled: true
    onStarted: { write(payload); payload = ""; stdinEnabled = false }
  }

  Op {
    id: nowGetProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: nowGetOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (nowGetProcess.stale) return
      var o = null
      try { o = JSON.parse(nowGetOut.text) } catch (e) { o = null }
      if (!o || typeof o !== "object") return
      var ep = Model.sanitizeEpisode(o)
      if (ep.id === "") return
      root.keptNowPlaying = ep
      root.restoreNowPlaying()
    }
  }

  Op {
    id: queueGetProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: queueGetOut; waitForEnd: true }
    onExited: function(exitCode) {
      var kept = []
      try { kept = JSON.parse(queueGetOut.text) } catch (e) { kept = [] }
      if (!Array.isArray(kept)) return
      var have = root.queue
      var extra = kept.map(Model.sanitizeEpisode).filter(function(e) {
        return e.id !== "" && !have.some(function(q) { return q.id === e.id })
      })
      if (extra.length > 0) root.queue = extra.concat(have)
    }
  }

  Op {
    id: queueSaveProcess
    property string payload: ""
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdinEnabled: true
    onStarted: { write(payload); payload = ""; stdinEnabled = false }
    onExited: function(exitCode) {
      if (root.queueDirty) { root.queueDirty = false; Qt.callLater(root.saveQueue) }
    }
  }

  Op {
    id: playedSaveProcess
    property string payload: ""
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (root.playedDirty) { root.playedDirty = false; Qt.callLater(root.savePlayed) }
    }
  }

  Op {
    id: saveProcess
    property int session: 0
    property string payload: ""
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdinEnabled: true
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.saving = false
      if (saveProcess.session !== root.session) return
      if (exitCode !== 0) {
        root.signInError = Model.text(saveErr.text).trim().slice(0, 200) || "Could not store the token."
        return
      }
      root.hasToken = true
      root.authState = "unknown"
      root.refresh()
    }
  }

  Op {
    id: artProcess
    property string url: ""
    deadlineMs: 30000
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: artOut; waitForEnd: true }
    onExited: function(exitCode) {
      var path = Model.text(artOut.text).trim()
      if (!artProcess.stale) {
        if (exitCode === 0 && /^\/[A-Za-z0-9\/._-]+$/.test(path)) {
          root.artPaths = root.withArt(root.artPaths, artProcess.url, "file://" + path, root.artKeep)
        } else {
          root.artFailed = root.withArt(root.artFailed, artProcess.url, true, root.artKeep)
        }
      }
      Qt.callLater(root.nextArt)
    }
  }

  Op {
    id: forgetProcess
    deadlineMs: 30000
    onExited: function(exitCode) { root.forgetting = false }
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
  }

  Op {
    id: resumeProcess
    property var episode: null
    property var apple: null
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: resumeOut; waitForEnd: true }
    onExited: function(exitCode) {
      var e = root.nowPlaying
      // Stopped meanwhile: nothing to start. Another episode picked: look that one up.
      if (!e || !root.starting) return
      if (!root.sameEpisode(e, resumeProcess.episode)) { root.fetchResume(); return }
      var response = Model.splitResponse(resumeOut.text)
      var found = exitCode === 0 && !resumeProcess.stale && response.status === 200 ? Model.parsePositions(response.body) : null
      root.resolveResume(e, found ? found[e.id] : null)
    }
  }

  Op {
    id: localGetProcess
    property var episode: null
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: localGetOut; waitForEnd: true }
    onExited: function(exitCode) {
      var e = root.nowPlaying
      if (!e || !root.starting) return
      if (!root.sameEpisode(e, localGetProcess.episode)) { root.fetchResume(); return }
      // What was just played here may not have reached the file or Apple yet.
      var mem = root.positions[e.id]
      var local = Model.newerPosition(exitCode === 0 && !localGetProcess.stale ? Model.parseLocalPosition(localGetOut.text) : null, mem && mem.at > 0 ? mem : null)
      var pos = Model.newerPosition(resumeProcess.apple, local)
      if (pos) {
        var next = Object.assign({}, root.positions)
        next[e.id] = pos
        root.setPositions(next)
      }
      root.launch(e, Model.resumeSeconds(pos, e.durationMs))
    }
  }

  Op {
    id: localSaveProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    onExited: function(exitCode) { if (root.localQueue.length > 0) Qt.callLater(root.nextLocal) }
  }

  Op {
    id: putProcess
    property var sent: null
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: putOut; waitForEnd: true }
    onExited: function(exitCode) {
      var status = Model.splitResponse(putOut.text).status
      if (!putProcess.stale && exitCode === 0 && status >= 200 && status < 300 && putProcess.sent) {
        var s = putProcess.sent
        root.pushedKey = s.key
        var next = Object.assign({}, root.positions)
        next[s.id] = { ms: s.ms, completed: s.done, at: Date.now() }
        root.setPositions(next)
      }
      // A failure is retried by the next push, which finds the key unsent.
      if (root.pendingPush.length > 0) Qt.callLater(root.flushPush)
    }
  }

  Op {
    id: positionsProcess
    property int session: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: positionsOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (positionsProcess.session !== root.session) return
      var response = Model.splitResponse(positionsOut.text)
      var found = exitCode === 0 && response.status === 200 ? Model.parsePositions(response.body) : null
      if (found) root.mergePositions(found)
    }
  }

  Op {
    id: localLoadProcess
    property int session: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: localLoadOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (localLoadProcess.session !== root.session || exitCode !== 0) return
      root.mergePositions(Model.parseLocalPositions(localLoadOut.text))
    }
  }

  Op {
    id: episodesProcess
    property int session: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: episodesOut; waitForEnd: true }
    stderr: StdioCollector { id: episodesErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      var stale = episodesProcess.session !== root.session
      var response = Model.splitResponse(episodesOut.text)
      if (!stale) {
        if (Model.isAuthFailure(exitCode, response.status)) {
          root.authState = "signedOut"
          root.signInError = Model.errorMessage(episodesErr.text, exitCode, response.status)
          root.episodes = []
        } else if (exitCode === 0 && response.status === 200) {
          var parsed = Model.parseEpisodes(response.body)
          root.authState = "ok"
          if (parsed.ok) { root.artFailed = ({}); root.episodes = parsed.episodes; root.errorText = ""; root.refreshPositions() }
          else root.errorText = parsed.error
        } else {
          root.authState = Model.isTransient(exitCode, response.status) ? "offline" : "ok"
          root.errorText = Model.errorMessage(episodesErr.text, exitCode, response.status)
        }
      }
      if (root.refreshQueued) { root.refreshQueued = false; Qt.callLater(root.refresh) }
    }
  }
}
