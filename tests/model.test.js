const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const vm = require("node:vm");

// Model.js is a QML .pragma library; evaluate it as a plain script.
const ctx = {};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(__dirname + "/../Model.js", "utf8").replace(/^\.pragma.*$/m, ""), ctx);
const M = ctx;

test("clampEpisodeLimit", () => {
  assert.strictEqual(M.clampEpisodeLimit(0), 1);
  assert.strictEqual(M.clampEpisodeLimit(999), 30);
  assert.strictEqual(M.clampEpisodeLimit("x"), 10);
  assert.strictEqual(M.clampEpisodeLimit(7.4), 7);
});

test("snapRefreshMinutes", () => {
  assert.strictEqual(M.snapRefreshMinutes(1), 30);
  assert.strictEqual(M.snapRefreshMinutes(45), 60);
  assert.strictEqual(M.snapRefreshMinutes(99999), 1440);
});

test("splitResponse", () => {
  assert.deepStrictEqual({ ...M.splitResponse('{"a":1}\nHTTP 200\n') }, { status: 200, body: '{"a":1}' });
  assert.strictEqual(M.splitResponse("garbage").status, 0);
});

test("parseEpisodes", () => {
  const body = JSON.stringify({ data: [{ id: "1", attributes: { name: "T", artistName: "S",
    releaseDateTime: "2026-10-27T08:00:00Z", url: "https://podcasts.apple.com/u", durationInMilliseconds: 1800000,
    artwork: { url: "https://a/{w}x{h}.{f}" } } }] });
  const r = M.parseEpisodes(body);
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.episodes[0].title, "T");
  assert.strictEqual(r.episodes[0].show, "S");
  assert.strictEqual(r.episodes[0].url, "https://podcasts.apple.com/u");
  assert.strictEqual(r.episodes[0].artwork, "https://a/80x80.jpg");
  assert.strictEqual(M.parseEpisodes("nope").ok, false);
  assert.strictEqual(M.parseEpisodes('{"x":1}').ok, false);
  assert.strictEqual(M.parseEpisodes('{"data":[]}').episodes.length, 0);
});

test("relativeAge and formatDuration", () => {
  const now = Date.parse("2026-10-28T12:00:00Z");
  assert.strictEqual(M.relativeAge("2026-10-28T11:30:00Z", now), "30m ago");
  assert.strictEqual(M.relativeAge("2026-10-27T12:00:00Z", now), "1d ago");
  assert.strictEqual(M.relativeAge("nope", now), "");
  assert.strictEqual(M.formatDuration(5400000), "1h 30m");
  assert.strictEqual(M.formatDuration(0), "");
});

test("errorMessage", () => {
  assert.match(M.errorMessage("", 21, 403), /Sign in again/);
  assert.match(M.errorMessage("", 20, 0), /reach Apple/);
});

test("player helpers", () => {
  assert.strictEqual(M.formatClock(65), "1:05");
  assert.strictEqual(M.formatClock(3725), "1:02:05");
  assert.strictEqual(M.formatClock(-4), "0:00");
  assert.strictEqual(M.knownSkip(15, 30), 15);
  assert.strictEqual(M.knownSkip(7, 30), 30);
  const st = M.parseStatus('{"position":12.5,"duration":60,"paused":true,"buffering":false,"title":"T"}');
  assert.strictEqual(st.position, 12.5);
  assert.strictEqual(st.paused, true);
  assert.strictEqual(st.title, "T");
  assert.strictEqual(M.parseStatus("nope"), null);
  assert.strictEqual(M.parseStatus('{"position":null,"duration":-1}').position, 0);
  const ep = M.parseEpisodes(JSON.stringify({ data: [{ id: "1", attributes: { name: "T", assetUrl: "https://a/b.mp3",
    artwork: { url: "https://x/{w}x{h}.{f}" } } }] })).episodes[0];
  assert.strictEqual(ep.assetUrl, "https://a/b.mp3");
  assert.strictEqual(ep.artworkLarge, "https://x/300x300.jpg");
});

// Nothing from the feed may name a non-web URL or a non-numeric id: those
// values reach xdg-open, Image.source, mpv and the scripts' argv.
test("untrusted URLs and ids are dropped", () => {
  assert.strictEqual(M.httpUrl("https://a.example/x.mp3"), "https://a.example/x.mp3");
  assert.strictEqual(M.httpUrl("HTTP://a.example/x"), "HTTP://a.example/x");
  assert.strictEqual(M.httpUrl(" https://a.example/x \n"), "https://a.example/x");
  for (const bad of ["file:///etc/passwd", "javascript:alert(1)", "ssh://h", "vnc://h", "//a.example/x",
    "https://a.example/x y", "https://a.example/x\"", "https://a.example/<", "https://a.example/\u0007", "", null, undefined, 42])
    assert.strictEqual(M.httpUrl(bad), "", String(bad));
  const r = M.parseEpisodes(JSON.stringify({ data: [{ id: "__proto__", attributes: { name: "T",
    url: "file:///etc/passwd", assetUrl: "javascript:alert(1)", artwork: { url: "file:///x/{w}x{h}.{f}" } } }] }));
  assert.deepStrictEqual({ ...r.episodes[0] }, { id: "", title: "T", show: "", published: "", url: "",
    artwork: "", artworkLarge: "", assetUrl: "", durationMs: 0 });
  assert.strictEqual(M.episodeId("1001"), "1001");
  assert.strictEqual(M.episodeId("1001;rm"), "");
  assert.strictEqual(M.episodeId("__proto__"), "");
  // A played.json written by an older version, or by hand, gets the same treatment.
  const s = M.sanitizeEpisode({ id: 7, title: "T", url: "file:///x", assetUrl: "https://a/b.mp3", durationMs: "-5", junk: 1 });
  assert.deepStrictEqual({ ...s }, { id: "7", title: "T", show: "", published: "", url: "",
    artwork: "", artworkLarge: "", assetUrl: "https://a/b.mp3", durationMs: 0 });
  assert.strictEqual(M.sanitizeEpisode(null).id, "");
  assert.strictEqual(M.sanitizeEpisode("x").id, "");
  const p = M.parsePositions(JSON.stringify({ data: [
    { id: "__proto__", attributes: { positionInMilliseconds: 5, completed: true } },
    { id: "1", attributes: { positionInMilliseconds: 5, completed: true } }] }));
  assert.deepStrictEqual(Object.keys(p), ["1"]);
  assert.strictEqual(Object.getPrototypeOf(p), vm.runInContext("Object.prototype", ctx));
  assert.strictEqual(p.ms, undefined);
  assert.strictEqual(p["nope"], undefined);
});

test("speed helpers", () => {
  assert.strictEqual(M.formatSpeed(1), "x1");
  assert.strictEqual(M.formatSpeed(1.3), "x1,3");
  assert.strictEqual(M.formatSpeed(0.8), "x0,8");
  assert.strictEqual(M.formatSpeed(7), "x1");
  assert.strictEqual(M.parseStatus('{"speed":1.5}').speed, 1.5);
  assert.strictEqual(M.parseStatus('{}').speed, 1);
});

test("positions and resuming", () => {
  const body = JSON.stringify({ data: [
    { id: "1", attributes: { positionInMilliseconds: 754000, completed: false } },
    { id: "2", attributes: { positionInMilliseconds: 1800000, completed: true } },
    { id: "3", attributes: { completed: false } }] });
  const p = M.parsePositions(body);
  assert.strictEqual(p["1"].ms, 754000);
  assert.strictEqual(p["2"].completed, true);
  assert.strictEqual(p["3"].ms, 0);
  assert.strictEqual(M.parsePositions("nope"), null);
  assert.strictEqual(M.parsePositions('{"x":1}'), null);
  assert.strictEqual(Object.keys(M.parsePositions('{"data":[]}')).length, 0);
  assert.strictEqual(M.resumeSeconds(p["1"], 1800000), 754);
  assert.strictEqual(M.resumeSeconds(p["2"], 1800000), 0);    // finished: from the top
  assert.strictEqual(M.resumeSeconds({ ms: 9000, completed: false }, 1800000), 9);  // early positions count
  assert.strictEqual(M.resumeSeconds({ ms: 400, completed: false }, 1800000), 0);  // under a second
  assert.strictEqual(M.resumeSeconds({ ms: 1795000, completed: false }, 1800000), 0);  // in the tail
  assert.strictEqual(M.resumeSeconds({ ms: 1795000, completed: false }, 0), 1795);  // unknown length
  assert.strictEqual(M.resumeSeconds(undefined, 1800000), 0);
  assert.strictEqual(M.isFinished(1795, 1800), true);
  assert.strictEqual(M.isFinished(1700, 1800), false);
  assert.strictEqual(M.isFinished(100, 0), false);
  assert.strictEqual(M.resumeLabel(p["1"], 1800000), "");
  assert.strictEqual(M.resumeLabel(p["2"], 1800000), "Played");
  assert.strictEqual(M.resumeLabel(undefined, 1800000), "");
  assert.strictEqual(M.progressFraction({ ms: 900000, completed: false }, 1800000), 0.5);
  assert.strictEqual(M.progressFraction({ ms: 900000, completed: true }, 1800000), 0);
  assert.strictEqual(M.progressFraction({ ms: 900000, completed: false }, 0), 0);
  assert.strictEqual(M.progressFraction({ ms: 1795000, completed: false }, 1800000), 0);
  assert.strictEqual(M.progressFraction(undefined, 1800000), 0);
});

test("local positions", () => {
  assert.strictEqual(M.parseLocalPosition("754000 false 1790000000\n").ms, 754000);
  assert.strictEqual(M.parseLocalPosition("754000 false 1790000000").at, 1790000000000);
  assert.strictEqual(M.parseLocalPosition("junk"), null);
  assert.strictEqual(M.parseLocalPositions("7 5000 false 1790000000\njunk\n9 1 true 1790000001\n")["9"].completed, true);
  assert.strictEqual(M.parseLocalPositions("7 5000 false 1790000000\n")["7"].ms, 5000);
  const apple = { ms: 600000, completed: false, at: 1000 }, local = { ms: 900000, completed: false, at: 2000 };
  assert.strictEqual(M.newerPosition(apple, local), local);
  assert.strictEqual(M.newerPosition({ ...apple, at: 3000 }, local).ms, 600000);
  assert.strictEqual(M.newerPosition({ ...apple, at: 0 }, local).ms, 600000);
  assert.strictEqual(M.newerPosition(null, local), local);
  assert.strictEqual(M.newerPosition(apple, null), apple);
  assert.strictEqual(M.newerPosition(null, null), null);
});

test("sortEpisodes", () => {
  const ep = (id, show, published, durationMs = 1800000) => ({ id, title: "T" + id, show, published, durationMs });
  // Apple's order: newest first across shows.
  const feed = [ep("1", "Beta", "2026-10-28T08:00:00Z"), ep("2", "Alpha", "2026-10-27T08:00:00Z"),
    ep("3", "Beta", "2026-10-26T08:00:00Z"), ep("4", "Alpha", "2026-10-25T08:00:00Z"), ep("5", "Gamma", "2026-10-24T08:00:00Z")];
  const ids = (list) => list.map((e) => e.id);
  const positions = {
    "3": { ms: 600000, completed: false, at: 1000 },   // started a while ago
    "4": { ms: 300000, completed: false, at: 2000 },   // started more recently
    "5": { ms: 1800000, completed: true, at: 3000 },   // finished: not in progress
    "1": { ms: 1795000, completed: false, at: 4000 }   // in the tail: starts over, not in progress
  };
  assert.strictEqual(M.knownSortOrder("date"), "date");
  assert.strictEqual(M.knownSortOrder("nope"), "feed");
  for (const size of ["small", "medium", "large", "xlarge"]) assert.strictEqual(M.knownTextSize(size), size);
  for (const size of ["huge", "", null, 3, "Medium"]) assert.strictEqual(M.knownTextSize(size), "medium");
  // In progress first, most recently listened to on top, then by show and date.
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, positions, { inProgressFirst: true, order: "feed" })), ["4", "3", "2", "1", "5"]);
  // Then by date instead: Apple's order for the rest.
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, positions, { inProgressFirst: true, order: "date" })), ["4", "3", "1", "2", "5"]);
  // Nothing pinned: plain feed / date orders.
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, positions, { inProgressFirst: false, order: "feed" })), ["2", "4", "1", "3", "5"]);
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, positions, { inProgressFirst: false, order: "date" })), ["1", "2", "3", "4", "5"]);
  // groupByFeed overrides order.
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, positions, { inProgressFirst: false, groupByFeed: false })), ["1", "2", "3", "4", "5"]);
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, positions, { inProgressFirst: false, groupByFeed: true, order: "date" })), ["2", "4", "1", "3", "5"]);
  // The episode playing now leads from its first second, before any saved position.
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, positions, { order: "feed", currentId: "5" })), ["5", "4", "3", "2", "1"]);
  // Defaults: in progress first, by feed; odd input is harmless and the list is not changed.
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, {}, {})), ["2", "4", "1", "3", "5"]);
  assert.deepStrictEqual(ids(M.sortEpisodes(feed, null, { currentId: "__proto__" })), ["2", "4", "1", "3", "5"]);
  assert.strictEqual(M.sortEpisodes(null, null, null).length, 0);
  assert.deepStrictEqual(ids(feed), ["1", "2", "3", "4", "5"]);
  // Same show, unknown date: feed order is kept.
  assert.deepStrictEqual(ids(M.sortEpisodes([ep("7", "A", ""), ep("8", "A", "")], {}, { inProgressFirst: false })), ["7", "8"]);
  assert.strictEqual(M.inProgress({ ms: 600000, completed: false }, 1800000), true);
  assert.strictEqual(M.inProgress({ ms: 600000, completed: true }, 1800000), false);
  assert.strictEqual(M.inProgress(undefined, 1800000), false);
});

test("knownKeepDays only accepts 1, 3 or 7", () => {
  assert.strictEqual(M.knownKeepDays(7), 7);
  assert.strictEqual(M.knownKeepDays("3"), 3);
  assert.strictEqual(M.knownKeepDays(5), 1);
});

test("recentlyFinished keeps a finished episode for the chosen days", () => {
  const now = 10 * 86400000;
  const done = (daysAgo) => ({ completed: true, at: now - daysAgo * 86400000 });
  assert.strictEqual(M.recentlyFinished(done(0.5), now, 1), true);
  assert.strictEqual(M.recentlyFinished(done(1.5), now, 1), false);
  assert.strictEqual(M.recentlyFinished(done(1.5), now, 3), true);
  assert.strictEqual(M.recentlyFinished(done(6), now, 7), true);
  assert.strictEqual(M.recentlyFinished(done(8), now, 7), false);
  assert.strictEqual(M.recentlyFinished({ completed: false, at: now }, now, 7), false);
  assert.strictEqual(M.recentlyFinished({ completed: true, at: 0 }, now, 7), false);
  assert.strictEqual(M.recentlyFinished(undefined, now, 7), false);
});

test("retained data is bounded", () => {
  const many = { data: Array.from({ length: 100 }, (_, i) => ({ id: String(i + 1), attributes: { name: "t".repeat(5000) } })) };
  const r = M.parseEpisodes(JSON.stringify(many));
  assert.strictEqual(r.episodes.length, M.episodeLimitMax);
  assert.strictEqual(r.episodes[0].title.length, M.maxTextLength);
  const pos = { data: Array.from({ length: 100 }, (_, i) => ({ id: String(i + 1), attributes: { positionInMilliseconds: 5 } })) };
  assert.strictEqual(Object.keys(M.parsePositions(JSON.stringify(pos))).length, M.episodeLimitMax);
  assert.strictEqual(M.httpUrl("https://a/" + "x".repeat(3000)), "");
  const big = {};
  for (let i = 1; i <= 700; i++) big[String(i)] = { ms: 1, completed: false, at: i };
  const kept = M.capPositions(big);
  assert.strictEqual(Object.keys(kept).length, M.maxPositions);
  assert.ok(kept["700"] && !kept["1"]);
});

test('pasteEnvironment keeps the Wayland display selection and nothing else extra', () => {
  assert.strictEqual(M.pasteEnvironment.WAYLAND_DISPLAY, null)
  assert.ok(!('WAYLAND_SOCKET' in M.pasteEnvironment))
  assert.ok(!('WAYLAND_DISPLAY' in M.environment))
  for (const k in M.environment) assert.strictEqual(M.pasteEnvironment[k], M.environment[k])
})
