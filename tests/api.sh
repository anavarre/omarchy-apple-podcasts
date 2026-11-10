#!/usr/bin/env bash
# Runs bin/podcasts-api against tests/fixture_server.py; no network, no Apple.
set -u
cd "$(dirname "$0")/.." || exit 1
here=$PWD
tmp=$(mktemp -d); trap 'kill $srv 2>/dev/null; rm -rf "$tmp"' EXIT
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
good=$(printf 'A%.0s' {1..60})
python3 tests/fixture_server.py "$port" "$good" & srv=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/us/new" > /dev/null && break; sleep 0.1; done

export HOME=$tmp PODCASTS_PLUGIN_DIR=$tmp/store
export PODCASTS_API_BASE=http://127.0.0.1:$port PODCASTS_WEB_BASE=http://127.0.0.1:$port
run() { bash "$here/bin/podcasts-api" "$@"; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fails=$((fails + 1)); fi; }

check "config without token" "$(run config | grep -c '"hasToken":false')" 1
odd="$tmp/odd \"dir\\"; mkdir -p "$odd"
export EXPECT=$odd
check "config is JSON whatever the store path" "$(PODCASTS_PLUGIN_DIR=$odd run config | python3 -c 'import json,os,sys; print(json.load(sys.stdin)["store"] == os.environ["EXPECT"].replace(os.environ["HOME"], "~", 1))')" True
run episodes 5 latest > /dev/null 2>&1; check "episodes without token exits 12" $? 12
echo 'short' | run save > /dev/null 2>&1; check "short token refused (26)" $? 26
echo 'bad token!!' | run save > /dev/null 2>&1; check "junk token refused (26)" $? 26
echo "media-user-token=$good; Path=/" | run save; check "cookie pair accepted" $? 0
check "token file mode 600" "$(stat -c %a "$tmp/store/media-user-token")" 600
check "store dir mode 700" "$(stat -c %a "$tmp/store")" 700
check "config with token" "$(run config | grep -c '"hasToken":true')" 1

out=$(run episodes 5 latest); rc=$?
check "episodes exit 0" "$rc" 0
check "episodes status line" "$(printf '%s\n' "$out" | tail -n1)" "HTTP 200"
check "episodes body has title" "$(printf '%s' "$out" | grep -c 'Episode One')" 1
check "dev token cached" "$([ -s "$tmp/store/dev-token" ] && echo yes)" yes
check "up-next works" "$(run episodes 5 up-next | tail -n1)" "HTTP 200"

# Positions: what another device left, and what this one writes back.
pos=$(run positions 1001,1002); check "positions exit 0" $? 0
check "positions status line" "$(printf '%s\n' "$pos" | tail -n1)" "HTTP 200"
check "positions has the saved one" "$(printf '%s' "$pos" | grep -c '"positionInMilliseconds":600000')" 1
check "positions omits unknown episode" "$(printf '%s' "$pos" | grep -c '"id":"1002"')" 0
sp=$(run setposition 1002 754000 false); check "setposition exit 0" $? 0
check "setposition is a 204" "$(printf '%s\n' "$sp" | tail -n1)" "HTTP 204"
check "written position reads back" "$(run positions 1002 | grep -c '"positionInMilliseconds":754000')" 1
run setposition 1002 1800000 true > /dev/null
check "completed reads back" "$(run positions 1002 | grep -c '"completed":true')" 1
run positions '' > /dev/null 2>&1; check "empty ids refused (64)" $? 64
run positions '1001;rm' > /dev/null 2>&1; check "junk ids refused (64)" $? 64
run positions "$(seq -s, 1 31)" > /dev/null 2>&1; check "31 ids refused (64)" $? 64
run setposition abc 5 false > /dev/null 2>&1; check "bad id refused (64)" $? 64
run setposition 1002 -5 false > /dev/null 2>&1; check "bad ms refused (64)" $? 64
run setposition 1002 5 maybe > /dev/null 2>&1; check "bad flag refused (64)" $? 64

printf 'B%.0s' {1..60} | run save
run episodes 5 latest > /dev/null 2>&1; check "wrong token exits 21" $? 21
run positions 1001 > /dev/null 2>&1; check "positions wrong token exits 21" $? 21
run setposition 1001 5 false > /dev/null 2>&1; check "setposition wrong token exits 21" $? 21

run episodes 0 latest > /dev/null 2>&1; check "limit 0 refused (64)" $? 64
run episodes 5 bogus > /dev/null 2>&1; check "bad source refused (64)" $? 64
PODCASTS_API_BASE=http://evil.example run config > /dev/null 2>&1; check "plain http off-box refused" $? 64
# A quote or newline in a base would end the header line in curl's config and
# start a new directive (url =, output =); refuse the base before that.
PODCASTS_WEB_BASE='https://x"' run config > /dev/null 2>&1; check "quote in web base refused (64)" $? 64
PODCASTS_API_BASE=$'https://x\nurl = "http://127.0.0.1:1/"' run config > /dev/null 2>&1; check "newline in api base refused (64)" $? 64
PODCASTS_WEB_BASE='https://x y' run config > /dev/null 2>&1; check "space in web base refused (64)" $? 64
PODCASTS_WEB_BASE='https://' run config > /dev/null 2>&1; check "empty host refused (64)" $? 64
# A token from the environment is held to the same format as a pasted one.
check "junk env token counts as none" "$(PODCASTS_MEDIA_USER_TOKEN=$'a"\noutput = /tmp/x\n' run config | grep -c '"hasToken":false')" 1
PODCASTS_MEDIA_USER_TOKEN='short' run episodes 5 latest > /dev/null 2>&1; check "short env token exits 12" $? 12
check "good env token is used" "$(PODCASTS_MEDIA_USER_TOKEN=$good run episodes 5 latest | tail -n1)" "HTTP 200"
# A cached developer token that is not JWT-shaped is ignored and re-fetched,
# never written into curl's config.
echo "$good" | run save
payload=$(cut -d. -f2 "$tmp/store/dev-token")
printf 'eyJ"\nurl = "http://127.0.0.1:1/"\n.%s.c2ln\n' "$payload" > "$tmp/store/dev-token"
check "poisoned dev-token cache is not used" "$(run episodes 5 latest | tail -n1)" "HTTP 200"
check "poisoned dev-token cache is replaced" "$(grep -c 'url =' "$tmp/store/dev-token")" 0
ln -sf /dev/null "$tmp/store/dev-token.link"; mv -f "$tmp/store/dev-token.link" "$tmp/store/dev-token"
check "symlinked dev-token is not read" "$(run episodes 5 latest | tail -n1)" "HTTP 200"
check "symlinked dev-token is replaced by a file" "$([ -L "$tmp/store/dev-token" ] && echo link || echo file)" file

run savepos 1002 321000 false; check "savepos exit 0" $? 0
check "getpos reads it back" "$(run getpos 1002 | cut -d' ' -f1,2)" "321000 false"
check "getpos unknown is empty" "$(run getpos 9999)" ""
run savepos 1002 5 maybe > /dev/null 2>&1; check "savepos bad flag refused (64)" $? 64

run savepos 1003 7000 true
check "getposall lists saved positions" "$(run getposall 1002,1003,9999 | cut -d' ' -f1-3 | paste -sd'|')" "1002 321000 false|1003 7000 true"
run getposall 'x;y' > /dev/null 2>&1; check "getposall junk ids refused (64)" $? 64
check "getplayed empty before save" "$(run getplayed)" ""
printf '[{"id":"1001"}]' | run saveplayed; check "saveplayed exit 0" $? 0
check "getplayed reads it back" "$(run getplayed)" '[{"id":"1001"}]'
check "played file mode 600" "$(stat -c %a "$tmp/store/played.json")" 600

# Artwork: a small image only, fetched without following redirects.
art=$(run art "http://127.0.0.1:$port/art/ok.png"); check "art exit 0" $? 0
check "art prints a cached file" "$([ -f "$art" ] && echo yes)" yes
check "art file mode 600" "$(stat -c %a "$art")" 600
run art "http://127.0.0.1:$port/art/text.png" > /dev/null 2>&1; check "art non-image refused (20)" $? 20
run art "http://127.0.0.1:$port/art/big.png" > /dev/null 2>&1; check "art oversized refused (20)" $? 20
run art "http://127.0.0.1:$port/art/redir.png" > /dev/null 2>&1; check "art redirect not followed (20)" $? 20
run art "file:///etc/passwd" > /dev/null 2>&1; check "art non-http refused (64)" $? 64
check "art leaves no temp files" "$(ls -A "$tmp/store/art" | grep -c '^\.tmp')" 0

run forget; check "forget empties store" "$(ls -A "$tmp/store" | wc -l)" 0
mkdir "$tmp/real"; ln -s "$tmp/real" "$tmp/link"
echo "$good" | PODCASTS_PLUGIN_DIR=$tmp/link run save > /dev/null 2>&1; check "symlinked store refused (24)" $? 24

# The token must never be visible in argv while a request is in flight.
check "no token in script source" "$(grep -c "$good" bin/podcasts-api)" 0
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
