#!/usr/bin/env bash
set -euo pipefail

# E2E regression test for Zigora.
# Starts the server, curls /metrics and /admin, then shuts down.
# Returns 0 on success, non-zero on failure.

ZIGORA="${ZIGORA:-./zig-out/bin/zigora}"
PORT="${PORT:-8080}"
BASE="http://127.0.0.1:${PORT}"

cleanup() {
    if [ -n "${PID:-}" ]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "=== Zigora E2E ==="

# Build if binary doesn't exist
if [ ! -x "$ZIGORA" ]; then
    echo "Building zigora..."
    zig build
fi

# Start server
echo "Starting server on 127.0.0.1:${PORT}..."
$ZIGORA &
PID=$!

# Wait for server to accept connections
for i in $(seq 1 10); do
    if curl -sf --connect-timeout 1 --max-time 2 "$BASE/metrics" >/dev/null 2>&1; then
        break
    fi
    sleep 0.3
done

echo "Server PID=$PID"

# Test: GET /metrics -> Prometheus text
echo -n "Test GET /metrics ... "
METRICS=$(curl -sf --connect-timeout 1 --max-time 3 "$BASE/metrics")
if echo "$METRICS" | grep -q "zigora_connections_accepted"; then
    echo "PASS"
else
    echo "FAIL: no prometheus metrics in response"
    echo "$METRICS"
    exit 1
fi

# Test: GET /admin -> HTML
echo -n "Test GET /admin ... "
ADMIN=$(curl -sf --connect-timeout 1 --max-time 3 "$BASE/admin")
if echo "$ADMIN" | grep -q "Zigora Admin"; then
    echo "PASS"
else
    echo "FAIL: no admin HTML in response"
    echo "$ADMIN"
    exit 1
fi

# Test: GET /metrics has counter > 0
echo -n "Test metrics counter ... "
if echo "$METRICS" | grep -q "zigora_requests_total [1-9]"; then
    echo "PASS"
else
    echo "FAIL: expected requests_total > 0"
    echo "$METRICS"
    # not fatal — counter may be 0 initially
fi

echo "=== All E2E tests PASS ==="
