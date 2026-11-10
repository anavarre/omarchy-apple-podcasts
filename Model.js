.pragma library

// Pure helpers shared by Service.qml, Panel.qml and BarWidget.qml, kept free of
// QML types so they can be unit-tested with node (tests/model.test.js).

var episodeLimitMin = 1
var episodeLimitMax = 30
var refreshChoices = [30, 60, 120, 180, 360, 720, 1440]
var sources = ["latest", "up-next"]
// How the unplayed list is ordered once anything in progress is pinned on top.
var sortOrders = ["feed", "date"]
// How many days a finished episode stays listed, with a check mark.
var keepDaysChoices = [1, 3, 7]
var textSizeValues = ["small", "medium", "large", "xlarge"]
// The skip lengths Apple's own clients offer.
// Playback speeds on offer, slowest first.
var speedChoices = [0.8, 1, 1.3, 1.5, 1.8, 2]
var skipChoices = [10, 15, 30, 45, 60, 75, 90]

// The environment bin/podcasts-api is run with. A null value means "inherit
// this one from the shell"; everything else is dropped (clearEnvironment).
var environment = {
  PATH: "/usr/bin:/bin",
  HOME: null,
  XDG_CONFIG_HOME: null,
  PODCASTS_PLUGIN_DIR: null,
  PODCASTS_API_BASE: null,
  PODCASTS_PLAYER_DIR: null,
  PODCASTS_MPV_AO: null,
  XDG_RUNTIME_DIR: null,
  PULSE_SERVER: null,
  PULSE_RUNTIME_PATH: null,
  PIPEWIRE_RUNTIME_DIR: null,
  PODCASTS_WEB_BASE: null,
  https_proxy: null,
  HTTPS_PROXY: null,
  http_proxy: null,
  all_proxy: null,
  ALL_PROXY: null,
  no_proxy: null,
  NO_PROXY: null,
  SSL_CERT_FILE: null,
  SSL_CERT_DIR: null,
  CURL_CA_BUNDLE: null
}

function localPath(url) {
  var s = String(url || "")
  if (s.indexOf("file://") !== 0) return ""
  try {
    return decodeURIComponent(s.slice("file://".length))
  } catch (e) {
    return ""
  }
}

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

// Only a web URL may be opened in the browser, loaded as artwork or handed to
// mpv. Anything else that arrives in the feed or the played list (file://,
// javascript:, a custom scheme another app has registered, quotes or control
// characters) is dropped rather than passed on.
function httpUrl(value) {
  var s = text(value).trim()
  if (s.length > maxUrlLength) return ""
  return /^https?:\/\/[^\s\x00-\x1F\x7F"<>\\]+$/i.test(s) ? s : ""
}

// Limits on what is retained from a feed (or a stored file), applied before
// anything reaches the UI: Apple was asked for episodeLimitMax, but the answer
// is not trusted to honour that.
var maxUrlLength = 2048
var maxTextLength = 500
var maxPositions = 500

// Keeps the `max` most recently recorded positions of { id: { at, ... } }.
function capPositions(map, max) {
  var ids = Object.keys(map || {})
  var limit = max === undefined ? maxPositions : max
  if (ids.length <= limit) return map
  ids.sort(function(a, b) { return (map[b].at || 0) - (map[a].at || 0) })
  var out = {}
  for (var i = 0; i < limit; i++) out[ids[i]] = map[ids[i]]
  return out
}

function limitedText(value) {
  var s = text(value)
  return s.length > maxTextLength ? s.slice(0, maxTextLength) : s
}

// Apple's episode ids are decimal numbers, and that is all the scripts accept
// and all that is safe as a key of the positions maps ("__proto__" is not).
function episodeId(value) {
  var s = text(value)
  return /^[0-9]+$/.test(s) ? s : ""
}

function clampEpisodeLimit(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 10
  return Math.max(episodeLimitMin, Math.min(episodeLimitMax, n))
}

function snapRefreshMinutes(value) {
  var n = Number(value)
  if (!isFinite(n)) return refreshChoices[0]
  for (var i = 0; i < refreshChoices.length; i++)
    if (refreshChoices[i] >= n) return refreshChoices[i]
  return refreshChoices[refreshChoices.length - 1]
}

function knownSkip(value, fallback) {
  var n = Number(value)
  return skipChoices.indexOf(n) >= 0 ? n : fallback
}

function knownSpeed(value) {
  var n = Number(value)
  return speedChoices.indexOf(n) >= 0 ? n : 1
}

// 1 -> "x1", 1.3 -> "x1,3": decimal comma, as the speeds are written for this plugin.
function formatSpeed(value) {
  return "x" + String(knownSpeed(value)).replace(".", ",")
}

function knownSource(value) {
  return sources.indexOf(value) >= 0 ? value : "latest"
}

function knownSortOrder(value) {
  return sortOrders.indexOf(value) >= 0 ? value : "feed"
}

function knownKeepDays(value) {
  var n = Number(value)
  return keepDaysChoices.indexOf(n) >= 0 ? n : 1
}

function knownTextSize(value) {
  return textSizeValues.indexOf(value) >= 0 ? value : "medium"
}

// bin/podcasts-api prints the response body, then a final line "HTTP <status>".
function splitResponse(out) {
  var s = text(out)
  var cut = s.lastIndexOf("\nHTTP ")
  var head = cut >= 0 ? s.slice(0, cut) : ""
  var tail = cut >= 0 ? s.slice(cut + 1) : s
  var m = /^HTTP (\d{3})\s*$/.exec(tail)
  if (!m) return { status: 0, body: s }
  return { status: Number(m[1]), body: head }
}

// Apple's amp-api answers { data: [ { id, type, attributes: {...} } ] }. The
// attribute names below are the ones the web app reads; each has a fallback so
// a renamed field degrades to a blank rather than an exception.
function artworkUrl(artwork, size) {
  var u = artwork && artwork.url ? String(artwork.url) : ""
  return u.replace("{w}", size).replace("{h}", size).replace("{f}", "jpg")
}

// An episode as the plugin keeps it, with every field checked: ids numeric,
// URLs http(s), the rest plain strings. Applied to Apple's answer and again to
// what comes back from played.json, so a stored entry is held to the same rule.
function sanitizeEpisode(e) {
  var o = e && typeof e === "object" ? e : {}
  var dur = Number(o.durationMs)
  return {
    id: episodeId(o.id),
    title: limitedText(o.title),
    show: limitedText(o.show),
    published: limitedText(o.published).slice(0, 64),
    url: httpUrl(o.url),
    artwork: httpUrl(o.artwork),
    artworkLarge: httpUrl(o.artworkLarge),
    assetUrl: httpUrl(o.assetUrl),
    durationMs: isFinite(dur) && dur > 0 ? dur : 0
  }
}

function normalizeEpisode(item) {
  var a = (item && item.attributes) || {}
  return sanitizeEpisode({
    id: item && item.id,
    title: a.name || a.title,
    show: a.artistName || a.showName || a.collectionName,
    published: a.releaseDateTime || a.releaseDate || a.datePublished || "",
    url: a.url || a.websiteUrl,
    artwork: artworkUrl(a.artwork, 80),
    artworkLarge: artworkUrl(a.artwork, 300),
    // The publisher's own audio file. Absent for some subscriber-only shows.
    assetUrl: a.assetUrl,
    durationMs: a.durationInMilliseconds
  })
}

// Returns { ok, episodes, error }. Anything that is not the expected envelope
// is an error rather than an empty list, so a schema change is visible.
function parseEpisodes(body) {
  var json
  try { json = JSON.parse(text(body)) } catch (e) {
    return { ok: false, episodes: [], error: "Apple returned something that is not JSON." }
  }
  if (!json || !Array.isArray(json.data))
    return { ok: false, episodes: [], error: "Apple's answer had no episode list; the web API may have changed." }
  var out = []
  for (var i = 0; i < json.data.length && i < episodeLimitMax; i++) {
    var e = normalizeEpisode(json.data[i])
    if (e.title !== "" || e.id !== "") out.push(e)
  }
  return { ok: true, episodes: out, error: "" }
}

// bin/podcasts-api positions answers { data: [ { id, attributes: {
// positionInMilliseconds, completed, recordedAtTimestamp } } ] }: where each
// episode was left, on whichever device. Returns { id: { ms, completed } }; an
// episode Apple has no position for is simply absent.
function parsePositions(body) {
  var json
  try { json = JSON.parse(text(body)) } catch (e) { return null }
  if (!json || !Array.isArray(json.data)) return null
  var out = {}
  for (var i = 0; i < json.data.length && i < episodeLimitMax; i++) {
    var item = json.data[i], a = (item && item.attributes) || {}
    var id = episodeId(item && item.id)
    var ms = Number(a.positionInMilliseconds)
    var at = Date.parse(text(a.recordedAtTimestamp))
    if (id !== "") out[id] = { ms: isFinite(ms) && ms > 0 ? ms : 0, completed: a.completed === true, at: isFinite(at) ? at : 0 }
  }
  return out
}

// What `podcasts-api getpos` printed ("MS DONE EPOCH"), as a position.
function parseLocalPosition(out) {
  var m = /^\s*([0-9]+) (true|false) ([0-9]+)\s*$/.exec(text(out))
  return m ? { ms: Number(m[1]), completed: m[2] === "true", at: Number(m[3]) * 1000 } : null
}

// What `podcasts-api getposall` printed ("ID MS DONE EPOCH" per line), by id.
function parseLocalPositions(out) {
  var res = {}, lines = text(out).split("\n")
  for (var i = 0; i < lines.length && i < maxPositions; i++) {
    var m = /^([0-9]+) ([0-9]+) (true|false) ([0-9]+)\s*$/.exec(lines[i])
    if (m) res[m[1]] = { ms: Number(m[2]), completed: m[3] === "true", at: Number(m[4]) * 1000 }
  }
  return res
}

// Whichever of Apple's and this machine's record of an episode is newer. Apple
// wins when it gives no time, as it is the one that hears from other devices.
function newerPosition(apple, local) {
  if (!local) return apple || null
  if (!apple) return local
  return apple.at > 0 && local.at > apple.at ? local : apple
}

// A finished episode starts over, and so does one left within the last 10 s of
// a known duration (nothing worth resuming). Anything else resumes where it was
// left, however early: Apple's own clients ignore the first 15 s, but a pause
// after a few seconds is still a place worth coming back to.
var resumeTailSeconds = 10
function resumeSeconds(pos, durationMs) {
  if (!pos || pos.completed) return 0
  var s = Math.floor(Number(pos.ms) / 1000)
  if (!isFinite(s) || s <= 0) return 0
  var dur = Number(durationMs) / 1000
  if (dur > 0 && s >= dur - resumeTailSeconds) return 0
  return s
}

// Whether playback that reached `seconds` of `duration` counts as finished.
function isFinished(seconds, duration) {
  return Number(duration) > 0 && Number(seconds) >= Number(duration) - resumeTailSeconds
}

// "Played", for an episode row; "" otherwise. The resume position is tracked
// (see resumeSeconds) but deliberately not shown; the progress bar covers it.
function resumeLabel(pos, durationMs) {
  return pos && pos.completed ? "Played" : ""
}

// Whether an episode has been started and not finished: the same test that
// decides whether it resumes somewhere rather than from the top.
function inProgress(pos, durationMs) {
  return resumeSeconds(pos, durationMs) > 0
}

// Whether an episode was finished within the last `days` days (`now` in ms):
// those stay listed with a check mark, older ones leave the list.
function recentlyFinished(pos, now, days) {
  if (!pos || pos.completed !== true || !(pos.at > 0)) return false
  var age = Number(now) - pos.at
  return age < knownKeepDays(days) * 86400000
}

// How far into an episode you are, 0..1, for the bar under its row. 0 when
// there is nothing started to show (never played, finished, or duration unknown).
function progressFraction(pos, durationMs) {
  var dur = Number(durationMs) / 1000
  if (!(dur > 0)) return 0
  var s = resumeSeconds(pos, durationMs)
  return s > 0 ? Math.min(1, s / dur) : 0
}

// The order the list is shown in. With `inProgressFirst`, every episode that
// has been started (and the one playing now, `currentId`, from its first
// second) sits on top, the most recently listened to first, so what you are in
// the middle of is never buried under new arrivals. The rest follows `order`:
// `groupByFeed` (or, when unset, order "feed") groups episodes by show (A to Z, newest first within a show), "date"
// is newest first across shows, the order Apple sends. Sorting is stable, so
// ties keep the feed's order. The input is not changed.
function sortEpisodes(episodes, positions, options) {
  var list = Array.isArray(episodes) ? episodes : []
  var pos = positions && typeof positions === "object" ? positions : {}
  var opts = options || {}
  var pinFirst = opts.inProgressFirst !== false
  var order = knownSortOrder(opts.order)
  var group = typeof opts.groupByFeed === "boolean" ? opts.groupByFeed : order === "feed"
  var current = episodeId(opts.currentId)
  var keyed = list.map(function(e, i) {
    var p = e && e.id !== "" ? pos[e.id] : undefined
    var started = pinFirst && e && ((current !== "" && e.id === current) || inProgress(p, e.durationMs))
    var at = started && p && isFinite(Number(p.at)) ? Number(p.at) : 0
    if (started && current !== "" && e.id === current) at = Infinity
    var date = Date.parse(text(e && e.published))
    return { e: e, i: i, started: started, at: at, date: isFinite(date) ? date : -Infinity,
      show: text(e && e.show).toLowerCase() }
  })
  keyed.sort(function(a, b) {
    if (a.started !== b.started) return a.started ? -1 : 1
    if (a.started && a.at !== b.at) return a.at > b.at ? -1 : 1
    if (group && a.show !== b.show) return a.show < b.show ? -1 : 1
    if (a.date !== b.date) return a.date > b.date ? -1 : 1
    return a.i - b.i
  })
  return keyed.map(function(k) { return k.e })
}

function relativeAge(iso, now) {
  var t = Date.parse(text(iso))
  if (!isFinite(t)) return ""
  var secs = Math.max(0, Math.round(((now === undefined ? Date.now() : now) - t) / 1000))
  if (secs < 3600) return Math.max(1, Math.round(secs / 60)) + "m ago"
  if (secs < 86400) return Math.round(secs / 3600) + "h ago"
  if (secs < 86400 * 30) return Math.round(secs / 86400) + "d ago"
  return Math.round(secs / 86400 / 30) + "mo ago"
}

function formatDuration(ms) {
  var mins = Math.round(Number(ms) / 60000)
  if (!isFinite(mins) || mins <= 0) return ""
  return mins >= 60 ? Math.floor(mins / 60) + "h " + (mins % 60) + "m" : mins + "m"
}

// A message for a failed request, from the script's exit code and the HTTP
// status (see the exit codes at the top of bin/podcasts-api).
function isAuthFailure(exitCode, status) {
  return exitCode === 12 || exitCode === 21 || status === 401 || status === 403
}

function isTransient(exitCode, status) {
  return exitCode === 20 || status === 0 || status >= 500 || status === 429
}

function errorMessage(stderr, exitCode, status) {
  var s = text(stderr).trim().slice(0, 200)
  if (isAuthFailure(exitCode, status))
    return "Apple rejected the stored session. Sign in again."
  if (exitCode === 25) return s || "Could not read Apple's web player to get its access token."
  if (isTransient(exitCode, status)) return s || "Could not reach Apple Podcasts."
  return s || "Apple Podcasts answered with HTTP " + status + "."
}

// 3725 -> "1:02:05", 65 -> "1:05", for the player's clock.
function formatClock(seconds) {
  var n = Math.max(0, Math.floor(Number(seconds)))
  if (!isFinite(n)) return "0:00"
  var h = Math.floor(n / 3600)
  var m = Math.floor((n % 3600) / 60)
  var s = n % 60
  var ss = (s < 10 ? "0" : "") + s
  return h > 0 ? h + ":" + (m < 10 ? "0" : "") + m + ":" + ss : m + ":" + ss
}

// bin/podcasts-player status prints one JSON object; anything else is no
// player. Numbers are clamped so a half-loaded stream cannot show NaN.
function parseStatus(out) {
  var j
  try { j = JSON.parse(text(out)) } catch (e) { return null }
  if (!j || typeof j !== "object") return null
  var pos = Number(j.position), dur = Number(j.duration)
  return {
    position: isFinite(pos) && pos > 0 ? pos : 0,
    duration: isFinite(dur) && dur > 0 ? dur : 0,
    paused: j.paused === true,
    buffering: j.buffering === true,
    speed: knownSpeed(j.speed),
    title: text(j.title)
  }
}

function playMessage(stderr, exitCode) {
  var s = text(stderr).trim().slice(0, 200)
  if (exitCode === 31) return "mpv could not start playing that episode."
  if (exitCode === 24) return s || "No safe place for the player's socket."
  return s || "Playback failed (exit " + exitCode + ")."
}
