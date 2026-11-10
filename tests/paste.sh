#!/usr/bin/env bash
# bin/podcasts-paste must cap bytes and time no matter what the clipboard owner does.
set -u
S="$(dirname "$0")/../bin/podcasts-paste"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cat > "$d/wl-paste" <<'X'
#!/bin/bash
case "$FAKE" in
  big) head -c 100000000 /dev/zero | tr '\0' a;;
  slow) printf abc; sleep 30;;
  ok) printf tokenvalue;;
esac
X
chmod +x "$d/wl-paste"
fail=0
run() { FAKE=$1 PATH="$d:$PATH" bash "$S"; }
[ "$(run ok)" = tokenvalue ] || { echo "FAIL ok"; fail=1; }
run big >/dev/null; [ $? -eq 2 ] || { echo "FAIL oversized not rejected"; fail=1; }
start=$SECONDS; run slow >/dev/null; rc=$?
{ [ $rc -eq 1 ] && [ $((SECONDS - start)) -le 4 ]; } || { echo "FAIL deadline"; fail=1; }
[ $fail -eq 0 ] && echo ok
exit $fail
