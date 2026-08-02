#!/usr/bin/env bash
# Run: bash test/e2e_all.sh
# Tests: GET, /metrics, /admin, POST, 5 sequential, 3 parallel, SIGTERM.

set +e
UP="${1:-9000}"
PP="${2:-8080}"
B="http://127.0.0.1:${PP}"

cleanup() { kill %1 %2 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

echo "=== Zigora E2E ==="
zig build 2>/dev/null || { echo "BUILD FAILED"; exit 1; }

python3 -m http.server "$UP" --bind 127.0.0.1 >/dev/null 2>&1 &
./zig-out/bin/zigora --backend "127.0.0.1:${UP}" >/dev/null 2>&1 &
sleep 2

echo -n "1. GET ............ "; curl -s -o /dev/null -w "%{http_code}" "$B/" | grep -q 200 && echo "PASS" || echo "FAIL"
echo -n "2. streaming ...... "; SIZE=$(curl -s -o /dev/null -w "%{size_download}" "$B/"); [ "$SIZE" -gt 100 ] && echo "PASS ($SIZE bytes)" || echo "FAIL ($SIZE bytes)"
echo -n "3. /metrics ..... "; curl -s "$B/metrics" | grep -q zigora && echo "PASS" || echo "FAIL"
echo -n "4. /admin .......... "; curl -s "$B/admin" | grep -qi admin && echo "PASS" || echo "FAIL"
echo -n "5. 5x sequential.. "; ok=true; for i in 1 2 3 4 5; do [ "$(curl -s -o /dev/null -w "%{http_code}" "$B/")" = "200" ] || ok=false; done; $ok && echo "PASS" || echo "FAIL"
echo -n "6. POST (nocrace) .. "; echo -n "" | curl -s -m 2 -X POST -o /dev/null "$B/" 2>/dev/null; sleep 0.3; pgrep -x zigora >/dev/null && echo "PASS" || echo "FAIL"
echo -n "7. 3 parallel ....... "; curl -s -o /dev/null "$B/" & P1=$!; curl -s -o /dev/null "$B/" & P2=$!; curl -s -o /dev/null "$B/" & P3=$!; wait $P1 $P2 $P3; echo "PASS"
echo -n "8. SIGTERM ........ "; kill -TERM $(pidof zigora) 2>/dev/null; sleep 2; pgrep -x zigora >/dev/null && echo "FAIL (still alive)" || echo "PASS"

echo "=== Done ==="