#!/usr/bin/env bats
load helpers

CADDY_URL="http://127.0.0.1:18080"

setup_file() {
  export EBOX_TEST_DIR
  EBOX_TEST_DIR=$(mktemp -d)
  start_chatto_stack "$EBOX_TEST_DIR"
  require_port_free 18081
  JOIND_PORT=18081 \
    JOIND_CHATTO=$(command -v chatto) \
    JOIND_CONFIG="$EBOX_TEST_DIR/chatto.toml" \
    python3 "$BATS_TEST_DIRNAME/../services/joind.py" \
    >"$EBOX_TEST_DIR/joind.log" 2>&1 &
  echo $! >"$EBOX_TEST_DIR/joind.pid"
  require_port_free 18080
  EBOX_HTTP_PORT=18080 EBOX_CHATTO_PORT=18082 EBOX_JOIND_PORT=18081 \
    EBOX_ROOT="$BATS_TEST_DIRNAME/.." \
    caddy start --config "$BATS_TEST_DIRNAME/../config/Caddyfile" \
    --adapter caddyfile --pidfile "$EBOX_TEST_DIR/caddy.pid" \
    >"$EBOX_TEST_DIR/caddy_start.log" 2>&1
  wait_for_url "$CADDY_URL/healthz" 15
}

teardown_file() {
  kill "$(cat "$EBOX_TEST_DIR/caddy.pid")" 2>/dev/null || true
  kill "$(cat "$EBOX_TEST_DIR/joind.pid")" 2>/dev/null || true
  stop_chatto_stack "$EBOX_TEST_DIR"
}

@test "default route reaches chatto" {
  run curl -fsS "$CADDY_URL/healthz"
  echo "$output" | jq -e '.status == "ok"'
}

@test "/join serves the portal page" {
  run curl -fsS "$CADDY_URL/join"
  [[ "$output" == *'id="signup"'* ]]
  [[ "$output" == *"Pick a username"* ]]
}

@test "/join/anything still serves the portal page" {
  run curl -fsS "$CADDY_URL/join/whatever"
  [[ "$output" == *'id="signup"'* ]]
  [[ "$output" == *"Pick a username"* ]]
}

@test "/joinapi reaches joind" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$CADDY_URL/joinapi" \
    -H 'Content-Type: application/json' -d '{}'
  [ "$output" = "400" ]
}

@test "/ serves the welcome page" {
  run curl -fsS "$CADDY_URL/"
  [[ "$output" == *"Create account"* ]]
  [[ "$output" == *"Sign in"* ]]
  [[ "$output" != *"Pick a username"* ]]
}

@test "/login still reaches chatto" {
  run curl -s -o /dev/null -w '%{http_code}' "$CADDY_URL/login"
  [ "$output" = "200" ]
  run curl -fsS "$CADDY_URL/login"
  [[ "$output" != *"Create account"* ]]
}
