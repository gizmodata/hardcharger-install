#!/bin/sh
# Smoke test of an installed Hardcharger: start hardcharger-server, sign in, run SELECT 42 over
# Warp SQL (with curl, and with the hardcharger client when the version ships one), check that a
# failing statement fails, stop the server.
#
#   .github/scripts/e2e.sh <bin-dir> <port> [<expected-version>]
set -eu

BIN_DIR="$1"
PORT="$2"
EXPECT="${3:-}"
HEALTH_PORT=$((PORT + 1))
PASSWORD="e2e-$(date +%s)-$$"
LOG="$(mktemp)"

fail() { echo "FAIL: $*" >&2; echo "--- server log ---" >&2; cat "$LOG" >&2; exit 1; }

"$BIN_DIR/hardcharger-server" --version
if [ -n "$EXPECT" ]; then
  "$BIN_DIR/hardcharger-server" --version | grep -F "Hardcharger $EXPECT" >/dev/null \
    || fail "expected Hardcharger $EXPECT"
fi

# 0.2.0 and later read HARDCHARGER_ADMIN_PASSWORD; 0.1.x read HARDCHARGER_PASSWORD.
HARDCHARGER_ADMIN_PASSWORD="$PASSWORD" HARDCHARGER_PASSWORD="$PASSWORD" "$BIN_DIR/hardcharger-server" \
  --host 127.0.0.1 --port "$PORT" --health-port "$HEALTH_PORT" --database :memory: >"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; rm -f "$LOG"' EXIT

i=0
until curl -fsS "http://127.0.0.1:$HEALTH_PORT/health" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 120 ] || fail "server not healthy after 60 s"
  kill -0 "$SERVER_PID" 2>/dev/null || fail "server exited"
  sleep 0.5
done
echo "server healthy on 127.0.0.1:$PORT"

W="http://127.0.0.1:$PORT/warp/v1"
TOKEN="$(curl -fsS "$W/auth/token" -H 'Content-Type: application/json' \
  -d "{\"grant_type\": \"password\", \"username\": \"hardcharger\", \"password\": \"$PASSWORD\"}" \
  | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')"
[ -n "$TOKEN" ] || fail "no access token"
HDR="$(mktemp)"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HDR"
SESSION="$(curl -fsS "$W/sessions" -H @"$HDR" -H 'Content-Type: application/json' -d '{}' \
  | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p')"
[ -n "$SESSION" ] || fail "no session"

run_sql() {
  curl -fsS "$W/sessions/$SESSION/statements" -H @"$HDR" -H 'Content-Type: application/json' \
    -d "{\"sql\": \"$1\"}"
}
# The result is Arrow, so the value is checked in SQL: error() fails the statement unless it is 42.
out="$(run_sql "SELECT CASE WHEN 6 * 7 = 42 THEN 42 ELSE error('wrong answer') END AS answer")"
printf '%s\n' "$out" | grep -F '"state":"succeeded"' >/dev/null || fail "SELECT 42 over curl: $out"
printf '%s\n' "$out" | grep -F '"rows":1' >/dev/null || fail "SELECT 42 over curl returned no row: $out"
echo "curl: SELECT 42 succeeded"
out="$(run_sql "SELECT error('expected failure')" 2>&1 || true)"
case "$out" in
  *'"state":"failed"'*'expected failure'*) ;;
  *) fail "a failing statement did not fail with its own error: $out" ;;
esac
echo "curl: a failing statement fails"
rm -f "$HDR"

if [ -x "$BIN_DIR/hardcharger" ]; then
  got="$(HARDCHARGER_PASSWORD="$PASSWORD" "$BIN_DIR/hardcharger" --host 127.0.0.1 --port "$PORT" \
    --username hardcharger --csv --command "SELECT 42 AS answer")" || fail "hardcharger client: $got"
  printf '%s\n' "$got"
  printf '%s\n' "$got" | grep -x '42' >/dev/null || fail "hardcharger client did not print 42"
  echo "client: SELECT 42 printed 42"
else
  echo "client: this version ships no hardcharger client (it arrives after 0.2.0)"
fi
echo "E2E OK"
