#!/usr/bin/env python3
"""Stands in for podcasts.apple.com and amp-api.podcasts.apple.com.

Serves the web player page, a bundle holding a developer JWT, and the library
endpoints, which demand the Bearer and media-user-token headers. The shape of
the episode JSON is an ASSUMPTION modelled on Apple's amp-api envelope; replace
it with a captured real response once the spike has one.

Usage: fixture_server.py PORT GOOD_USER_TOKEN
"""
import base64, json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

def b64(d):
    return base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")

DEV = ".".join([b64({"alg": "ES256"}), b64({"exp": int(time.time()) + 86400 * 30}), "c2lnbmF0dXJlLXNpZ25hdHVyZQ"])
GOOD = sys.argv[2]
EPISODES = {"data": [
    {"id": "1001", "type": "podcast-episodes", "attributes": {
        "name": "Episode One", "artistName": "Show A",
        "releaseDateTime": "2026-10-27T08:00:00Z", "url": "https://podcasts.apple.com/us/podcast/x/id1?i=1001",
        "durationInMilliseconds": 1800000, "artwork": {"url": "https://example.test/{w}x{h}.{f}"}}},
    {"id": "1002", "type": "podcast-episodes", "attributes": {
        "name": "Episode Two", "artistName": "Show B",
        "releaseDateTime": "2026-10-26T08:00:00Z", "url": "https://podcasts.apple.com/us/podcast/y/id2?i=1002"}},
]}

# Playback positions as Apple keeps them: shared by every device, last write wins.
POSITIONS = {"1001": {"completed": False, "positionInMilliseconds": 600000, "recordedAtTimestamp": "2026-10-28T08:00:00.000Z"}}
POS_PATH = "/v1/me/playback/positions/podcast-episodes"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass  # the client hung up on an oversized body
    def authed(self):
        if self.headers.get("Authorization") != "Bearer " + DEV:
            self.send(401, '{"errors":[{"status":"401"}]}'); return False
        if self.headers.get("media-user-token") != GOOD:
            self.send(403, '{"errors":[{"status":"403"}]}'); return False
        return True
    def ids(self):
        q = parse_qs(urlparse(self.path).query)
        return [i for v in q.get("ids", []) for i in v.split(",") if i]
    def do_PUT(self):
        # Like Apple, a write names its one episode in the path; ?ids= is a 405.
        path = urlparse(self.path).path
        if path == POS_PATH: return self.send(405, '{"code":405,"message":"HTTP 405 Method Not Allowed"}')
        if not path.startswith(POS_PATH + "/"): return self.send(404, "{}")
        if not self.authed(): return
        id = path[len(POS_PATH) + 1:]
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if not id or body.get("type") != "playback-positions": return self.send(400, "{}")
        POSITIONS[id] = body["attributes"]
        self.send(204, "")
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/art/ok.png": return self.send(200, b"\x89PNG\r\n\x1a\n" + b"0" * 64, "image/png")
        if path == "/art/text.png": return self.send(200, "<html>not an image</html>", "image/png")
        if path == "/art/big.png": return self.send(200, b"\x89PNG\r\n\x1a\n" + b"0" * 2000000, "image/png")
        if path == "/art/redir.png":
            self.send_response(302); self.send_header("Location", "/art/ok.png"); self.send_header("Content-Length", "0"); self.end_headers(); return
        p = self.path.split("?")[0]
        if p == POS_PATH:
            if not self.authed(): return
            if not self.ids(): return self.send(400, '{"errors":[{"status":"400"}]}')
            return self.send(200, json.dumps({"data": [
                {"id": i, "type": "playback-positions", "attributes": POSITIONS[i]} for i in self.ids() if i in POSITIONS]}, separators=(",", ":")))
        if p == "/us/browse":
            self.send_response(301); self.send_header("Location", "/us/new")
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if p == "/us/new":
            return self.send(200, '<script src="/assets/index~abc123.js"></script>', "text/html")
        if p.startswith("/assets/index"):
            return self.send(200, 'const pc="%s";' % DEV, "application/javascript")
        if p in ("/v1/me/library/latest-episodes", "/v1/me/library/next-episodes"):
            if self.headers.get("Authorization") != "Bearer " + DEV:
                return self.send(401, '{"errors":[{"status":"401"}]}')
            if self.headers.get("media-user-token") != GOOD:
                return self.send(403, '{"errors":[{"status":"403"}]}')
            if p.endswith("next-episodes"):
                return self.send(200, '{"data":[]}')
            return self.send(200, json.dumps(EPISODES))
        self.send(404, "{}")

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
